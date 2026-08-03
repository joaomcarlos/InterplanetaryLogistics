local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")
local Router = require("scripts.router")
local Platforms = require("scripts.platforms")

local Demands = {}

local function quality_name(quality)
  local kind = type(quality)
  if kind == "table" or kind == "userdata" then return quality.name or "normal" end
  return quality or "normal"
end

local function auto_approve_tick()
  return game.tick + settings.global["il-auto-approve-seconds"].value * 60
end

local function create_request(key, data)
  local state = State.ensure()
  local existing_id = state.request_by_key[key]
  local existing = existing_id and state.requests[existing_id]
  if existing and (Constants.active_statuses[existing.status] or existing.status == "denied") then
    if existing.status == "queued" or existing.status == "approved" or existing.status == "denied" then
      existing.amount = data.amount
      existing.requested = data.requested
      existing.current = data.current
    end
    existing.last_seen_tick = game.tick
    return existing
  end
  if state.suppressions[key] then
    return nil
  end
  local request = data
  request.id = state.next_request_id
  state.next_request_id = state.next_request_id + 1
  request.key = key
  request.status = "queued"
  request.created_tick = game.tick
  request.last_seen_tick = game.tick
  request.auto_approve_tick = auto_approve_tick()
  request.priority = request.priority or 0
  state.requests[request.id] = request
  state.request_by_key[key] = request.id
  return request
end

local function targeted_count(point, item, quality)
  local count = 0
  for _, stack in pairs(point.targeted_items_deliver or {}) do
    if stack.name == item and (stack.quality or "normal") == quality then
      count = count + stack.count
    end
  end
  return count
end

local function collect_chest(chest, configured, groups)
  local point = chest.get_requester_point()
  if not point then
    return
  end
  local network = point.logistic_network
  for _, filter in pairs(point.filters or {}) do
    if filter.name and (not filter.type or filter.type == "item") and filter.count > 0 then
      local quality = quality_name(filter.quality)
      local item = Util.item_id(filter.name, quality)
      local inside = chest.get_item_count(item)
      local incoming = targeted_count(point, filter.name, quality)
      local local_need = math.max(0, filter.count - inside - incoming)
      local key = table.concat({"chest", chest.unit_number, filter.name, quality}, "|")
      configured[key] = true
      if local_need > 0 then
        local network_id = network and network.valid and network.network_id or 0
        local group_key = table.concat({chest.force.index, chest.surface.index, network_id, filter.name, quality}, "|")
        local group = groups[group_key]
        if not group then
          group = {entries = {}}
          groups[group_key] = group
        end
        group.entries[#group.entries + 1] = {
          key = key,
          local_need = local_need,
          data = {
          origin = "chest",
          chest_unit_number = chest.unit_number,
          force_index = chest.force.index,
          destination_surface_index = chest.surface.index,
          destination = Util.surface_location(chest.surface),
          logistic_network_id = network and network.valid and network.network_id or nil,
          item = filter.name,
          quality = quality,
          amount = local_need,
          requested = filter.count,
          current = inside + incoming,
          position = {x = chest.position.x, y = chest.position.y}
          }
        }
      end
    end
  end
end

local function publish_chest_group(group, needed)
  table.sort(group.entries, function(a, b)
    return a.data.chest_unit_number < b.data.chest_unit_number
  end)
  for _, entry in ipairs(group.entries) do
    needed[entry.key] = true
    entry.data.amount = entry.local_need
    create_request(entry.key, entry.data)
  end
end

local function publish_chest_groups(groups, needed)
  for _, group in pairs(groups) do
    publish_chest_group(group, needed)
  end
end

local construction_entity_types = {"entity-ghost", "tile-ghost", "item-request-proxy"}

local function surface_networks(force, surface)
  local by_surface = force.logistic_networks or {}
  return by_surface[surface.name] or by_surface[surface.index] or {}
end

