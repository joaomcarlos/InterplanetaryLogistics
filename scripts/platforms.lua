local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")
local SourceStock = require("scripts.source_stock")

local Platforms = {}

local function hub_inventory(hub)
  if not hub or not hub.valid then
    return nil
  end
  if hub.get_inventory and defines and defines.inventory and defines.inventory.hub_main then
    return hub.get_inventory(defines.inventory.hub_main)
  end
  return hub.get_main_inventory and hub.get_main_inventory() or nil
end

local function setting_value(name, default)
  local setting = settings and settings.global and settings.global[name]
  if setting == nil then return default end
  if type(setting) == "table" then return setting.value end
  return setting
end

local function endpoint_name(endpoint)
  return endpoint and endpoint.name or nil
end

local function estimate_current_leg(platform, target)
  local connection = platform.space_connection
  local distance = platform.distance
  if not connection or distance == nil then return nil end
  local remaining
  if target == endpoint_name(connection.to) then
    remaining = 1 - distance
  elseif target == endpoint_name(connection.from) then
    remaining = distance
  else
    return nil
  end
  local speed = math.abs(platform.speed or 0)
  if speed <= 0 then return nil end
  return math.max(0, math.ceil(remaining * (connection.length or 1) / speed))
end

function Platforms.estimate_ticks_to(platform, target)
  if not platform or not platform.valid then return nil end
  if platform.space_location and platform.space_location.name == target then return 0 end
  local current_leg = estimate_current_leg(platform, target)
  if current_leg then return current_leg end
  local schedule = platform.schedule
  local records = schedule and schedule.records or {}
  local start = schedule and schedule.current or 1
  for offset = 0, #records - 1 do
    local index = ((start + offset - 1) % #records) + 1
    if records[index].station == target then
      return (offset + 1) * Constants.default_leg_ticks
    end
  end
  return nil
end

local function request_group(request_id)
  return "Interplanetary Logistics #" .. request_id
end

local function schedule_has_location(schedule, location)
  if not schedule then
    return false
  end
  for _, record in pairs(schedule.records or {}) do
    if record.station == location then
      return true
    end
  end
  return false
end

local function item_condition(request, comparator, constant)
  return {
    type = "item_count",
    condition = {
      first_signal = Util.item_signal(request.item, request.quality),
      comparator = comparator,
      constant = constant
    }
  }
end

local function ready_condition()
  return {
    type = "circuit",
    condition = {
      first_signal = {type = "virtual", name = setting_value("il-ready-signal", "signal-green")},
      comparator = ">",
      constant = 0
    }
  }
end

local function set_request_section(entity, request, import_from, amount)
  local sections = entity and entity.valid and entity.get_logistic_sections()
  if not sections then
    return nil
  end
  local section = sections.add_section()
  if not section then
    return nil
  end
  section.group = request_group(request.id)
  section.set_slot(1, {
    value = Util.item_signal(request.item, request.quality),
    min = amount,
    max = amount,
    minimum_delivery_count = math.min(request.amount, amount),
    import_from = import_from
  })
  return section.index
end

local function remove_request_section(entity, section_index, request_id)
  local sections = entity and entity.valid and entity.get_logistic_sections()
  if not sections then
    return
  end
  local section = section_index and sections.get_section(section_index)
  if section and section.valid and section.group == request_group(request_id) then
    sections.remove_section(section.index)
    return
  end
  for _, candidate in pairs(sections.sections) do
    if candidate.valid and candidate.is_manual and candidate.group == request_group(request_id) then
      sections.remove_section(candidate.index)
      return
    end
  end
end

local function find_destination_pad(request, force)
  local surface = game.get_surface(request.destination_surface_index)
  if not surface then
    return nil
  end
  local desired_network_id = request.logistic_network_id
  local fallback
  for _, pad in pairs(surface.find_entities_filtered({type = "cargo-landing-pad", force = force})) do
    fallback = fallback or pad
    local network = pad.logistic_network
      or surface.find_logistic_network_by_position(pad.position, force)
    if desired_network_id and network and network.valid and network.network_id == desired_network_id then
      return pad
    end
  end
  if desired_network_id then
    return nil
  end
  return fallback
end

local function platform_capacity(platform, request)
  local hub = platform.hub
  local inventory = hub_inventory(hub)
  if not inventory then
    return 0
  end
  return inventory.get_insertable_count(Util.item_id(request.item, request.quality))
end

function Platforms.platform_capacity(platform, item, quality)
  return platform_capacity(platform, {item = item, quality = quality})
end

function Platforms.is_enrolled(force_index, platform_index)
  local state = State.ensure()
  return state.enrolled[force_index] and state.enrolled[force_index][platform_index] == true
end

function Platforms.set_enrolled(force_index, platform_index, enrolled)
  local state = State.ensure()
  state.enrolled[force_index] = state.enrolled[force_index] or {}
  state.enrolled[force_index][platform_index] = enrolled or nil
end

function Platforms.toggle_ready_signal(force_index, platform_index)
  local options = State.get_platform_options(force_index, platform_index)
  options.ready_signal = not options.ready_signal
  return options.ready_signal
end

function Platforms.pin_routes(force_index, platform)
  local routes = Util.route_pairs(platform)
  local all_pinned = #routes > 0
  for _, route in ipairs(routes) do
    if State.get_route_preference(force_index, route.source, route.destination) ~= platform.index then
      all_pinned = false
      break
    end
  end
  for _, route in ipairs(routes) do
    State.set_route_preference(force_index, route.source, route.destination, all_pinned and nil or platform.index)
  end
  return not all_pinned
end

function Platforms.is_pinned(force_index, platform)
  for _, route in ipairs(Util.route_pairs(platform)) do
    if State.get_route_preference(force_index, route.source, route.destination) == platform.index then return true end
  end
  return false
end

function Platforms.find_matching(request, force, source, destination)
  local state = State.ensure()
  local enrolled = state.enrolled[force.index] or {}
  local matches = {}
  local enrolled_count, idle_count, route_count, capacity_count = 0, 0, 0, 0
  for _, platform in pairs(force.platforms) do
    if platform.valid and enrolled[platform.index] then
      enrolled_count = enrolled_count + 1
      if not state.platform_shipments[platform.index] and not state.platform_transfers[platform.index] then
        idle_count = idle_count + 1
        local schedule = platform.schedule
        if schedule_has_location(schedule, source) and schedule_has_location(schedule, destination) then
          route_count = route_count + 1
          local capacity = platform_capacity(platform, request)
          if capacity >= request.amount then
            capacity_count = capacity_count + 1
            matches[#matches + 1] = {
              platform = platform,
              capacity = capacity,
              eta = Platforms.estimate_ticks_to(platform, source) or math.huge,
              pinned = State.get_route_preference(force.index, source, destination) == platform.index
            }
          end
        end
      end
    end
  end
  table.sort(matches, function(a, b)
    if a.pinned ~= b.pinned then return a.pinned end
    if a.eta ~= b.eta then return a.eta < b.eta end
    if a.capacity == b.capacity then
      return a.platform.index < b.platform.index
    end
    return a.capacity < b.capacity
  end)
  if matches[1] then return matches[1].platform end
  if enrolled_count == 0 then return nil, "No platforms are enrolled" end
  if idle_count == 0 then return nil, "All enrolled platforms are currently delivering other requests" end
  if route_count == 0 then return nil, "No available enrolled platform has both " .. source .. " and " .. destination .. " in its schedule" end
  if capacity_count == 0 then return nil, "Available routed platforms do not have space for " .. request.amount .. " items" end
  return nil, "No enrolled platform is currently eligible"
end

local function is_transfer_record(record, transfer, station, comparator, constant)
  if not record or not record.temporary or record.station ~= station then
    return false
  end
  local condition = record.wait_conditions and record.wait_conditions[1]
  local circuit = condition and condition.condition
  return condition and condition.type == "item_count"
    and circuit and circuit.comparator == comparator and circuit.constant == constant
    and circuit.first_signal and circuit.first_signal.name == transfer.item
end

local function remove_temporary_records(platform, transfer)
  local schedule = platform.schedule
  if not schedule then
    return
  end
  local records = schedule.records or {}
  for index = #records, 1, -1 do
    local record = records[index]
    if is_transfer_record(record, transfer, transfer.source, ">=", transfer.target_count)
      or is_transfer_record(record, transfer, transfer.destination, "<=", transfer.baseline_count) then
      table.remove(records, index)
    end
  end
  if #records == 0 then
    platform.schedule = nil
  else
    platform.schedule = {
      current = math.min(transfer.original_current or 1, #records),
      records = records
    }
  end
end

function Platforms.dispatch(request, platform, force)
  local state = State.ensure()
  local hub = platform.hub
  local inventory = hub_inventory(hub)
  if not inventory then
    return false, "Platform hub has no cargo inventory"
  end
  local source_available = SourceStock.available(request, force, request.source, true)
  if source_available < request.amount then
    return false, "Source no longer has enough provider stock for " .. request.amount .. " items"
  end
  local pad = find_destination_pad(request, force)
  if not pad then
    return false, "Destination has no cargo landing pad"
  end
  local schedule = platform.schedule
  if not schedule or not schedule.records or #schedule.records == 0 then
    return false, "Platform has no schedule"
  end

  local baseline = inventory.get_item_count(Util.item_id(request.item, request.quality))
  local target = baseline + request.amount
  local hub_section = set_request_section(hub, request, request.source, target)
  if not hub_section then
    return false, "Could not add a request section to the platform hub"
  end
  local pad_baseline = pad.get_item_count(Util.item_id(request.item, request.quality))
  local pad_section = set_request_section(pad, request, nil, pad_baseline + request.amount)
  if not pad_section then
    remove_request_section(hub, hub_section, request.id)
    return false, "Could not add a request section to the destination landing pad"
  end

  local records = Util.deep_copy(schedule.records)
  local source_index = #records + 1
  records[source_index] = {
    station = request.source,
    temporary = true,
    allows_unloading = false,
    wait_conditions = {item_condition(request, ">=", target)}
  }
  local options = State.get_platform_options(force.index, platform.index)
  if setting_value("il-enable-ready-signal", false) or options.ready_signal then
    records[source_index].wait_conditions[#records[source_index].wait_conditions + 1] = ready_condition()
  end
  records[source_index].wait_conditions[#records[source_index].wait_conditions + 1] = {
    type = "time", compare_type = "or", ticks = Constants.source_wait_timeout
  }
  records[source_index + 1] = {
    station = request.destination,
    temporary = true,
    allows_unloading = true,
    wait_conditions = {item_condition(request, "<=", baseline)}
  }
  platform.schedule = {current = source_index, records = records}

  local transfer = {
    request_id = request.id,
    force_index = force.index,
    platform_index = platform.index,
    platform_name = platform.name,
    source = request.source,
    destination = request.destination,
    item = request.item,
    quality = request.quality,
    amount = request.amount,
    baseline_count = baseline,
    target_count = target,
    original_current = schedule.current,
    hub_section_index = hub_section,
    pad_unit_number = pad.unit_number,
    pad_section_index = pad_section,
    pad_baseline_count = pad_baseline,
    started_tick = game.tick,
    loaded_full = false
  }
  state.active_transfers[request.id] = transfer
  state.platform_transfers[platform.index] = request.id
  request.platform_index = platform.index
  request.platform_name = platform.name
  request.status = "loading"
  request.dispatched_tick = game.tick
  request.last_reason = nil
  request.eta_tick = game.tick + (Platforms.estimate_ticks_to(platform, request.destination) or Constants.default_leg_ticks)
  return true
end

function Platforms.finish(request, status, reason)
  local state = State.ensure()
  local transfer = state.active_transfers[request.id]
  if transfer then
    local force = game.forces[transfer.force_index]
    local platform = Util.get_platform(force, transfer.platform_index)
    if platform then
      remove_temporary_records(platform, transfer)
      if platform.hub and platform.hub.valid then
        remove_request_section(platform.hub, transfer.hub_section_index, request.id)
      end
    end
    local pad = transfer.pad_unit_number and game.get_entity_by_unit_number(transfer.pad_unit_number)
    if pad then
      remove_request_section(pad, transfer.pad_section_index, request.id)
    end
    state.platform_transfers[transfer.platform_index] = nil
    state.active_transfers[request.id] = nil
    if status == "completed" and transfer.baseline_count > 0 then
      state.recent_returns[transfer.platform_index] = {
        item = transfer.item,
        quality = transfer.quality,
        amount = transfer.baseline_count,
        source = transfer.source,
        expires_tick = game.tick + Constants.default_leg_ticks * 2
      }
    end
  end

  request.status = status
  request.completed_tick = game.tick
  request.last_reason = reason
  if status ~= "denied" then
    state.request_by_key[request.key] = nil
  end
  local metric_key = request.source
  if metric_key then
    local metrics = state.source_metrics[metric_key] or {successes = 0, failures = 0}
    if status == "completed" then
      metrics.successes = metrics.successes + 1
    elseif status == "failed" then
      metrics.failures = metrics.failures + 1
    end
    state.source_metrics[metric_key] = metrics
  end
  State.add_history(request, status, reason)
end

local function monitor_transfer(state, request_id)
  local request = state.requests[request_id]
  local transfer = state.active_transfers[request_id]
  if not request or not transfer then
    state.active_transfers[request_id] = nil
    if transfer then state.platform_transfers[transfer.platform_index] = nil end
  else
    local force = game.forces[transfer.force_index]
    local platform = Util.get_platform(force, transfer.platform_index)
    if not platform or not platform.hub or not platform.hub.valid then
      Platforms.finish(request, "failed", "Enrolled platform is no longer available")
    else
      local inventory = hub_inventory(platform.hub)
      local count = inventory and inventory.get_item_count(Util.item_id(request.item, request.quality)) or 0
      local location = platform.space_location and platform.space_location.name
      if count >= transfer.target_count then
        transfer.loaded_full = true
        request.status = "delivering"
      elseif location == transfer.destination and count <= transfer.baseline_count then
        if transfer.loaded_full then
          Platforms.finish(request, "completed", "Cargo delivered to destination")
        else
          Platforms.finish(request, "failed", "Platform reached the destination without the full cargo")
        end
      elseif game.tick - transfer.started_tick > Constants.transfer_timeout then
        Platforms.finish(request, "failed", "Transfer timed out")
      end
    end
  end
end

function Platforms.start_monitor()
  local state = State.ensure()
  local ids = {}
  for request_id in pairs(state.active_transfers) do
    ids[#ids + 1] = request_id
  end
  table.sort(ids)
  state.monitor_job = {ids = ids, index = 1}
  return true
end

function Platforms.monitor_active()
  return State.ensure().monitor_job ~= nil
end

function Platforms.step_monitor(budget)
  local state = State.ensure()
  local job = state.monitor_job
  if not job then return true end
  budget = math.max(1, budget or Constants.monitor_work_per_tick)
  local processed = 0
  while processed < budget do
    local request_id = job.ids[job.index]
    if not request_id then
      state.monitor_job = nil
      break
    end
    monitor_transfer(state, request_id)
    job.index = job.index + 1
    processed = processed + 1
  end
  return state.monitor_job == nil
end

function Platforms.monitor()
  Platforms.start_monitor()
  while Platforms.monitor_active() do Platforms.step_monitor(math.huge) end
end

local function platform_snapshot(platform, force_index)
  local state = State.ensure()
  local previous = state.platform_status[platform.index]
  local shipment_id = state.platform_shipments[platform.index]
  local shipment = shipment_id and state.shipments[shipment_id]
  local request_id = shipment and shipment.demand_id or state.platform_transfers[platform.index]
  local request = request_id and state.demands[request_id]
  local location = platform.space_location and platform.space_location.name
  local distance = platform.distance
  local changed = not previous or previous.location ~= location or previous.distance ~= distance
    or previous.request_id ~= request_id
  local last_progress_tick = changed and game.tick or (previous.last_progress_tick or game.tick)
  local status = "idle"
  local destination
  if platform.paused then
    status = "paused"
  elseif shipment then
    status = shipment.status == "loading" and "loading" or "delivering"
    destination = shipment.status == "loading" and (shipment.source or (request and request.source)) or (request and request.destination)
  elseif request then
    status = request.status == "loading" and "loading" or "delivering"
    destination = request.status == "loading" and request.source or request.destination
  elseif platform.space_connection then
    status = "working"
    local schedule = platform.schedule
    local record = schedule and schedule.records and schedule.records[schedule.current or 1]
    destination = record and record.station or nil
  elseif state.recent_returns[platform.index] then
    local returning = state.recent_returns[platform.index]
    if game.tick <= returning.expires_tick and location ~= returning.source then
      status = "returning"
      destination = returning.source
    else
      state.recent_returns[platform.index] = nil
    end
  end
  if request and game.tick - last_progress_tick > Constants.stuck_timeout then status = "stuck" end
  return {
    platform_index = platform.index,
    force_index = force_index,
    name = platform.name,
    enrolled = Platforms.is_enrolled(force_index, platform.index),
    status = status,
    location = location,
    destination = destination,
    eta = destination and Platforms.estimate_ticks_to(platform, destination) or nil,
    request_id = request_id,
    shipment_id = shipment_id,
    last_progress_tick = last_progress_tick,
    distance = distance,
    speed = platform.speed or 0,
    reason = status == "stuck" and "No platform progress detected" or nil
  }
end

function Platforms.start_fleet_refresh()
  local state = State.ensure()
  local platforms = {}
  for _, force in pairs(game.forces) do
    for _, platform in pairs(force.platforms or {}) do
      if platform.valid then platforms[#platforms + 1] = {force_index = force.index, platform_index = platform.index} end
    end
  end
  table.sort(platforms, function(a, b)
    if a.platform_index == b.platform_index then return a.force_index < b.force_index end
    return a.platform_index < b.platform_index
  end)
  state.fleet_job = {platforms = platforms, index = 1, seen = {}}
  return true
end

function Platforms.fleet_refresh_active()
  return State.ensure().fleet_job ~= nil
end

function Platforms.step_fleet_refresh(budget)
  local state = State.ensure()
  local job = state.fleet_job
  if not job then return true end
  budget = math.max(1, budget or Constants.fleet_work_per_tick)
  local processed = 0
  while processed < budget do
    local entry = job.platforms[job.index]
    if not entry then
      for platform_index in pairs(state.platform_status) do
        if not job.seen[platform_index] then state.platform_status[platform_index] = nil end
      end
      state.fleet_job = nil
      break
    end
    local force = game.forces[entry.force_index]
    local platform = Util.get_platform(force, entry.platform_index)
    if platform then
      state.platform_status[platform.index] = platform_snapshot(platform, entry.force_index)
      job.seen[platform.index] = true
    end
    job.index = job.index + 1
    processed = processed + 1
  end
  return state.fleet_job == nil
end

function Platforms.refresh_fleet()
  Platforms.start_fleet_refresh()
  while Platforms.fleet_refresh_active() do Platforms.step_fleet_refresh(math.huge) end
end

function Platforms.cancel(request, reason)
  local state = State.ensure()
  if state.active_transfers[request.id] then
    Platforms.finish(request, "cancelled", reason or "Request removed")
  else
    -- Cancel all shipments belonging to this demand so platforms, hub
    -- sections, pad sections, and temporary schedule records are released.
    -- Without this, retiring an active demand (e.g. when a construction
    -- ghost is built or removed) orphans shipments and blocks platforms.
    local index = state.shipments_by_demand[request.id]
    if index then
      local ids = {}
      for shipment_id in pairs(index) do ids[#ids + 1] = shipment_id end
      table.sort(ids)
      for _, shipment_id in ipairs(ids) do
        Platforms.cancel_shipment(shipment_id, reason or "Request removed")
      end
    end
    Platforms.remove_pad_section(request.id)
    request.status = "cancelled"
    request.completed_tick = game.tick
    request.last_reason = reason
    state.request_by_key[request.key] = nil
    State.add_history(request, "cancelled", reason)
  end
end

function Platforms.fulfill(request, reason)
  local state = State.ensure()
  if state.active_transfers[request.id] then
    Platforms.finish(request, "completed", reason or "Destination need is fulfilled")
    return
  end
  local index = state.shipments_by_demand[request.id]
  if index then
    local ids = {}
    for shipment_id in pairs(index) do ids[#ids + 1] = shipment_id end
    table.sort(ids)
    for _, shipment_id in ipairs(ids) do
      local shipment = state.shipments[shipment_id]
      if shipment and shipment.status ~= "completed" and shipment.status ~= "failed"
        and shipment.status ~= "cancelled" then
        Platforms.cancel_shipment(shipment_id, reason or "Destination need is fulfilled")
      end
    end
  end
  Platforms.remove_pad_section(request.id)
  request.amount = 0
  request.observed_shortage = 0
  request.active_shipment_amount = 0
  request.unplanned_amount = 0
  request.status = "completed"
  request.completed_tick = game.tick
  request.last_reason = reason or "Destination need is fulfilled"
  state.request_by_key[request.key] = nil
  state.suppressions[request.key] = nil
  State.add_history(request, "completed", request.last_reason)
end

-- ---------------------------------------------------------------------------
-- Shipment execution (Task 6)
-- ---------------------------------------------------------------------------

local function shipment_request(shipment)
  return {
    id = shipment.id,
    item = shipment.item,
    quality = shipment.quality,
    amount = shipment.amount
  }
end

local function demand_request(demand)
  return {
    id = demand.id,
    item = demand.item,
    quality = demand.quality,
    amount = demand.observed_shortage or demand.amount or 0
  }
end

local function signal_quality_name(signal)
  local quality = signal and signal.quality
  if type(quality) == "table" or type(quality) == "userdata" then
    return quality.name or "normal"
  end
  return quality or "normal"
end

local function shipment_record_matches(record, shipment, station, allows_unloading, comparator, constant)
  if not record or not record.temporary or record.station ~= station
    or record.allows_unloading ~= allows_unloading then
    return false
  end
  local wait = record.wait_conditions and record.wait_conditions[1]
  local condition = wait and wait.condition
  local signal = condition and condition.first_signal
  return wait and wait.type == "item_count"
    and condition and condition.comparator == comparator and condition.constant == constant
    and signal and signal.type == "item" and signal.name == shipment.item
    and signal_quality_name(signal) == (shipment.quality or "normal")
end

local function is_shipment_temporary_record(record, shipment)
  if shipment_record_matches(record, shipment, shipment.destination, true, "<=", shipment.baseline_count) then
    return true
  end
  for _, leg in ipairs(shipment.pickup_legs or {}) do
    if shipment_record_matches(record, shipment, leg.source, false, ">=",
      (shipment.baseline_count or 0) + (leg.cumulative_target or 0)) then
      return true
    end
  end
  return false
end

local function has_shipment_destination_record(platform, shipment)
  local schedule = platform and platform.schedule
  for _, record in ipairs(schedule and schedule.records or {}) do
    if shipment_record_matches(record, shipment, shipment.destination, true, "<=", shipment.baseline_count) then
      return true
    end
  end
  return false
end

local function remove_shipment_temporary_records(platform, shipment)
  local schedule = platform.schedule
  if not schedule then return end
  local records = schedule.records or {}
  for index = #records, 1, -1 do
    local record = records[index]
    if is_shipment_temporary_record(record, shipment) then
      table.remove(records, index)
    end
  end
  if #records == 0 then
    platform.schedule = nil
  else
    platform.schedule = {
      current = math.min(shipment.original_current or 1, #records),
      records = records
    }
  end
end

local function active_shipment_count(state, demand_id)
  local count = 0
  local index = state.shipments_by_demand[demand_id]
  if not index then return 0 end
  for shipment_id in pairs(index) do
    local shipment = state.shipments[shipment_id]
    if shipment and shipment.status ~= "completed" and shipment.status ~= "failed"
      and shipment.status ~= "cancelled" then
      count = count + 1
    end
  end
  return count
end

function Platforms.ensure_pad_section(demand, force)
  local state = State.ensure()
  local existing = state.pad_sections[demand.id]
  if existing then
    local pad = existing.pad_unit_number and game.get_entity_by_unit_number(existing.pad_unit_number)
    if pad and pad.valid then
      return existing, pad
    end
    state.pad_sections[demand.id] = nil
  end
  local pad = find_destination_pad(demand, force)
  if not pad then
    return nil, nil
  end
  local pad_baseline = pad.get_item_count(Util.item_id(demand.item, demand.quality))
  local target = pad_baseline + (demand.observed_shortage or demand.amount or 0)
  local section_index = set_request_section(pad, demand_request(demand), nil, target)
  if not section_index then
    return nil, nil
  end
  local record = {
    pad_unit_number = pad.unit_number,
    pad_section_index = section_index,
    pad_baseline_count = pad_baseline,
    target = target
  }
  state.pad_sections[demand.id] = record
  return record, pad
end

function Platforms.remove_pad_section(demand_id)
  local state = State.ensure()
  local record = state.pad_sections[demand_id]
  if not record then return end
  local pad = record.pad_unit_number and game.get_entity_by_unit_number(record.pad_unit_number)
  if pad and pad.valid then
    remove_request_section(pad, record.pad_section_index, demand_id)
  end
  state.pad_sections[demand_id] = nil
end

function Platforms.execute_shipment(shipment, force)
  if shipment.status ~= "planned" then
    return false, "shipment is not in planned status"
  end
  local state = State.ensure()
  local platform = Util.get_platform(force, shipment.platform_index)
  if not platform or not platform.valid then
    return false, "platform is no longer available"
  end
  local hub = platform.hub
  local inventory = hub_inventory(hub)
  if not inventory then
    return false, "platform hub has no cargo inventory"
  end
  local schedule = platform.schedule
  if not schedule or not schedule.records or #schedule.records == 0 then
    return false, "platform has no schedule"
  end

  local hub_baseline = inventory.get_item_count(Util.item_id(shipment.item, shipment.quality))
  local original_current = schedule.current

  -- Write hub request sections for each pickup leg
  for _, leg in ipairs(shipment.pickup_legs) do
    local target = hub_baseline + leg.cumulative_target
    local section_index = set_request_section(hub, shipment_request(shipment), leg.source, target)
    if not section_index then
      -- Rollback any sections already written
      for _, prior_leg in ipairs(shipment.pickup_legs) do
        if prior_leg.hub_section_index then
          remove_request_section(hub, prior_leg.hub_section_index, shipment.id)
          prior_leg.hub_section_index = nil
        end
      end
      return false, "could not add a request section to the platform hub"
    end
    leg.hub_section_index = section_index
    leg.status = "loading"
  end

  -- Write or reuse the Demand-owned pad section
  local demand = state.demands[shipment.demand_id]
  if not demand then
    for _, leg in ipairs(shipment.pickup_legs) do
      remove_request_section(hub, leg.hub_section_index, shipment.id)
      leg.hub_section_index = nil
    end
    return false, "parent demand no longer exists"
  end
  local pad_record = Platforms.ensure_pad_section(demand, force)
  if not pad_record then
    for _, leg in ipairs(shipment.pickup_legs) do
      remove_request_section(hub, leg.hub_section_index, shipment.id)
      leg.hub_section_index = nil
    end
    return false, "could not create a destination landing-pad request section"
  end

  -- Append temporary schedule records (never mutate permanent records)
  local records = Util.deep_copy(schedule.records)
  local first_source_index = #records + 1
  local options = State.get_platform_options(force.index, platform.index)
  for _, leg in ipairs(shipment.pickup_legs) do
    local record = {
      station = leg.source,
      temporary = true,
      allows_unloading = false,
      wait_conditions = {
        item_condition(shipment_request(shipment), ">=", hub_baseline + leg.cumulative_target)
      }
    }
    if setting_value("il-enable-ready-signal", false) or options.ready_signal then
      record.wait_conditions[#record.wait_conditions + 1] = ready_condition()
    end
    record.wait_conditions[#record.wait_conditions + 1] = {
      type = "time", compare_type = "or", ticks = Constants.source_wait_timeout
    }
    records[#records + 1] = record
  end
  local destination_record = {
    station = shipment.destination,
    temporary = true,
    allows_unloading = true,
    wait_conditions = {
      item_condition(shipment_request(shipment), "<=", hub_baseline)
    }
  }
  records[#records + 1] = destination_record
  platform.schedule = {current = first_source_index, records = records}

  -- Store execution metadata
  shipment.baseline_count = hub_baseline
  shipment.original_current = original_current
  shipment.original_schedule_current = original_current
  shipment.pad_unit_number = pad_record.pad_unit_number
  shipment.pad_section_index = pad_record.pad_section_index
  shipment.pad_baseline_count = pad_record.pad_baseline_count
  shipment.destination_baseline_current = demand.current or 0
  shipment.destination_baseline_shortage = demand.observed_shortage or demand.amount or 0
  shipment.destination_observation_tick = demand.last_seen_tick or game.tick
  shipment.max_loaded_amount = 0
  shipment.delivered_amount = 0
  shipment.status = "loading"
  shipment.started_tick = game.tick

  if demand.status ~= "loading" and demand.status ~= "delivering" then
    demand.status = "loading"
  end
  return true
end

function Platforms.execute_pending_shipments(force)
  local state = State.ensure()
  local ids = {}
  for shipment_id, shipment in pairs(state.shipments) do
    if shipment.status == "planned" and shipment.force_index == force.index then
      ids[#ids + 1] = shipment_id
    end
  end
  table.sort(ids)
  for _, shipment_id in ipairs(ids) do
    local shipment = state.shipments[shipment_id]
    if shipment and shipment.status == "planned" then
      local ok, reason = Platforms.execute_shipment(shipment, force)
      if not ok then
        Platforms.cancel_shipment(shipment_id, reason or "execution failed")
      end
    end
  end
end

function Platforms.cancel_shipment(shipment_id, reason)
  local state = State.ensure()
  local shipment = state.shipments[shipment_id]
  if not shipment then return end
  local force = game.forces[shipment.force_index]
  local platform = force and Util.get_platform(force, shipment.platform_index)
  if platform then
    for _, leg in ipairs(shipment.pickup_legs or {}) do
      if leg.hub_section_index and platform.hub and platform.hub.valid then
        remove_request_section(platform.hub, leg.hub_section_index, shipment.id)
      end
    end
    remove_shipment_temporary_records(platform, shipment)
  end
  local demand_id = shipment.demand_id
  State.cancel_shipment(shipment_id)
  -- Remove pad section if no more active shipments for this demand
  if active_shipment_count(state, demand_id) == 0 then
    Platforms.remove_pad_section(demand_id)
  end
  local demand = state.demands[demand_id]
  if demand then
    demand.active_shipment_amount = State.active_shipment_amount(demand_id)
    demand.unplanned_amount = math.max(0, (demand.observed_shortage or demand.amount or 0) - demand.active_shipment_amount)
    if demand.unplanned_amount > 0 and demand.status ~= "completed" and demand.status ~= "cancelled" then
      demand.status = "approved"
    end
  end
end

-- Remove a shipment from state regardless of status. Active shipments are
-- cancelled first so hub/pad sections and temporary schedule records are
-- cleaned up; terminal shipments are deleted directly.
function Platforms.remove_shipment(shipment_id, reason)
  local state = State.ensure()
  local shipment = state.shipments[shipment_id]
  if not shipment then return end
  if shipment.status == "completed" or shipment.status == "cancelled" or shipment.status == "failed" then
    State.delete_shipment(shipment_id)
  else
    Platforms.cancel_shipment(shipment_id, reason or "cleared by player")
  end
end

function Platforms.finish_shipment(shipment_id, status, reason)
  local state = State.ensure()
  local shipment = state.shipments[shipment_id]
  if not shipment then return end
  local force = game.forces[shipment.force_index]
  local platform = force and Util.get_platform(force, shipment.platform_index)
  if platform then
    for _, leg in ipairs(shipment.pickup_legs or {}) do
      if leg.hub_section_index and platform.hub and platform.hub.valid then
        remove_request_section(platform.hub, leg.hub_section_index, shipment.id)
      end
    end
    remove_shipment_temporary_records(platform, shipment)
  end
  shipment.status = status
  shipment.completed_tick = game.tick
  shipment.last_reason = reason
  if state.platform_shipments[shipment.platform_index] == shipment.id then
    state.platform_shipments[shipment.platform_index] = nil
  end
  local demand_id = shipment.demand_id
  local demand = state.demands[demand_id]
  if demand then
    demand.active_shipment_amount = State.active_shipment_amount(demand_id)
    demand.unplanned_amount = math.max(0, (demand.observed_shortage or demand.amount or 0) - demand.active_shipment_amount)
  end
  -- Update source metrics
  for _, leg in ipairs(shipment.pickup_legs or {}) do
    local metric_key = leg.source
    if metric_key then
      local metrics = state.source_metrics[metric_key] or {successes = 0, failures = 0}
      if status == "completed" then
        metrics.successes = metrics.successes + 1
      elseif status == "failed" then
        metrics.failures = metrics.failures + 1
      end
      state.source_metrics[metric_key] = metrics
    end
  end
  -- Remove pad section if no more active shipments for this demand
  if active_shipment_count(state, demand_id) == 0 then
    Platforms.remove_pad_section(demand_id)
    if demand then
      if status == "completed" and (demand.observed_shortage or 0) <= 0 then
        demand.status = "completed"
        demand.completed_tick = game.tick
        demand.last_reason = nil
        state.demand_by_key[demand.key] = nil
      elseif status == "failed" and demand.unplanned_amount > 0 then
        demand.status = "approved"
      elseif status == "completed" and demand.unplanned_amount > 0 then
        local observation_advanced = demand.last_seen_tick
          and demand.last_seen_tick > (shipment.destination_observation_tick or shipment.started_tick or 0)
        if observation_advanced then
          demand.status = "approved"
          demand.last_reason = "Partial delivery confirmed; remainder awaiting routing"
        else
          demand.status = "dispatching"
          demand.reconcile_pending = true
          demand.last_reason = "Delivery confirmed; awaiting destination reconciliation"
        end
      end
    end
  end
  State.add_history(demand or {id = demand_id, item = shipment.item, quality = shipment.quality,
    amount = shipment.amount, source = shipment.pickup_legs and shipment.pickup_legs[1] and shipment.pickup_legs[1].source,
    destination = shipment.destination}, status, reason)
end

function Platforms.check_local_fulfillment(demand)
  if (demand.observed_shortage or 0) > 0 then
    return false
  end
  Platforms.fulfill(demand, "Fulfilled by local logistics")
  return true
end

-- ---------------------------------------------------------------------------
-- Bounded shipment execution (Task 7)
-- ---------------------------------------------------------------------------

local function sorted_shipment_ids(values)
  local keys = {}
  for key in pairs(values or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

function Platforms.start_shipment_execution()
  local state = State.ensure()
  local ids = {}
  for shipment_id, shipment in pairs(state.shipments) do
    if shipment.status == "planned" then
      ids[#ids + 1] = shipment_id
    end
  end
  if #ids == 0 then return false end
  table.sort(ids)
  state.shipment_execution_job = {ids = ids, index = 1}
  return true
end

function Platforms.shipment_execution_active()
  return State.ensure().shipment_execution_job ~= nil
end

function Platforms.step_shipment_execution(budget)
  local state = State.ensure()
  local job = state.shipment_execution_job
  if not job then return true end
  budget = math.max(1, budget or Constants.shipment_execution_work_per_tick)
  local processed = 0
  while processed < budget do
    local shipment_id = job.ids[job.index]
    if not shipment_id then
      state.shipment_execution_job = nil
      break
    end
    local shipment = state.shipments[shipment_id]
    if shipment and shipment.status == "planned" then
      local force = game.forces[shipment.force_index]
      if force then
        local ok, reason = Platforms.execute_shipment(shipment, force)
        if not ok then
          Platforms.cancel_shipment(shipment_id, reason or "execution failed")
        end
      else
        Platforms.cancel_shipment(shipment_id, "team no longer available")
      end
    end
    job.index = job.index + 1
    processed = processed + 1
  end
  return state.shipment_execution_job == nil
end

-- ---------------------------------------------------------------------------
-- Shipment dirty queue (Task 7)
-- ---------------------------------------------------------------------------

function Platforms.mark_shipment_dirty(shipment_id)
  local state = State.ensure()
  state.shipment_dirty[shipment_id] = true
end

function Platforms.shipment_dirty_active()
  return next(State.ensure().shipment_dirty) ~= nil
end

function Platforms.step_shipment_dirty(budget)
  local state = State.ensure()
  if not next(state.shipment_dirty) then return true end
  budget = math.max(1, budget or Constants.shipment_dirty_work_per_tick)
  local ids = sorted_shipment_ids(state.shipment_dirty)
  local processed = 0
  for index = 1, #ids do
    if processed >= budget then return false end
    local shipment_id = ids[index]
    state.shipment_dirty[shipment_id] = nil
    local shipment = state.shipments[shipment_id]
    if shipment and shipment.status ~= "completed"
      and shipment.status ~= "failed" and shipment.status ~= "cancelled" then
      Platforms.maintain_shipment(shipment_id)
    end
    processed = processed + 1
  end
  return next(state.shipment_dirty) == nil
end

-- ---------------------------------------------------------------------------
-- Bounded shipment maintenance (Task 7)
-- ---------------------------------------------------------------------------

local function shipment_last_leg(shipment)
  local legs = shipment.pickup_legs or {}
  return legs[#legs]
end

local function shipment_cumulative_target(shipment)
  local leg = shipment_last_leg(shipment)
  return leg and leg.cumulative_target or shipment.amount or 0
end

local function platform_at_location(platform, location)
  return platform and platform.valid
    and platform.space_location and platform.space_location.name == location
end

local function update_pickup_leg_status(shipment, platform, hub_count, baseline_count)
  local location = platform and platform.valid
    and platform.space_location and platform.space_location.name
  for _, leg in ipairs(shipment.pickup_legs or {}) do
    if leg.status == "loading" then
      if hub_count >= baseline_count + (leg.cumulative_target or 0) then
        leg.status = "completed"
      elseif location and location ~= leg.source then
        -- Platform left this source with less than planned (short pickup)
        leg.status = "skipped"
      end
    end
  end
end

local function destination_received_amount(shipment, demand, pad)
  local received = 0
  if pad and pad.valid and pad.get_item_count then
    local pad_count = pad.get_item_count(Util.item_id(shipment.item, shipment.quality))
    received = math.max(received, pad_count - (shipment.pad_baseline_count or pad_count))
  end
  if demand then
    received = math.max(received, (demand.current or 0) - (shipment.destination_baseline_current or 0))
    received = math.max(received,
      (shipment.destination_baseline_shortage or demand.observed_shortage or 0) - (demand.observed_shortage or 0))
  end
  return math.max(0, math.min(shipment.amount or 0, received))
end

function Platforms.maintain_shipment(shipment_id)
  local state = State.ensure()
  local shipment = state.shipments[shipment_id]
  if not shipment then return end
  if shipment.status == "completed" or shipment.status == "failed"
    or shipment.status == "cancelled" then return end

  local demand = state.demands[shipment.demand_id]

  -- Check local fulfillment first
  if demand and (demand.observed_shortage or 0) <= 0 then
    Platforms.check_local_fulfillment(demand)
    return
  end

  -- 1. Is the platform still valid?
  local force = game.forces[shipment.force_index]
  local platform = force and Util.get_platform(force, shipment.platform_index)
  if not platform or not platform.valid then
    Platforms.finish_shipment(shipment_id, "failed", "platform is no longer available")
    return
  end

  -- 2. Is the hub still accessible?
  local hub = platform.hub
  if not hub or not hub.valid then
    Platforms.finish_shipment(shipment_id, "failed", "platform hub is no longer accessible")
    return
  end
  local inventory = hub_inventory(hub)
  if not inventory then
    Platforms.finish_shipment(shipment_id, "failed", "platform hub has no cargo inventory")
    return
  end

  local item_id = Util.item_id(shipment.item, shipment.quality)
  local hub_count = inventory.get_item_count(item_id)
  local baseline_count = tonumber(shipment.baseline_count)
  if not baseline_count then
    local target_count = tonumber(shipment.target_count)
    local amount = tonumber(shipment.amount or shipment.allocated_amount)
    if target_count and amount then
      baseline_count = math.max(0, target_count - amount)
    else
      -- Older persisted Shipments did not always store a hub baseline. The
      -- current count is the only safe observation that avoids treating
      -- already-present cargo as newly loaded.
      baseline_count = hub_count
    end
    shipment.baseline_count = baseline_count
  end
  shipment.max_loaded_amount = math.max(shipment.max_loaded_amount or 0,
    math.max(0, hub_count - baseline_count))
  local cumulative_target = baseline_count + shipment_cumulative_target(shipment)
  local location = platform.space_location and platform.space_location.name

  local pad = shipment.pad_unit_number and game.get_entity_by_unit_number(shipment.pad_unit_number)
  if not pad or not pad.valid then
    Platforms.finish_shipment(shipment_id, "failed", "destination landing pad is no longer available")
    return
  end
  if location ~= shipment.destination and not has_shipment_destination_record(platform, shipment) then
    Platforms.finish_shipment(shipment_id, "failed", "shipment destination schedule record is missing")
    return
  end

  -- 5. Has the shipment timed out?
  if shipment.started_tick and game.tick - shipment.started_tick > Constants.transfer_timeout then
    Platforms.finish_shipment(shipment_id, "failed", "shipment timed out")
    return
  end

  -- Update pickup leg statuses
  update_pickup_leg_status(shipment, platform, hub_count, baseline_count)

  if shipment.status == "loading" then
    -- 3. Has the cargo been loaded? (hub count >= cumulative target of last leg)
    if hub_count >= cumulative_target then
      shipment.status = "delivering"
      if demand then demand.status = "delivering" end
      return
    end

    if location == shipment.destination then
      shipment.status = "delivering"
      shipment.destination_arrival_tick = shipment.destination_arrival_tick or game.tick
      if demand then demand.status = "delivering" end
      return
    end
  elseif shipment.status == "delivering" then
    -- 4. Has the cargo been delivered? (platform at destination AND hub count <= baseline)
    if platform_at_location(platform, shipment.destination) then
      if hub_count <= baseline_count then
        local delivered_amount = destination_received_amount(shipment, demand, pad)
        if delivered_amount > 0 then
          shipment.delivered_amount = delivered_amount
          Platforms.finish_shipment(shipment_id, "completed", "cargo delivered to destination")
          return
        end
        if shipment.destination_arrival_tick
          and game.tick - shipment.destination_arrival_tick > Constants.delivery_confirmation_timeout then
          Platforms.finish_shipment(shipment_id, "failed", "destination receipt was not confirmed")
          return
        end
      end
      -- Platform at destination but cargo not yet unloaded; keep waiting
    end
  end
end

function Platforms.start_shipment_maintenance()
  local state = State.ensure()
  local ids = {}
  for shipment_id, shipment in pairs(state.shipments) do
    if shipment.status == "loading" or shipment.status == "delivering" then
      ids[#ids + 1] = shipment_id
    end
  end
  table.sort(ids)
  state.shipment_maintenance_job = {ids = ids, index = 1}
  return true
end

function Platforms.shipment_maintenance_active()
  return State.ensure().shipment_maintenance_job ~= nil
end

function Platforms.step_shipment_maintenance(budget)
  local state = State.ensure()
  local job = state.shipment_maintenance_job
  if not job then return true end
  budget = math.max(1, budget or Constants.shipment_maintenance_work_per_tick)
  local processed = 0
  while processed < budget do
    local shipment_id = job.ids[job.index]
    if not shipment_id then
      state.shipment_maintenance_job = nil
      break
    end
    Platforms.maintain_shipment(shipment_id)
    job.index = job.index + 1
    processed = processed + 1
  end
  return state.shipment_maintenance_job == nil
end

return Platforms
