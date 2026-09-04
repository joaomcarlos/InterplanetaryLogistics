#!/usr/bin/env python3
"""Run a disposable Factorio 2.1 server against a real save.

The runner intentionally owns only the disposable wrapper process.  It never
starts, stops, or attaches to a user's existing Factorio instance.  A copied
save is loaded with the working tree as a mod and Lua console speed is
increased so the real control stage can be observed for many game ticks.
"""

from __future__ import annotations

import argparse
import json
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[1]
_RUNNER_RELATIVE_PATH = Path(
    "skills/factorio-debug-ingame-state/scripts/run-disposable-factorio.sh"
)
_RUNNER_CANDIDATES = (
    REPO_ROOT / ".agents" / _RUNNER_RELATIVE_PATH,
    Path("/home/jc/.agents") / _RUNNER_RELATIVE_PATH,
    Path("/home/jc/.codex") / _RUNNER_RELATIVE_PATH,
)
DEFAULT_DISPOSABLE_RUNNER = next(
    (candidate for candidate in _RUNNER_CANDIDATES if candidate.is_file()),
    _RUNNER_CANDIDATES[0],
)
ACTIVE_SHIPMENT_STATUSES = {"loading", "delivering"}
RUNTIME_ERROR_MARKERS = (
    "Error while running event interplanetary-logistics::",
    "non-recoverable error",
    "LuaEntity doesn't contain key station",
    "attempt to perform arithmetic on field 'baseline_count'",
)
RCON_ERROR_MARKERS = (
    "Cannot execute command.",
    "Error when running interface function",
    "stack traceback:",
)


class LiveSmokeFailure(RuntimeError):
    """A live smoke assertion or disposable-server startup failed."""


def build_remote_call_command(method: str) -> str:
    """Build a safe RCON command for one known mod diagnostic method."""

    if not re.fullmatch(r"[a-z][a-z0-9_]*", method):
        raise ValueError(f"invalid remote method name: {method!r}")
    return (
        '/silent-command rcon.print(remote.call('
        f'"interplanetary_logistics", "{method}"))'
    )


def find_active_shipment_ids(output: str) -> list[int]:
    """Return active Shipment ids from the mod's deterministic state dump."""

    found = set()
    pattern = re.compile(
        r"^\s*Shipment\s+(\d+):\s+status=(planned|loading|delivering)\b",
        re.MULTILINE,
    )
    for match in pattern.finditer(output):
        if match.group(2) in ACTIVE_SHIPMENT_STATUSES:
            found.add(int(match.group(1)))
    return sorted(found)


def find_active_shipment_baselines(output: str) -> dict[int, str]:
    """Return active Shipment ids and their diagnostic baseline values."""

    found: dict[int, str] = {}
    pattern = re.compile(
        r"^\s*Shipment\s+(\d+):\s+status=(loading|delivering)\b[^\n]*?\sbaseline=([^\s]+)",
        re.MULTILINE,
    )
    for match in pattern.finditer(output):
        found[int(match.group(1))] = match.group(3)
    return dict(sorted(found.items()))


def find_shipment_baselines(output: str) -> dict[int, str]:
    """Return baseline values for every Shipment still present in state."""

    found: dict[int, str] = {}
    pattern = re.compile(
        r"^\s*Shipment\s+(\d+):\s+status=[^\s]+\b[^\n]*?\sbaseline=([^\s]+)",
        re.MULTILINE,
    )
    for match in pattern.finditer(output):
        found[int(match.group(1))] = match.group(2)
    return dict(sorted(found.items()))


def find_runtime_errors(log: str) -> list[str]:
    """Extract actionable Interplanetary Logistics runtime errors from logs."""

    errors = []
    for line in log.splitlines():
        stripped = line.strip()
        if stripped and any(marker in stripped for marker in RUNTIME_ERROR_MARKERS):
            errors.append(stripped)
    return errors


def find_rcon_errors(response: str) -> list[str]:
    """Extract Factorio command/interface failures from one RCON response."""

    return [
        line.strip()
        for line in response.splitlines()
        if line.strip() and any(marker in line for marker in RCON_ERROR_MARKERS)
    ]


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise LiveSmokeFailure(f"expected JSON object in {path}")
    return value


