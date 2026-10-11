local Constants = require("scripts.constants")

local State = {}

-- Runtime-only destination registries (not persisted).
-- Rebuilt from world entities at game start and maintained via build/remove events.
local chests = {}
local landing_pads = {}
local destinations_initialized = false

-- Runtime-only flag to clear stale persisted jobs once per session.
-- Jobs persisted from a previous session may have an incompatible schema
-- after code changes, so we nil them out on first State.ensure() call.
local jobs_cleared_this_session = false

-- Runtime-only fast path for State.ensure(). The full body below re-sorts
-- every demand and shipment id and rescans history on each call, but those
-- backstops only need to run once per session (plus on schema change, which
-- always lands on the first call after load). Scheduler predicates invoke
-- ensure() many times per tick, so subsequent calls return the table
-- directly once initialization has run.
local ensured_this_session = false

local terminal_shipment_statuses = {
  cancelled = true,
  completed = true,
  failed = true
}

local function sorted_keys(values)
  local keys = {}
  for key in pairs(values or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function next_id(values, configured)
  local result = configured or 1
  for _, id in ipairs(sorted_keys(values)) do
    if type(id) == "number" and id >= result then
      result = id + 1
    end
  end
  return result
end

local function add_shipment_index(state, demand_id, shipment_id)
  state.shipments_by_demand[demand_id] = state.shipments_by_demand[demand_id] or {}
  state.shipments_by_demand[demand_id][shipment_id] = true
end

local function shipment_amount(state, demand_id)
  local total = 0
  for _, shipment_id in ipairs(sorted_keys(state.shipments_by_demand[demand_id])) do
    local shipment = state.shipments[shipment_id]
    if shipment and not terminal_shipment_statuses[shipment.status] then
      total = total + (shipment.allocated_amount or shipment.amount or 0)
    end
  end
  return total
end

local function first_active_shipment_source(state, demand_id)
  for _, shipment_id in ipairs(sorted_keys(state.shipments_by_demand[demand_id])) do
    local shipment = state.shipments[shipment_id]
    if shipment and not terminal_shipment_statuses[shipment.status] then
      local legs = shipment.pickup_legs
      if legs and legs[1] and legs[1].source then
        return legs[1].source
      end
    end
  end
  return nil
end

local function recompute_demand_source(state, demand_id)
  local demand = state.demands[demand_id]
  if not demand then return end
  demand.source = first_active_shipment_source(state, demand_id)
end

local function find_legacy_shipment(state, transfer_id)
  for _, shipment_id in ipairs(sorted_keys(state.shipments)) do
    local shipment = state.shipments[shipment_id]
    if shipment.legacy_transfer_id == transfer_id then
      return shipment_id, shipment
    end
  end
  return nil, nil
end

local function repair_shipment_indexes(state, shipment_id, demand_id, platform_index)
  for _, indexed_demand_id in ipairs(sorted_keys(state.shipments_by_demand)) do
    local index = state.shipments_by_demand[indexed_demand_id]
    if indexed_demand_id ~= demand_id and index[shipment_id] then
      index[shipment_id] = nil
      if not next(index) then
        state.shipments_by_demand[indexed_demand_id] = nil
      end
    end
  end
  add_shipment_index(state, demand_id, shipment_id)

  for _, indexed_platform in ipairs(sorted_keys(state.platform_shipments)) do
    if indexed_platform ~= platform_index and state.platform_shipments[indexed_platform] == shipment_id then
      state.platform_shipments[indexed_platform] = nil
    end
  end
  if platform_index then
    state.platform_shipments[platform_index] = shipment_id
  end
end

local function migrate_legacy_transfer(state, transfer_id, transfer)
  local demand_id = transfer.request_id or transfer.demand_id or transfer_id
  local shipment_id, shipment = find_legacy_shipment(state, transfer_id)
  if shipment then
    shipment.demand_id = demand_id
    shipment.request_id = shipment.request_id or demand_id
    repair_shipment_indexes(state, shipment_id, demand_id, transfer.platform_index or shipment.platform_index)
    return shipment
  end

  local demand = state.demands[demand_id]
  shipment_id = state.next_shipment_id
  local loaded_full = transfer.loaded_full == true
  local pickup_legs = {{
    source = transfer.source,
    planned_amount = transfer.amount,
    cumulative_target = transfer.target_count,
    hub_section_index = transfer.hub_section_index,
    status = loaded_full and "completed" or "loading"
  }}
  shipment = {
    id = shipment_id,
    legacy_transfer_id = transfer_id,
    demand_id = demand_id,
    request_id = demand_id,
    force_index = transfer.force_index,
    platform_index = transfer.platform_index,
    platform_name = transfer.platform_name,
    source = transfer.source,
    destination = transfer.destination,
    destination_surface_index = transfer.destination_surface_index or (demand and demand.destination_surface_index),
    logistic_network_id = transfer.logistic_network_id or (demand and demand.logistic_network_id),
    item = transfer.item,
    quality = transfer.quality,
    amount = transfer.amount,
    allocated_amount = transfer.amount,
    baseline_count = transfer.baseline_count,
    target_count = transfer.target_count,
    original_current = transfer.original_current,
    original_schedule_current = transfer.original_schedule_current or transfer.original_current,
    hub_section_index = transfer.hub_section_index,
    pad_unit_number = transfer.pad_unit_number,
    pad_section_index = transfer.pad_section_index,
    pad_baseline_count = transfer.pad_baseline_count,
    started_tick = transfer.started_tick,
    loaded_full = loaded_full,
    status = loaded_full and "delivering" or "loading",
    pickup_legs = pickup_legs
  }
  state.shipments[shipment_id] = shipment
  repair_shipment_indexes(state, shipment_id, demand_id, transfer.platform_index)
  state.next_shipment_id = shipment_id + 1
  return shipment
end

function State.ensure()
  local state = storage.interplanetary_logistics
  if ensured_this_session and state and state.schema_version == Constants.schema_version then
    return state
  end
  local fresh = not state
  storage.interplanetary_logistics = state or {}
  state = storage.interplanetary_logistics
  local previous_schema = state.schema_version or 1
  if fresh then
    previous_schema = Constants.schema_version
  end

  state.suppressions = state.suppressions or {}
  state.enrolled = state.enrolled or {}
  state.schedule_override = state.schedule_override or {}
  state.history = state.history or {}
  state.next_history_seq = state.next_history_seq or 1
  -- Backfill seq on legacy history entries so individual clear buttons work
  for _, entry in ipairs(state.history) do
    if not entry.seq then
      entry.seq = state.next_history_seq
      state.next_history_seq = state.next_history_seq + 1
    end
  end
  state.source_metrics = state.source_metrics or {}
  state.destination_metrics = state.destination_metrics or {}
  state.gui_tabs = state.gui_tabs or {}
  state.platform_status = state.platform_status or {}
  -- Route pinning was removed; drop the dead persisted table.
  state.route_preferences = nil
  -- Clear stale persisted jobs and dirty queues once per session to avoid
  -- schema mismatches after code changes (e.g. new fields added to scan_job).
  if not jobs_cleared_this_session then
    state.scan_job = nil
    state.process_job = nil
    state.fleet_job = nil
    state.gui_refresh_job = nil
    state.shipment_execution_job = nil
    state.shipment_maintenance_job = nil
    state.bootstrap_job = nil
    state.chest_dirty = {}
    state.construction_dirty = {}
    state.shipment_dirty = {}
    jobs_cleared_this_session = true
  end

  if previous_schema < 3 then
    state.demands = state.requests or state.demands or {}
    state.demand_by_key = state.request_by_key or state.demand_by_key or {}
  else
    state.demands = state.demands or state.requests or {}
    state.demand_by_key = state.demand_by_key or state.request_by_key or {}
  end
  -- Drop legacy aliases so only demands/demand_by_key are persisted.
  state.requests = nil
  state.request_by_key = nil

  state.next_demand_id = math.max(state.next_demand_id or 1, state.next_request_id or 1)
  state.next_demand_id = next_id(state.demands, state.next_demand_id)
  state.next_request_id = nil
  state.shipments = state.shipments or {}
  state.shipments_by_demand = state.shipments_by_demand or {}
  state.platform_shipments = state.platform_shipments or {}
  state.pad_sections = state.pad_sections or {}
  state.next_shipment_id = next_id(state.shipments, state.next_shipment_id or 1)
  state.tracked_construction = state.tracked_construction or {}
  state.bootstrap_completed = state.bootstrap_completed or false

  if previous_schema < 2 then
    for _, player_index in ipairs(sorted_keys(state.gui_tabs)) do
      local tabs = state.gui_tabs[player_index]
      local old = tabs.main_tab_index
      if old == 1 then tabs.main_tab_index = 2
      elseif old == 2 then tabs.main_tab_index = 3
      elseif old == 3 then tabs.main_tab_index = 1
      end
    end
  end

  if previous_schema < 3 then
    for _, transfer_id in ipairs(sorted_keys(state.active_transfers)) do
      migrate_legacy_transfer(state, transfer_id, state.active_transfers[transfer_id])
    end
    state.next_shipment_id = next_id(state.shipments, state.next_shipment_id)
    for _, demand_id in ipairs(sorted_keys(state.demands)) do
      local demand = state.demands[demand_id]
      demand.observed_shortage = demand.observed_shortage or demand.amount or 0
      demand.active_shipment_amount = shipment_amount(state, demand_id)
      demand.unplanned_amount = math.max(0, demand.observed_shortage - demand.active_shipment_amount)
    end
  end

  if previous_schema < 4 then
    for _, demand_id in ipairs(sorted_keys(state.demands)) do
      recompute_demand_source(state, demand_id)
    end
  end

  if previous_schema < 5 then
    -- Legacy transfers are now represented by Shipments. Keep the old maps
    -- only long enough to migrate them, then remove them so stale records
    -- cannot compete with the canonical Shipment indexes.
    for _, transfer_id in ipairs(sorted_keys(state.active_transfers)) do
      migrate_legacy_transfer(state, transfer_id, state.active_transfers[transfer_id])
    end
    state.next_shipment_id = next_id(state.shipments, state.next_shipment_id)
    -- Drop the legacy maps entirely; nothing reads them after migration.
    state.active_transfers = nil
    state.platform_transfers = nil
  end

  if previous_schema < 6 then
    -- Earlier tracking relied on global unit lookup, which excludes ghosts and
    -- proxies without the prototype flag. Recover their references once.
    state.tracked_construction = {}
    state.construction_dirty = {}
    state.bootstrap_completed = false
    state.bootstrap_job = nil
  end

  if previous_schema < 7 then
    -- Ghosts created by entity death were never tracked (on_post_entity_died
    -- was unwired). Re-run the bounded bootstrap once to discover any that
    -- still exist in the save.
    state.tracked_construction = {}
    state.construction_dirty = {}
    state.bootstrap_completed = false
    state.bootstrap_job = nil
  end

  for _, demand_id in ipairs(sorted_keys(state.demands or {})) do
    local demand = state.demands[demand_id]
    demand.status_tick = demand.status_tick or demand.created_tick or (game and game.tick) or 0
  end

  state.schema_version = Constants.schema_version
  ensured_this_session = true
  return state
end

function State.get_demand(demand_id)
  return State.ensure().demands[demand_id]
end

function State.get_shipment(shipment_id)
  return State.ensure().shipments[shipment_id]
end

function State.set_status(demand, status)
  if demand.status ~= status then
    demand.status = status
    demand.status_tick = game.tick
  end
end

function State.active_shipment_amount(demand_id)
  return shipment_amount(State.ensure(), demand_id)
end

function State.create_shipment(demand, platform, legs)
  local state = State.ensure()
  local total = 0
  for _, leg in ipairs(legs) do
    total = total + (leg.planned_amount or 0)
  end
  local shipment_id = state.next_shipment_id
  local shipment = {
    id = shipment_id,
    demand_id = demand.id,
    force_index = demand.force_index,
    platform_index = platform.index,
    platform_name = platform.name,
    destination = demand.destination,
    destination_surface_index = demand.destination_surface_index,
    logistic_network_id = demand.logistic_network_id,
    item = demand.item,
    quality = demand.quality,
    amount = total,
    allocated_amount = total,
    pickup_legs = legs,
    status = "planned",
    started_tick = game.tick
  }
  state.shipments[shipment_id] = shipment
  add_shipment_index(state, demand.id, shipment_id)
  state.platform_shipments[platform.index] = shipment_id
  state.next_shipment_id = shipment_id + 1
  recompute_demand_source(state, demand.id)
  return shipment
end

function State.cancel_shipment(shipment_id)
  local state = State.ensure()
  local shipment = state.shipments[shipment_id]
  if not shipment then return end
  local demand_id = shipment.demand_id
  local platform_index = shipment.platform_index
  state.shipments[shipment_id] = nil
  State.remove_shipment_index(demand_id, shipment_id)
  if state.platform_shipments[platform_index] == shipment_id then
    state.platform_shipments[platform_index] = nil
  end
  shipment.status = "cancelled"
  local demand = state.demands[demand_id]
  if demand then
    demand.active_shipment_amount = shipment_amount(state, demand_id)
    demand.unplanned_amount = math.max(0, (demand.observed_shortage or demand.amount or 0) - demand.active_shipment_amount)
    recompute_demand_source(state, demand_id)
  end
  return shipment
end

function State.add_shipment_index(demand_id, shipment_id)
  add_shipment_index(State.ensure(), demand_id, shipment_id)
end

function State.remove_shipment_index(demand_id, shipment_id)
  local state = State.ensure()
  local index = state.shipments_by_demand[demand_id]
  if not index then return end
  index[shipment_id] = nil
  if not next(index) then
    state.shipments_by_demand[demand_id] = nil
  end
end

function State.get()
  return storage.interplanetary_logistics
end

function State.rebuild_destinations()
  chests = {}
  landing_pads = {}
  for _, surface in pairs(game.surfaces) do
    for _, chest in pairs(surface.find_entities_filtered({name = Constants.chest_name})) do
      if chest.valid and chest.unit_number then
        chests[chest.unit_number] = true
      end
    end
    for _, pad in pairs(surface.find_entities_filtered({type = "cargo-landing-pad"})) do
      if pad.valid and pad.unit_number then
        landing_pads[pad.unit_number] = pad
      end
    end
  end
  destinations_initialized = true
end

function State.ensure_destinations()
  if not destinations_initialized then
    State.rebuild_destinations()
  end
  return State.ensure()
end

function State.get_chests()
  return chests
end

function State.get_landing_pads()
  return landing_pads
end

function State.register_chest(unit_number)
  chests[unit_number] = true
end

function State.unregister_chest(unit_number)
  chests[unit_number] = nil
end

function State.register_landing_pad(unit_number, entity)
  landing_pads[unit_number] = entity
end

function State.unregister_landing_pad(unit_number)
  landing_pads[unit_number] = nil
end

function State.add_history(request, status, reason)
  local state = State.ensure()
  state.history[#state.history + 1] = {
    seq = state.next_history_seq,
    id = request.id,
    item = request.item,
    quality = request.quality,
    amount = request.amount,
    source = request.source,
    destination = request.destination,
    origin = request.origin,
    status = status,
    reason = reason,
    created_tick = request.created_tick,
    tick = game.tick
  }
  state.next_history_seq = state.next_history_seq + 1
  while #state.history > Constants.history_limit do
    table.remove(state.history, 1)
  end
end

function State.remove_history_entry(seq)
  if not seq then return end
  local state = State.ensure()
  for index, entry in ipairs(state.history) do
    if entry.seq == seq then
      table.remove(state.history, index)
      return
    end
  end
end

function State.clear_history()
  local state = State.ensure()
  state.history = {}
end

function State.delete_shipment(shipment_id)
  local state = State.ensure()
  local shipment = state.shipments[shipment_id]
  if not shipment then return end
  local demand_id = shipment.demand_id
  state.shipments[shipment_id] = nil
  State.remove_shipment_index(demand_id, shipment_id)
  if state.platform_shipments[shipment.platform_index] == shipment_id then
    state.platform_shipments[shipment.platform_index] = nil
  end
  recompute_demand_source(state, demand_id)
end

-- Iterate all indexed shipment ids for a demand in sorted order, calling
-- `callback(shipment_id, shipment)` for each. Used by cancel/fulfill/remove
-- paths that need deterministic cleanup of child shipments.
function State.for_each_sorted_shipment(demand_id, callback)
  local state = State.ensure()
  local index = state.shipments_by_demand[demand_id]
  if not index then return end
  local ids = sorted_keys(index)
  for _, shipment_id in ipairs(ids) do
    local shipment = state.shipments[shipment_id]
    if shipment then callback(shipment_id, shipment) end
  end
end

return State
