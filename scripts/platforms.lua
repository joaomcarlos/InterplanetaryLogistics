local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")

local Platforms = {}

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
  if not hub or not hub.valid then
    return 0
  end
  local inventory = hub.get_main_inventory()
  if not inventory then
    return 0
  end
  return inventory.get_insertable_count(Util.item_id(request.item, request.quality))
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
  for _, platform in pairs(force.platforms) do
    if platform.valid and enrolled[platform.index] and not state.platform_transfers[platform.index] then
      local schedule = platform.schedule
      if schedule_has_location(schedule, source) and schedule_has_location(schedule, destination) then
        local capacity = platform_capacity(platform, request)
        if capacity >= request.amount then
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
  table.sort(matches, function(a, b)
    if a.pinned ~= b.pinned then return a.pinned end
    if a.eta ~= b.eta then return a.eta < b.eta end
    if a.capacity == b.capacity then
      return a.platform.index < b.platform.index
    end
    return a.capacity < b.capacity
  end)
  return matches[1] and matches[1].platform or nil
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
  local inventory = hub and hub.valid and hub.get_main_inventory()
  if not inventory then
    return false, "Platform hub has no cargo inventory"
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

  State.release_reservation(request.id)

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
    State.release_reservation(request_id)
    if transfer then state.platform_transfers[transfer.platform_index] = nil end
  else
    local force = game.forces[transfer.force_index]
    local platform = Util.get_platform(force, transfer.platform_index)
    if not platform or not platform.hub or not platform.hub.valid then
      Platforms.finish(request, "failed", "Enrolled platform is no longer available")
    else
      local inventory = platform.hub.get_main_inventory()
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
  local request_id = state.platform_transfers[platform.index]
  local request = request_id and state.requests[request_id]
  local location = platform.space_location and platform.space_location.name
  local distance = platform.distance
  local changed = not previous or previous.location ~= location or previous.distance ~= distance
    or previous.request_id ~= request_id
  local last_progress_tick = changed and game.tick or (previous.last_progress_tick or game.tick)
  local status = "idle"
  local destination
  if platform.paused then
    status = "paused"
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
  if State.ensure().active_transfers[request.id] then
    Platforms.finish(request, "cancelled", reason or "Request removed")
  else
    State.release_reservation(request.id)
    request.status = "cancelled"
    request.completed_tick = game.tick
    request.last_reason = reason
    State.ensure().request_by_key[request.key] = nil
    State.add_history(request, "cancelled", reason)
  end
end

return Platforms