def _copy_mod_tree(destination: Path) -> Path:
    """Copy the current working tree into a Factorio mod directory."""

    info = _read_json(REPO_ROOT / "info.json")
    name = info.get("name")
    version = info.get("version")
    if not isinstance(name, str) or not isinstance(version, str):
        raise LiveSmokeFailure("info.json must define string name and version")

    mod_path = destination / f"{name}_{version}"
    ignored = shutil.ignore_patterns(
        ".git",
        ".agents",
        ".claude",
        ".codex-headless",
        ".codex-headless.*",
        "__pycache__",
        "mockups",
        "tests",
    )
    shutil.copytree(REPO_ROOT, mod_path, ignore=ignored)
    return mod_path


def _read_packet(sock: socket.socket, deadline: float) -> Optional[tuple[int, int, str]]:
    def read_exact(size: int) -> Optional[bytes]:
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            sock.settimeout(remaining)
            try:
                chunk = sock.recv(size - len(data))
            except socket.timeout:
                return None
            if not chunk:
                return None
            data.extend(chunk)
        return bytes(data)

    header = read_exact(4)
    if header is None:
        return None
    length = struct.unpack("<i", header)[0]
    if length < 10:
        raise LiveSmokeFailure(f"invalid RCON packet length: {length}")
    payload = read_exact(length)
    if payload is None:
        return None
    request_id, packet_type = struct.unpack("<ii", payload[:8])
    body = payload[8:-2].decode("utf-8", errors="replace")
    return request_id, packet_type, body


def _packet(request_id: int, packet_type: int, body: str) -> bytes:
    payload = struct.pack("<ii", request_id, packet_type)
    payload += body.encode("utf-8") + b"\0\0"
    return struct.pack("<i", len(payload)) + payload


