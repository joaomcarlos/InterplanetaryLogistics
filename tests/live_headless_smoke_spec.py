#!/usr/bin/env python3
"""Unit tests for the disposable Factorio live-smoke runner."""

from live_headless_smoke import (
    build_remote_call_command,
    find_active_shipment_ids,
    find_active_shipment_baselines,
    find_rcon_errors,
    find_shipment_baselines,
    find_runtime_errors,
)


def assert_equal(actual, expected, message):
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def test_remote_call_command_is_explicit_and_readable():
    assert_equal(
        build_remote_call_command("dump_state"),
        '/silent-command rcon.print(remote.call("interplanetary_logistics", "dump_state"))',
        "remote probe should be emitted as a Factorio silent command",
    )


def test_active_shipment_ids_are_sorted_and_terminal_shipments_ignored():
    output = """\
Shipment 9: status=loading platform=Alpha
Shipment 2: status=delivering platform=Beta
Shipment 7: status=completed platform=Gamma
Shipment 4: status=failed platform=Delta
"""
    assert_equal(
        find_active_shipment_ids(output),
        [2, 9],
        "live probe should choose active shipments deterministically",
    )


def test_active_shipment_baselines_are_read_from_state_dump():
    output = """\
Shipment 9: status=loading platform=Alpha baseline=12
Shipment 2: status=delivering platform=Beta baseline=nil
Shipment 7: status=completed platform=Gamma baseline=4
"""
    assert_equal(
        find_active_shipment_baselines(output),
        {2: "nil", 9: "12"},
        "live probe should expose baseline values for active Shipments",
    )


def test_shipment_baselines_include_terminal_shipments_after_maintenance():
    output = "Shipment 9: status=failed platform=Alpha baseline=12\n"
    assert_equal(
        find_shipment_baselines(output),
        {9: "12"},
        "live probe should retain a recovered baseline after a Shipment finishes",
    )


def test_runtime_error_filter_only_reports_factorio_mod_failures():
    log = """\
2026-09-04 12:00:00 [WARNING] unrelated warning
Error while running event interplanetary-logistics::on_tick (ID 0)
scripts/platforms.lua:1235: attempt to perform arithmetic on field 'baseline_count'
"""
    assert_equal(
        find_runtime_errors(log),
        [
            "Error while running event interplanetary-logistics::on_tick (ID 0)",
            "scripts/platforms.lua:1235: attempt to perform arithmetic on field 'baseline_count'",
        ],
        "runner should surface mod runtime errors from the Factorio log",
    )


def test_rcon_error_filter_rejects_failed_diagnostics():
    response = """\
Cannot execute command. Error: Error when running interface function
interplanetary_logistics.dump_entities: Unknown entity name
stack traceback:
"""
    assert_equal(
        find_rcon_errors(response),
        [
            "Cannot execute command. Error: Error when running interface function",
            "stack traceback:",
        ],
        "runner should fail when a Factorio diagnostic command is rejected",
    )


def run():
    tests = [
        test_remote_call_command_is_explicit_and_readable,
        test_active_shipment_ids_are_sorted_and_terminal_shipments_ignored,
        test_active_shipment_baselines_are_read_from_state_dump,
        test_shipment_baselines_include_terminal_shipments_after_maintenance,
        test_runtime_error_filter_only_reports_factorio_mod_failures,
        test_rcon_error_filter_rejects_failed_diagnostics,
    ]
    for test in tests:
        test()
    print("live_headless_smoke_spec: OK")


if __name__ == "__main__":
    run()
