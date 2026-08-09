---
name: factorio-routing-source-stock
description: Debug Factorio interplanetary routes that select nonexistent source cargo or synthesize surprising planet requests. Use when a route has a source but loading never completes, a spoilable item is sent cross-planet, or the GUI destination does not match the player's intended demand.
author: joaomcarlos
version: 1.0.0
---

# Factorio Routing Source Stock

## Problem

Separate demand identity from route selection. A surprising route may be a real requester-chest filter, a construction ghost or item-request proxy, or persisted state that has not yet been retired. A valid source ranking can also become stale before a temporary platform transfer is created.

## Context / Trigger Conditions

- The dashboard shows `Routing...` or a source that has no cargo.
- A request appears for an item or destination the player does not recognize.
- The item is spoilable and the platform waits at the source or arrives without cargo.

## Solution

1. Read the persisted request key, origin, item, amount, destination surface index, logistic-network id, and status.
2. For `origin = chest`, inspect the exact requester-chest unit number and its live filters. For construction requests, inspect registered ghosts and item-request proxies; never infer item identity from alert wrapper prototypes.
3. Rank source planets from rocket-silo-connected logistic networks using the exact item and quality. Subtract other reservations and preserve the configured source reserve.
4. Cache the expensive source ranking for the current tick, but perform a fresh provider-stock lookup immediately before adding temporary platform schedule records.
5. Preserve the concrete dispatch blocker in the request so the dashboard explains missing stock, landing pads, capacity, or routes.

## Verification

- Add a regression where provider stock disappears before direct dispatch and assert no transfer or temporary schedule is created.
- Run `lua tests/runtime_spec.lua`, `lua tests/data_stage_spec.lua`, `python tests/locale_spec.py`, Lua parsing, and Factorio mod lint.
- Reproduce with a copied save only. Read back request origin/destination and exact source candidates from the disposable headless run; never mutate the player's live save.

## Notes

`LuaLogisticNetwork::get_item_count(item, "providers")` is source evidence only for provider members connected to rocket silos. It does not guarantee that a spoilable stack will still exist after a long trip; spoilable-item policy needs separate ETA/spoil-tick handling.

## References

- https://lua-api.factorio.com/latest/classes/LuaLogisticNetwork.html
- https://lua-api.factorio.com/latest/classes/LuaItemPrototype.html
- https://lua-api.factorio.com/latest/classes/LuaItemStack.html