local function sorted_construction_surfaces(force)
  local result = {}
  local seen = {}
  for _, surface in pairs(game.surfaces or {}) do
    if surface.valid and not seen[surface.index] and next(surface_networks(force, surface)) then
      seen[surface.index] = true
      result[#result + 1] = surface.index
    end
  end
  table.sort(result)
  return result
end

local function sorted_networks(force, surface)
  local result = {}
  for _, network in pairs(surface_networks(force, surface)) do
    if network.valid ~= false then result[#result + 1] = network end
  end
  table.sort(result, function(a, b) return (a.network_id or 0) < (b.network_id or 0) end)
  return result
end

local function sorted_cells(network)
  local result = {}
  for _, cell in pairs(network.cells or {}) do
    if cell.valid ~= false and cell.owner and cell.owner.valid and cell.owner.position then
      result[#result + 1] = cell
    end
  end
  table.sort(result, function(a, b)
    local ap, bp = a.owner.position, b.owner.position
    if ap.x == bp.x then
      if ap.y == bp.y then return (a.owner.unit_number or 0) < (b.owner.unit_number or 0) end
      return ap.y < bp.y
    end
    return ap.x < bp.x
  end)
  return result
end

local function entity_key(surface_index, entity)
  if entity.unit_number then
    return table.concat({surface_index, entity.name, entity.unit_number}, "|")
  end
  local position = entity.position or {x = 0, y = 0}
  return table.concat({surface_index, entity.name, position.x, position.y}, "|")
end

local function add_construction_item(context, network, surface, position, name, quality, count)
  if not name or not count or count <= 0 then return end
  quality = quality_name(quality)
  local network_id = network.network_id or 0
  local key = table.concat({surface.index, network_id, name, quality}, "|")
  local entry = context.aggregate[key]
  if not entry then
    entry = {
      surface_index = surface.index,
      network_id = network_id,
      network = network,
      item = name,
      quality = quality,
      amount = 0,
      position = {x = position.x, y = position.y}
    }
    context.aggregate[key] = entry
  end
  entry.amount = entry.amount + count
end

local function add_placement_item(context, network, surface, entity)
  local prototype = entity.ghost_prototype
  if not prototype or prototype.valid == false then return end
  local items = prototype.items_to_place_this
  local item = items and (items[1] or items)
  if item and item.name then
    add_construction_item(
      context,
      network,
      surface,
      entity.position,
      item.name,
      entity.quality or item.quality,
      item.count or item.amount or 1
    )
  end
end

local function add_item_requests(context, network, surface, entity)
  for _, request in pairs(entity.item_requests or {}) do
    add_construction_item(
      context,
      network,
      surface,
      entity.position,
      request.name,
      request.quality,
      request.count
    )
  end
end

local function aggregate_construction_entity(context, network, surface, entity)
  if not entity or entity.valid == false or not entity.is_registered_for_construction then return end
  if not entity.is_registered_for_construction() then return end
  local key = entity_key(surface.index, entity)
  if context.seen[key] then return end
  context.seen[key] = true

  if entity.name == "item-request-proxy" then
    add_item_requests(context, network, surface, entity)
  elseif entity.name == "entity-ghost" then
    add_placement_item(context, network, surface, entity)
    add_item_requests(context, network, surface, entity)
  elseif entity.name == "tile-ghost" then
    add_placement_item(context, network, surface, entity)
  end
end

local function start_construction_context(force)
  return {
    force = force,
    surface_indices = sorted_construction_surfaces(force),
    surface_index = 1,
    network_index = 1,
    cell_index = 1,
    entity_index = 1,
    seen = {},
    aggregate = {},
    aggregate_keys = nil,
    aggregate_index = 1,
    phase = "surface"
  }
end

local function publish_construction_entry(context, entry, configured, needed)
  local surface = game.get_surface(entry.surface_index)
  if not surface then return end
  local request_key = table.concat({
    "alert",
    context.force.index,
    entry.surface_index,
    entry.network_id,
    entry.item,
    entry.quality
  }, "|")
  configured[request_key] = true

  local available = 0
  if entry.network and entry.network.valid ~= false and entry.network.get_item_count then
    available = math.max(0, entry.network.get_item_count(Util.item_id(entry.item, entry.quality)) or 0)
  end
  local shortage = math.max(0, entry.amount - available)
  if shortage <= 0 then return end

  needed[request_key] = true
  create_request(request_key, {
    origin = "construction-alert",
    force_index = context.force.index,
    destination_surface_index = surface.index,
    destination = Util.surface_location(surface),
    logistic_network_id = entry.network_id,
    item = entry.item,
    quality = entry.quality,
    amount = shortage,
    requested = entry.amount,
    current = math.min(available, entry.amount),
    position = entry.position
  })
end

local function step_construction_context(context, budget, configured, needed)
  local processed = 0
  while processed < budget do
    if context.phase == "surface" then
      local surface_index = context.surface_indices[context.surface_index]
      if not surface_index then
        context.aggregate_keys = {}
        for key in pairs(context.aggregate) do context.aggregate_keys[#context.aggregate_keys + 1] = key end
        table.sort(context.aggregate_keys)
        context.aggregate_index = 1
        context.phase = "publish"
        return false, processed
      end
      context.surface = game.get_surface(surface_index)
      context.surface_index = context.surface_index + 1
      context.networks = context.surface and sorted_networks(context.force, context.surface) or {}
      context.network_index = 1
      context.phase = "network"
      processed = processed + 1
    elseif context.phase == "network" then
      local network = context.networks[context.network_index]
      if not network then
        context.networks = nil
        context.surface = nil
        context.phase = "surface"
      else
        context.network_index = context.network_index + 1
        if network.valid ~= false then
          context.network = network
          context.cells = sorted_cells(network)
          context.cell_index = 1
          context.phase = "cell"
        end
        processed = processed + 1
      end
    elseif context.phase == "cell" then
      local cell = context.cells[context.cell_index]
      if not cell then
        context.cells = nil
        context.network = nil
        context.phase = "network"
      else
        context.cell_index = context.cell_index + 1
        if cell.valid ~= false
          and context.network
          and context.network.valid ~= false
          and context.surface
          and context.surface.valid ~= false
        then
          local owner = cell.owner
          if owner and owner.valid ~= false and owner.position then
            local radius = cell.construction_radius or 0
            local position = owner.position
            context.entities = context.surface.find_entities_filtered({
              area = {
                {x = position.x - radius, y = position.y - radius},
                {x = position.x + radius, y = position.y + radius}
              },
              type = construction_entity_types,
              force = context.force
            }) or {}
            context.entity_index = 1
            context.phase = "entity"
          end
        end
        processed = processed + 1
      end
    elseif context.phase == "entity" then
      if not context.network or context.network.valid == false then
        context.entities = nil
        context.cells = nil
        context.network = nil
        context.phase = "network"
        processed = processed + 1
      else
        local entity = context.entities[context.entity_index]
        if not entity then
          context.entities = nil
          context.phase = "cell"
        else
          context.entity_index = context.entity_index + 1
          aggregate_construction_entity(context, context.network, context.surface, entity)
          processed = processed + 1
        end
      end
    elseif context.phase == "publish" then
      local key = context.aggregate_keys[context.aggregate_index]
      if not key then return true, processed end
      publish_construction_entry(context, context.aggregate[key], configured, needed)
      context.aggregate_index = context.aggregate_index + 1
      processed = processed + 1
    else
      return true, processed
    end
  end
  return false, processed
end

local function sorted_forces()
  local result = {}
  local seen = {}
  for _, force in pairs(game.forces) do
    if force.valid and not seen[force.index] then
      seen[force.index] = true
      result[#result + 1] = force
    end
  end
  table.sort(result, function(a, b) return a.index < b.index end)
  return result
end

local function scan_construction(configured, needed)
  for _, force in ipairs(sorted_forces()) do
    local context = start_construction_context(force)
    local done = false
    while not done do done = step_construction_context(context, 1000, configured, needed) end
  end
end

local function retire_request(state, key, configured, needed)
  local request_id = state.request_by_key[key]
  local request = request_id and state.requests[request_id]
  if request then
    if request.status == "denied" and not configured[key] then
      state.suppressions[key] = nil
      state.request_by_key[key] = nil
      request.status = "cancelled"
      request.last_reason = "Original request was removed"
    elseif Constants.active_statuses[request.status] and not needed[key] then
      Platforms.cancel(request, "Need was fulfilled or removed")
    end
  end
end

local function retire_unseen(configured, needed)
  local state = State.ensure()
  for key in pairs(state.request_by_key) do
    retire_request(state, key, configured, needed)
  end
end

function Demands.scan()
  local state = State.ensure()
  state.scan_job = nil
  local configured = {}
  local needed = {}
  local groups = {}
  for unit_number in pairs(state.chests) do
    local chest = game.get_entity_by_unit_number(unit_number)
    if chest and chest.valid and chest.name == Constants.chest_name then
      collect_chest(chest, configured, groups)
    else
      state.chests[unit_number] = nil
    end
  end
  publish_chest_groups(groups, needed)
  scan_construction(configured, needed)
  retire_unseen(configured, needed)
end

local function sorted_scan_chests(chests)
  local ids = {}
  for unit_number in pairs(chests) do ids[#ids + 1] = unit_number end
  table.sort(ids)
  return ids
end

local function scan_force_indices()
  local result = {}
  for _, force in ipairs(sorted_forces()) do result[#result + 1] = force.index end
  return result
end

function Demands.start_scan()
  local state = State.ensure()
  if state.scan_job or state.process_job then return false end
  state.scan_job = {
    phase = "chests",
    chest_ids = sorted_scan_chests(state.chests),
    chest_index = 1,
    configured = {},
    needed = {},
    groups = {},
    construction_forces = scan_force_indices(),
    construction_index = 1,
    construction_context = nil
  }
  return true
end

function Demands.scan_active()
  return State.ensure().scan_job ~= nil
end

function Demands.step_scan(budget)
  local state = State.ensure()
  local job = state.scan_job
  if not job then return true end
  budget = math.max(1, budget or Constants.scan_work_per_tick)
  local processed = 0
  while processed < budget and job do
    if job.phase == "chests" then
      local unit_number = job.chest_ids[job.chest_index]
      if not unit_number then
        job.group_keys = {}
        for key in pairs(job.groups) do job.group_keys[#job.group_keys + 1] = key end
        table.sort(job.group_keys)
        job.group_index = 1
        job.phase = "publish"
        return false
      else
        local chest = game.get_entity_by_unit_number(unit_number)
        if chest and chest.valid and chest.name == Constants.chest_name then
          collect_chest(chest, job.configured, job.groups)
        else
          state.chests[unit_number] = nil
        end
        job.chest_index = job.chest_index + 1
        processed = processed + 1
      end
    elseif job.phase == "publish" then
      local key = job.group_keys[job.group_index]
      if not key then
        job.phase = "construction"
        return false
      else
        publish_chest_group(job.groups[key], job.needed)
        job.group_index = job.group_index + 1
        processed = processed + 1
      end
    elseif job.phase == "construction" then
      local force_index = job.construction_forces[job.construction_index]
      if not force_index then
        job.retire_keys = {}
        for key in pairs(state.request_by_key) do job.retire_keys[#job.retire_keys + 1] = key end
        table.sort(job.retire_keys)
        job.retire_index = 1
        job.phase = "retire"
        return false
      else
        if not job.construction_context then
          local force = game.forces[force_index]
          if force and force.valid then
            job.construction_context = start_construction_context(force)
          else
            job.construction_index = job.construction_index + 1
          end
          processed = processed + 1
          return state.scan_job == nil
        else
          local done, used = step_construction_context(
            job.construction_context,
            budget - processed,
            job.configured,
            job.needed
          )
          processed = processed + used
          if done then
            job.construction_context = nil
            job.construction_index = job.construction_index + 1
          end
          return state.scan_job == nil
        end
      end
    elseif job.phase == "retire" then
      local key = job.retire_keys[job.retire_index]
      if not key then
        state.scan_job = nil
        job = nil
      else
        retire_request(state, key, job.configured, job.needed)
        job.retire_index = job.retire_index + 1
        processed = processed + 1
      end
    else
      state.scan_job = nil
      job = nil
    end
  end
  return state.scan_job == nil
end

function Demands.approve(request_id, player_index, automatic)
  local request = State.ensure().requests[request_id]
  if not request or (request.status ~= "queued" and request.status ~= "denied") then
    return false
  end
  request.status = "approved"
  request.approved_tick = game.tick
  local approving_player = player_index and game.get_player(player_index)
  request.approved_by = automatic and "automatic" or (approving_player and approving_player.name or "script")
  request.last_reason = nil
  State.ensure().suppressions[request.key] = nil
  State.add_history(request, "approved", automatic and "Auto-approved" or "Manually approved")
  Router.try_dispatch(request)
  return true
end

function Demands.deny(request_id, player_index)
  local state = State.ensure()
  local request = state.requests[request_id]
  if not request or request.status ~= "queued" then
    return false
  end
  request.status = "denied"
  request.denied_tick = game.tick
  local denying_player = player_index and game.get_player(player_index)
  request.denied_by = denying_player and denying_player.name or "script"
  request.last_reason = "Denied; retained for manual review"
  state.suppressions[request.key] = true
  State.add_history(request, "denied", request.last_reason)
  return true
end

function Demands.process()
  local state = State.ensure()
  local requests = Util.sorted_values(state.requests)
  table.sort(requests, function(a, b)
    if (a.priority or 0) == (b.priority or 0) then
      if (a.created_tick or 0) == (b.created_tick or 0) then return a.id < b.id end
      return (a.created_tick or 0) < (b.created_tick or 0)
    end
    return (a.priority or 0) > (b.priority or 0)
  end)
  for _, request in ipairs(requests) do
    if request.status == "queued" and game.tick >= request.auto_approve_tick then
      Demands.approve(request.id, nil, true)
    elseif request.status == "approved" then
      Router.try_dispatch(request)
    end
  end
end

local process_priorities = {1, 0, -1}

local function process_request(request)
  if request.status == "queued" and game.tick >= request.auto_approve_tick then
    Demands.approve(request.id, nil, true)
  elseif request.status == "approved" then
    Router.try_dispatch(request)
  end
end

function Demands.start_process()
  local state = State.ensure()
  if state.scan_job or state.process_job then return false end
  state.process_job = {
    priority_index = 1,
    request_id = 1,
    max_request_id = state.next_request_id - 1
  }
  return true
end

function Demands.process_active()
  return State.ensure().process_job ~= nil
end

function Demands.step_process(budget)
  local state = State.ensure()
  local job = state.process_job
  if not job then return true end
  budget = math.max(1, budget or Constants.process_work_per_tick)
  local processed = 0
  while processed < budget and job do
    local priority = process_priorities[job.priority_index]
    if not priority then
      state.process_job = nil
      job = nil
    elseif job.request_id > job.max_request_id then
      job.priority_index = job.priority_index + 1
      job.request_id = 1
    else
      local request = state.requests[job.request_id]
      if request and (request.priority or 0) == priority then process_request(request) end
      job.request_id = job.request_id + 1
      processed = processed + 1
    end
  end
  return state.process_job == nil
end

function Demands.set_priority(request_id, priority)
  local request = State.ensure().requests[request_id]
  if not request or not Constants.active_statuses[request.status] then return false end
  request.priority = math.max(-1, math.min(1, priority or 0))
  return true
end

return Demands
