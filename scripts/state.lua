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
  local fresh = not storage.interplanetary_logistics
  storage.interplanetary_logistics = storage.interplanetary_logistics or {}
  local state = storage.interplanetary_logistics
  local previous_schema = state.schema_version or 1
  if fresh then
    previous_schema = Constants.schema_version
  end

  state.suppressions = state.suppressions or {}
  state.enrolled = state.enrolled or {}
  state.active_transfers = state.active_transfers or {}
  state.platform_transfers = state.platform_transfers or {}
  state.history = state.history or {}
  state.source_metrics = state.source_metrics or {}
  state.gui_tabs = state.gui_tabs or {}
  state.route_preferences = state.route_preferences or {}
  state.platform_options = state.platform_options or {}
  state.platform_status = state.platform_status or {}
  state.recent_returns = state.recent_returns or {}
  -- Clear stale persisted jobs and dirty queues once per session to avoid
  -- schema mismatches after code changes (e.g. new fields added to scan_job).
  if not jobs_cleared_this_session then
    state.scan_job = nil
    state.process_job = nil
    state.monitor_job = nil
    state.fleet_job = nil
    state.gui_refresh_job = nil
    state.shipment_execution_job = nil
    state.shipment_maintenance_job = nil
    state.bootstrap_job = nil
    state.reconciliation_job = nil
    state.chest_dirty = {}
    state.construction_dirty = {}
    state.shipment_dirty = {}
    jobs_cleared_this_session = true
  else
    state.scan_job = state.scan_job or nil
    state.process_job = state.process_job or nil
    state.monitor_job = state.monitor_job or nil
    state.fleet_job = state.fleet_job or nil
    state.gui_refresh_job = state.gui_refresh_job or nil
    state.shipment_execution_job = state.shipment_execution_job or nil
    state.shipment_maintenance_job = state.shipment_maintenance_job or nil
    state.bootstrap_job = state.bootstrap_job or nil
    state.reconciliation_job = state.reconciliation_job or nil
    state.chest_dirty = state.chest_dirty or {}
    state.construction_dirty = state.construction_dirty or {}
    state.shipment_dirty = state.shipment_dirty or {}
  end

  if previous_schema < 3 then
    state.demands = state.requests or state.demands or {}
    state.demand_by_key = state.request_by_key or state.demand_by_key or {}
  else
    state.demands = state.demands or state.requests or {}
    state.demand_by_key = state.demand_by_key or state.request_by_key or {}
  end
  state.requests = state.demands
  state.request_by_key = state.demand_by_key

  state.next_demand_id = math.max(state.next_demand_id or 1, state.next_request_id or 1)
  state.next_demand_id = next_id(state.demands, state.next_demand_id)
  state.next_request_id = state.next_demand_id
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

  state.schema_version = Constants.schema_version
  return state
end

function State.get_demand(demand_id)
  return State.ensure().demands[demand_id]
end

function State.get_shipment(shipment_id)
  return State.ensure().shipments[shipment_id]
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

function State.route_key(source, destination)
  return (source or "?") .. "->" .. (destination or "?")
end

function State.get_route_preference(force_index, source, destination)
  local by_force = State.ensure().route_preferences[force_index] or {}
  return by_force[State.route_key(source, destination)]
end

function State.set_route_preference(force_index, source, destination, platform_index)
  local state = State.ensure()
  state.route_preferences[force_index] = state.route_preferences[force_index] or {}
  local key = State.route_key(source, destination)
  state.route_preferences[force_index][key] = platform_index or nil
end

function State.get_platform_options(force_index, platform_index)
  local state = State.ensure()
  state.platform_options[force_index] = state.platform_options[force_index] or {}
  state.platform_options[force_index][platform_index] = state.platform_options[force_index][platform_index] or {
    ready_signal = false
  }
  return state.platform_options[force_index][platform_index]
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
        landing_pads[pad.unit_number] = true
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

function State.register_landing_pad(unit_number)
  landing_pads[unit_number] = true
end

function State.unregister_landing_pad(unit_number)
  landing_pads[unit_number] = nil
end

function State.add_history(request, status, reason)
  local state = State.ensure()
  state.history[#state.history + 1] = {
    id = request.id,
    item = request.item,
    quality = request.quality,
    amount = request.amount,
    source = request.source,
    destination = request.destination,
    origin = request.origin,
    status = status,
    reason = reason,
    tick = game.tick
  }
  while #state.history > Constants.history_limit do
    table.remove(state.history, 1)
  end
end

return State