class RconClient:
    """Minimal Source RCON client using only Python's standard library."""

    def __init__(self, host: str, port: int, password: str):
        self.host = host
        self.port = port
        self.password = password
        self._next_request_id = 10

    def execute(self, command: str, timeout: float = 8.0) -> str:
        request_id = self._next_request_id
        self._next_request_id += 1
        deadline = time.monotonic() + timeout
        with socket.create_connection((self.host, self.port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            sock.sendall(_packet(1, 3, self.password))
            auth = _read_packet(sock, deadline)
            if auth is None or auth[0] == -1:
                raise LiveSmokeFailure("Factorio RCON authentication failed")

            sock.sendall(_packet(request_id, 2, command))
            while time.monotonic() < deadline:
                response = _read_packet(sock, deadline)
                if response is None:
                    break
                if response[0] == request_id:
                    return response[2]
        return ""

    def wait_until_ready(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        last_error: Optional[Exception] = None
        while time.monotonic() < deadline:
            try:
                response = self.execute(
                    '/silent-command rcon.print("il-live-ready")', timeout=2.0
                )
                if "il-live-ready" in response:
                    return
            except (OSError, LiveSmokeFailure) as error:
                last_error = error
            time.sleep(0.25)
        detail = f": {last_error}" if last_error else ""
        raise LiveSmokeFailure(f"RCON did not become ready{detail}")


class LiveSmokeRunner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.artifact_root = REPO_ROOT / ".codex-headless"
        self.artifact_root.mkdir(parents=True, exist_ok=True)
        self.run_root = Path(
            tempfile.mkdtemp(prefix="live-smoke-", dir=self.artifact_root)
        )
        self.wrapper_stdout_path = self.run_root / "wrapper.stdout.log"
        self.wrapper_stderr_path = self.run_root / "wrapper.stderr.log"
        self.factorio_run_dir: Optional[Path] = None
        self.process: Optional[subprocess.Popen[bytes]] = None
        self.rcon: Optional[RconClient] = None

    def _wrapper_run_dir(self) -> Optional[Path]:
        if not self.wrapper_stderr_path.exists():
            return None
        try:
            text = self.wrapper_stderr_path.read_text(encoding="utf-8")
        except OSError:
            return None
        match = re.search(r"^run_dir=(\S+)$", text, re.MULTILINE)
        return Path(match.group(1)).resolve() if match else None

    def _factorio_logs(self) -> str:
        run_dir = self.factorio_run_dir or self._wrapper_run_dir()
        if run_dir is None:
            return ""
        logs = []
        paths = list((run_dir / "logs").glob("*.log"))
        write_data = run_dir / "write-data"
        paths.extend(
            path
            for path in write_data.rglob("factorio-*.log")
            if path.is_file()
        )
        for path in sorted(set(paths)):
            try:
                logs.append(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                pass
        return "\n".join(logs)

    def _write_probe(self, name: str, contents: str) -> None:
        (self.run_root / name).write_text(contents, encoding="utf-8")

    def _owned_factorio_run_dir(self) -> Optional[Path]:
        run_dir = self.factorio_run_dir or self._wrapper_run_dir()
        if run_dir is None or not run_dir.name.startswith("lil-einstein-factorio."):
            return None
        marker = run_dir / "OWNER"
        try:
            if marker.read_text(encoding="utf-8") != "disposable-factorio-run\n":
                return None
        except OSError:
            return None
        return run_dir

    def _start(self) -> None:
        factorio = Path(self.args.factorio).expanduser().resolve()
        runner = Path(self.args.runner).expanduser().resolve()
        save = Path(self.args.save).expanduser().resolve()
        if not factorio.is_file() or not factorio.stat().st_mode & 0o111:
            raise LiveSmokeFailure(f"Factorio executable is not executable: {factorio}")
        if factorio.name not in {"factorio", "factorio-bin"}:
            raise LiveSmokeFailure(f"refusing non-Factorio executable: {factorio}")
        if not runner.is_file() or not runner.stat().st_mode & 0o111:
            raise LiveSmokeFailure(f"disposable runner is not executable: {runner}")
        if not save.is_file():
            raise LiveSmokeFailure(f"source save is missing: {save}")

        mods_dir = self.run_root / "mods"
        mods_dir.mkdir()
        _copy_mod_tree(mods_dir)
        self._write_probe(
            "run.json",
            json.dumps(
                {
                    "save": str(save),
                    "factorio": str(factorio),
                    "speed": self.args.speed,
                    "seconds": self.args.seconds,
                    "prepare_baseline": self.args.prepare_baseline,
                },
                indent=2,
            )
            + "\n",
        )
        server_settings_path = self.run_root / "server-settings.json"
        server_settings_path.write_text(
            json.dumps(
                {
                    "name": "Interplanetary Logistics live smoke",
                    "description": "Disposable headless verification run",
                    "visibility": {"public": False, "lan": False},
                    "allow_commands": "true",
                    "auto_pause": False,
                    "auto_pause_when_players_connect": False,
                    "autosave_interval": 0,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        rcon_port = _free_port()
        game_port = _free_port()
        password = secrets.token_urlsafe(24)
        command = [
            str(runner),
            "--factorio",
            str(factorio),
            "--save",
            str(save),
            "--",
            "--mod-directory",
            str(mods_dir),
            "--port",
            str(game_port),
            "--rcon-port",
            str(rcon_port),
            "--rcon-password",
            password,
            "--server-settings",
            str(server_settings_path),
            "--disable-audio",
        ]
        stdout = self.wrapper_stdout_path.open("wb")
        stderr = self.wrapper_stderr_path.open("wb")
        try:
            # The disposable wrapper, not this script, owns the Factorio child.
            self.process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
        finally:
            stdout.close()
            stderr.close()
        self.factorio_run_dir = None
        self.rcon = RconClient("127.0.0.1", rcon_port, password)
        self.rcon.wait_until_ready(self.args.startup_timeout)
        self.factorio_run_dir = self._wrapper_run_dir()

    def _execute(self, command: str, timeout: float = 8.0) -> str:
        if self.rcon is None:
            raise LiveSmokeFailure("RCON client is not initialized")
        try:
            response = self.rcon.execute(command, timeout=timeout)
        except (OSError, LiveSmokeFailure) as error:
            raise LiveSmokeFailure(f"RCON command failed: {error}") from error
        rcon_errors = find_rcon_errors(response)
        if rcon_errors:
            raise LiveSmokeFailure(
                "Factorio rejected the RCON command:\n" + "\n".join(rcon_errors)
            )
        return response

    def _remote(self, method: str, timeout: float = 10.0) -> str:
        return self._execute(build_remote_call_command(method), timeout=timeout)

    def _run_lua(self, lua: str, timeout: float = 8.0) -> str:
        return self._execute(f"/silent-command {lua}", timeout=timeout)

    def _confirm_lua_console(self) -> None:
        command = '/silent-command rcon.print("il-live-confirm")'
        response = self._execute(command, timeout=2.0)
        if "il-live-confirm" not in response:
            response = self._execute(command, timeout=4.0)
        if "il-live-confirm" not in response:
            raise LiveSmokeFailure(
                "Factorio did not accept the Lua console confirmation command"
            )

    def _game_tick(self) -> int:
        output = self._run_lua('rcon.print("il-live-tick=" .. tostring(game.tick))')
        match = re.search(r"il-live-tick=(\d+)", output)
        if not match:
            raise LiveSmokeFailure(f"could not read game.tick from RCON output: {output!r}")
        return int(match.group(1))

    def run(self) -> None:
        self._start()
        self._confirm_lua_console()
        pause_output = self._run_lua(
            'game.tick_paused=true; game.ticks_to_run=0; '
            'rcon.print("il-live-paused="..tostring(game.tick_paused))'
        )
        self._write_probe("pause.txt", pause_output)
        if "il-live-paused=true" not in pause_output:
            raise LiveSmokeFailure(f"could not pause the disposable game: {pause_output!r}")

        if self.args.prepare_baseline:
            setting_output = self._remote("enable_live_test_mode")
            self._write_probe("live-test-mode.txt", setting_output)
            if "live test mode enabled" not in setting_output:
                raise LiveSmokeFailure(
                    "could not enable the isolated live-test setting: "
                    + repr(setting_output)
                )

        self._remote("rebuild_destinations")
        before = self._remote("dump_state")
        self._write_probe("state-before.txt", before)
        active_ids = find_active_shipment_ids(before)
        active_baselines = find_active_shipment_baselines(before)
        self._write_probe(
            "active-before.txt",
            "\n".join(
                f"{shipment_id}: {active_baselines.get(shipment_id, 'unknown')}"
                for shipment_id in active_ids
            )
            + ("\n" if active_ids else ""),
        )
        if not active_ids and (self.args.prepare_baseline or not self.args.allow_no_active):
            raise LiveSmokeFailure(
                "fixture has no loading/delivering Shipment; "
                "prepare an editor-mode save with an active shipment or pass "
                "--allow-no-active (without --prepare-baseline)"
            )

        prepared_ids = []
        if self.args.prepare_baseline:
            preparation = self._remote("prepare_live_smoke")
            self._write_probe("prepare.txt", preparation)
            prepared = self._remote("dump_state")
            self._write_probe("state-prepared.txt", prepared)
            prepared_ids = find_active_shipment_ids(prepared)
            prepared_baselines = find_active_shipment_baselines(prepared)
            missing = [shipment_id for shipment_id in active_ids if shipment_id not in prepared_ids]
            if missing:
                raise LiveSmokeFailure(
                    "live preparation lost active Shipment ids "
                    + ", ".join(str(shipment_id) for shipment_id in missing)
                )
            uncleared = [
                shipment_id
                for shipment_id in active_ids
                if prepared_baselines.get(shipment_id) != "nil"
            ]
            if uncleared:
                raise LiveSmokeFailure(
                    "live preparation did not clear baseline_count for Shipment ids "
                    + ", ".join(str(shipment_id) for shipment_id in uncleared)
                )

        speed_output = self._run_lua(
            f"game.ticks_to_run=1000000000; game.speed={self.args.speed}; "
            "game.tick_paused=false; "
            'rcon.print("il-live-speed="..tostring(game.speed).." paused="..tostring(game.tick_paused))'
        )
        self._write_probe("speed.txt", speed_output)
        if "il-live-speed=" not in speed_output:
            raise LiveSmokeFailure(f"could not set game speed: {speed_output!r}")

        tick_before = self._game_tick()
        deadline = time.monotonic() + self.args.seconds
        while time.monotonic() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise LiveSmokeFailure(
                    f"disposable Factorio exited early with code {self.process.returncode}"
                )
            time.sleep(0.25)
        tick_after = self._game_tick()
        if tick_after <= tick_before:
            raise LiveSmokeFailure(
                f"Factorio did not advance while running (ticks {tick_before} -> {tick_after})"
            )
        self._write_probe("ticks.txt", f"{tick_before} -> {tick_after}\n")

        after = self._remote("dump_state")
        self._write_probe("state-after.txt", after)
        if "bootstrap: true" not in after:
            raise LiveSmokeFailure("mod bootstrap did not complete in the disposable save")
        if active_ids:
            after_baselines = find_shipment_baselines(after)
            missing_baselines = [
                shipment_id
                for shipment_id in active_ids
                if shipment_id in after_baselines
                and after_baselines[shipment_id] in {"nil", "None", ""}
            ]
            if missing_baselines:
                raise LiveSmokeFailure(
                    "maintenance did not restore baseline_count for Shipment ids "
                    + ", ".join(str(shipment_id) for shipment_id in missing_baselines)
                )
            if self.args.prepare_baseline:
                recovered = [
                    shipment_id
                    for shipment_id in prepared_ids
                    if shipment_id in after_baselines
                    and after_baselines[shipment_id] not in {"nil", "None", ""}
                ]
                if not recovered:
                    raise LiveSmokeFailure(
                        "no prepared Shipment remained observable with a recovered baseline_count"
                    )
            self._write_probe(
                "active-after.txt",
                "\n".join(
                    f"{shipment_id}: {after_baselines[shipment_id]}"
                    for shipment_id in sorted(after_baselines)
                )
                + "\n",
            )
        self._write_probe("entities-after.txt", self._remote("dump_entities"))
        self._write_probe("platforms-after.txt", self._remote("dump_platforms"))

        errors = find_runtime_errors(self._factorio_logs())
        if errors:
            self._write_probe("runtime-errors.txt", "\n".join(errors) + "\n")
            raise LiveSmokeFailure(
                "Factorio reported Interplanetary Logistics runtime errors:\n"
                + "\n".join(errors)
            )

    def finish(self, success: bool) -> Path:
        """Stop only our wrapper process, copy evidence, and clean exact temp dirs."""

        stopped = True
        if self.process is not None and self.process.poll() is None:
            # This is the wrapper we launched.  Its EXIT trap owns child cleanup.
            try:
                self.process.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    self.process.send_signal(signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    stopped = False
        if self.process is not None and self.process.poll() is None:
            stopped = False

        self.factorio_run_dir = self.factorio_run_dir or self._wrapper_run_dir()
        if self.factorio_run_dir is not None:
            logs_dir = self.factorio_run_dir / "logs"
            if logs_dir.is_dir():
                destination = self.run_root / "factorio-logs"
                if not destination.exists():
                    shutil.copytree(logs_dir, destination)
            write_data_logs = self.factorio_run_dir / "write-data"
            if write_data_logs.is_dir():
                destination = self.run_root / "factorio-write-data-logs"
                for path in write_data_logs.rglob("factorio-*.log"):
                    if not path.is_file():
                        continue
                    target = destination / path.relative_to(write_data_logs)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, target)

        owned_run_dir = self._owned_factorio_run_dir()
        if stopped and owned_run_dir is not None and owned_run_dir.exists():
            shutil.rmtree(owned_run_dir, ignore_errors=False)

        if success and not self.args.keep_artifacts and stopped:
            shutil.rmtree(self.run_root, ignore_errors=False)
        return self.run_root


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run Interplanetary Logistics in a disposable headless Factorio "
            "server against a copied save."
        )
    )
    parser.add_argument("--factorio", required=True, help="absolute Factorio 2.1 binary path")
    parser.add_argument("--save", required=True, help="source save ZIP; it is copied before launch")
    parser.add_argument(
        "--runner",
        default=str(DEFAULT_DISPOSABLE_RUNNER),
        help="disposable Factorio wrapper (default: %(default)s)",
    )
    parser.add_argument(
        "--speed",
        type=float,
        default=32.0,
        help="temporary game.speed used by the disposable server (default: %(default)s)",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        default=8.0,
        help="wall-clock seconds to let the accelerated simulation run (default: %(default)s)",
    )
    parser.add_argument(
        "--startup-timeout",
        type=float,
        default=120.0,
        help="seconds to wait for headless Factorio/RCON startup (default: %(default)s)",
    )
    parser.add_argument(
        "--allow-no-active",
        action="store_true",
        help="run the smoke loop even when the fixture has no active Shipment",
    )
    parser.add_argument(
        "--prepare-baseline",
        action="store_true",
        help=(
            "in the isolated run, enable the hidden live-test setting and clear "
            "baseline_count on existing active Shipments before maintenance"
        ),
    )
    parser.add_argument(
        "--keep-artifacts",
        action="store_true",
        help="retain .codex-headless/live-smoke-* artifacts after a successful run",
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    if args.speed <= 0 or args.seconds <= 0 or args.startup_timeout <= 0:
        print("--speed, --seconds, and --startup-timeout must be positive", file=sys.stderr)
        return 2

    runner = LiveSmokeRunner(args)
    success = False
    try:
        runner.run()
        success = True
        print("live_headless_smoke: OK")
        return 0
    except (LiveSmokeFailure, OSError, ValueError) as error:
        print(f"live_headless_smoke: FAIL: {error}", file=sys.stderr)
        return 1
    finally:
        artifact_path = runner.finish(success)
        if not success or args.keep_artifacts:
            print(f"artifacts: {artifact_path}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
