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
      existing.observed_shortage = data.amount
      existing.unplanned_amount = math.max(0, (existing.observed_shortage or 0) - (existing.active_shipment_amount or 0))
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
  request.observed_shortage = request.observed_shortage or request.amount or 0
  request.active_shipment_amount = 0
  request.unplanned_amount = request.observed_shortage
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
    if filter.name and (not filter.type or filter.type == "item") and filter.count > 0 and Util.is_shippable(filter.name) then
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

local function sorted_dirty_chests(dirty)
  local ids = {}
  for unit_number in pairs(dirty) do ids[#ids + 1] = unit_number end
  table.sort(ids)
  return ids
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
  local network_id = network and network.network_id or 0
  local force_index = context.force_index or (context.force and context.force.index) or 0
  local key = table.concat({force_index, surface.index, network_id, name, quality}, "|")
  local entry = context.aggregate[key]
  if not entry then
    entry = {
      force_index = force_index,
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
  if item and item.name and Util.is_shippable(item.name) then
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
    if Util.is_shippable(request.name) then
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
  local force_index = entry.force_index or (context.force and context.force.index) or 0
  local request_key = table.concat({
    "alert",
    force_index,
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
    force_index = force_index,
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

local function scan_force_indices()
  local result = {}
  for _, force in ipairs(sorted_forces()) do result[#result + 1] = force.index end
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

local function process_single_chest(unit_number)
  local state = State.ensure()
  local chest = game.get_entity_by_unit_number(unit_number)
  if not chest or not chest.valid or chest.name ~= Constants.chest_name then
    State.unregister_chest(unit_number)
    Demands.retire_chest(unit_number)
    return
  end
  State.register_chest(unit_number)
  local configured = {}
  local needed = {}
  local groups = {}
  collect_chest(chest, configured, groups)
  publish_chest_groups(groups, needed)
  local prefix = "chest|" .. unit_number .. "|"
  for key in pairs(state.request_by_key) do
    if string.sub(key, 1, #prefix) == prefix and not configured[key] then
      retire_request(state, key, configured, needed)
    end
  end
  for key in pairs(configured) do
    if not needed[key] then
      retire_request(state, key, configured, needed)
    end
  end
end

function Demands.mark_chest_dirty(unit_number)
  local state = State.ensure()
  state.chest_dirty[unit_number] = true
end

function Demands.chest_dirty_active()
  return next(State.ensure().chest_dirty) ~= nil
end

function Demands.step_chest_dirty(budget)
  local state = State.ensure()
  if not next(state.chest_dirty) then return true end
  budget = math.max(1, budget or Constants.chest_dirty_work_per_tick)
  local ids = sorted_dirty_chests(state.chest_dirty)
  local processed = 0
  for index = 1, #ids do
    if processed >= budget then return false end
    local unit_number = ids[index]
    state.chest_dirty[unit_number] = nil
    process_single_chest(unit_number)
    processed = processed + 1
  end
  return next(state.chest_dirty) == nil
end

function Demands.retire_chest(unit_number)
  local state = State.ensure()
  local prefix = "chest|" .. unit_number .. "|"
  local to_remove = {}
  for key in pairs(state.request_by_key) do
    if string.sub(key, 1, #prefix) == prefix then
      to_remove[#to_remove + 1] = key
    end
  end
  table.sort(to_remove)
  for _, key in ipairs(to_remove) do
    local request_id = state.request_by_key[key]
    local request = request_id and state.requests[request_id]
    if request then
      if Constants.active_statuses[request.status] then
        Platforms.cancel(request, "Chest removed")
      end
      state.suppressions[key] = nil
      state.request_by_key[key] = nil
      request.status = "cancelled"
      request.last_reason = "Chest removed"
    end
  end
end

-- ---------------------------------------------------------------------------
-- Event-driven construction tracking
-- ---------------------------------------------------------------------------

local function is_construction_type(name)
  return name == "entity-ghost" or name == "tile-ghost" or name == "item-request-proxy"
end

local function find_network_for_position(surface, position, force)
  if not surface or not surface.valid or not surface.find_logistic_network_by_position then return nil end
  local network = surface.find_logistic_network_by_position(position, force)
  if network and network.valid ~= false then return network end
  return nil
end

local function sorted_dirty_construction(dirty)
  local keys = {}
  for key in pairs(dirty) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function sorted_tracked_keys(tracked)
  local keys = {}
  for key in pairs(tracked) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

function Demands.track_construction(entity)
  if not entity or not entity.valid then return end
  if not is_construction_type(entity.name) then return end
  local state = State.ensure()
  local surface = entity.surface
  if not surface then return end
  local key = entity_key(surface.index, entity)
  state.tracked_construction[key] = {
    surface_index = surface.index,
    unit_number = entity.unit_number,
    name = entity.name,
    position = {x = entity.position.x, y = entity.position.y},
    force_index = entity.force and entity.force.index or 0
  }
  state.construction_dirty[key] = true
end

function Demands.untrack_construction(entity)
  if not entity then return end
  local state = State.ensure()
  local surface = entity.surface
  local key
  if surface then
    key = entity_key(surface.index, entity)
  elseif entity.unit_number then
    -- Fallback: search by unit_number in tracked entries
    for tracked_key, tracked in pairs(state.tracked_construction) do
      if tracked.unit_number == entity.unit_number then
        key = tracked_key
        break
      end
    end
  end
  if not key then return end
  local tracked = state.tracked_construction[key]
  state.tracked_construction[key] = nil
  state.construction_dirty[key] = nil
  if tracked then
    -- Mark all other tracked entities on the same (force, surface) dirty
    -- so the dirty queue re-aggregates and updates demands for remaining entities
    for _, other_key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
      local other = state.tracked_construction[other_key]
      if other and other.surface_index == tracked.surface_index
        and other.force_index == tracked.force_index then
        state.construction_dirty[other_key] = true
      end
    end
    -- Retire demands for the affected surface (will be re-created by dirty queue if needed)
    local prefix = table.concat({"alert", tracked.force_index, tracked.surface_index, ""}, "|")
    local to_retire = {}
    for demand_key in pairs(state.request_by_key) do
      if string.sub(demand_key, 1, #prefix) == prefix then
        to_retire[#to_retire + 1] = demand_key
      end
    end
    table.sort(to_retire)
    for _, demand_key in ipairs(to_retire) do
      retire_request(state, demand_key, {}, {})
    end
  end
end

function Demands.untrack_construction_at_position(surface_index, position)
  if not surface_index or not position then return end
  local state = State.ensure()
  local to_untrack = {}
  for _, key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
    local tracked = state.tracked_construction[key]
    if tracked and tracked.surface_index == surface_index
      and tracked.position.x == position.x and tracked.position.y == position.y then
      to_untrack[#to_untrack + 1] = key
    end
  end
  for _, key in ipairs(to_untrack) do
    local tracked = state.tracked_construction[key]
    state.tracked_construction[key] = nil
    state.construction_dirty[key] = nil
    if tracked then
      local prefix = table.concat({"alert", tracked.force_index, tracked.surface_index, ""}, "|")
      local to_retire = {}
      for demand_key in pairs(state.request_by_key) do
        if string.sub(demand_key, 1, #prefix) == prefix then
          to_retire[#to_retire + 1] = demand_key
        end
      end
      table.sort(to_retire)
      for _, demand_key in ipairs(to_retire) do
        retire_request(state, demand_key, {}, {})
      end
      -- Mark other tracked entities on the same surface dirty
      for _, other_key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
        local other = state.tracked_construction[other_key]
        if other and other.surface_index == tracked.surface_index
          and other.force_index == tracked.force_index then
          state.construction_dirty[other_key] = true
        end
      end
    end
  end
end

function Demands.construction_dirty_active()
  return next(State.ensure().construction_dirty) ~= nil
end

local function reaggregate_construction_surface(state, force_index, surface_index, configured, needed)
  local surface = game.get_surface(surface_index)
  if not surface or not surface.valid then return end
  local force = game.forces[force_index]
  if not force or not force.valid then return end
  local context = {
    aggregate = {},
    seen = {},
    force = force,
    force_index = force_index
  }
  for _, key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
    local tracked = state.tracked_construction[key]
    if tracked and tracked.surface_index == surface_index and tracked.force_index == force_index then
      local entity = tracked.unit_number and game.get_entity_by_unit_number(tracked.unit_number) or nil
      if entity and entity.valid and entity.is_registered_for_construction
        and entity.is_registered_for_construction() then
        local network = find_network_for_position(surface, tracked.position, force)
        aggregate_construction_entity(context, network, surface, entity)
      else
        -- Entity no longer valid/registered; remove from tracking
        state.tracked_construction[key] = nil
      end
    end
  end
  -- Publish demands from the aggregate
  local aggregate_keys = {}
  for key in pairs(context.aggregate) do aggregate_keys[#aggregate_keys + 1] = key end
  table.sort(aggregate_keys)
  for _, key in ipairs(aggregate_keys) do
    publish_construction_entry(context, context.aggregate[key], configured, needed)
  end
end

function Demands.step_construction_dirty(budget)
  local state = State.ensure()
  if not next(state.construction_dirty) then return true end
  budget = math.max(1, budget or Constants.construction_dirty_work_per_tick)
  local keys = sorted_dirty_construction(state.construction_dirty)
  local processed = 0
  local affected = {}
  for index = 1, #keys do
    if processed >= budget then return false end
    local key = keys[index]
    state.construction_dirty[key] = nil
    local tracked = state.tracked_construction[key]
    if tracked then
      local pair_key = tracked.force_index .. "|" .. tracked.surface_index
      if not affected[pair_key] then
        affected[pair_key] = {force_index = tracked.force_index, surface_index = tracked.surface_index}
      end
    end
    processed = processed + 1
  end
  -- Re-aggregate each affected surface
  local configured = {}
  local needed = {}
  local affected_list = {}
  for _, pair in pairs(affected) do affected_list[#affected_list + 1] = pair end
  table.sort(affected_list, function(a, b)
    if a.force_index == b.force_index then return a.surface_index < b.surface_index end
    return a.force_index < b.force_index
  end)
  for _, pair in ipairs(affected_list) do
    reaggregate_construction_surface(state, pair.force_index, pair.surface_index, configured, needed)
  end
  -- Retire demands for affected surfaces: both unconfigured and configured-but-not-needed
  for _, pair in ipairs(affected_list) do
    local prefix = table.concat({"alert", pair.force_index, pair.surface_index, ""}, "|")
    local to_retire = {}
    for demand_key in pairs(state.request_by_key) do
      if string.sub(demand_key, 1, #prefix) == prefix then
        to_retire[#to_retire + 1] = demand_key
      end
    end
    table.sort(to_retire)
    for _, demand_key in ipairs(to_retire) do
      retire_request(state, demand_key, configured, needed)
    end
  end
  return next(state.construction_dirty) == nil
end

-- ---------------------------------------------------------------------------
-- Roboport topology reassociation
-- ---------------------------------------------------------------------------

function Demands.reassociate_construction(surface_index, force_index)
  local state = State.ensure()
  local surface = game.get_surface(surface_index)
  if not surface or not surface.valid then return end
  local force = game.forces[force_index]
  if not force or not force.valid then return end
  for _, key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
    local tracked = state.tracked_construction[key]
    if tracked and tracked.surface_index == surface_index and tracked.force_index == force_index then
      -- Re-validate the entity and mark it dirty for re-aggregation
      local entity = tracked.unit_number and game.get_entity_by_unit_number(tracked.unit_number) or nil
      if entity and entity.valid then
        tracked.position = {x = entity.position.x, y = entity.position.y}
        state.construction_dirty[key] = true
      else
        state.tracked_construction[key] = nil
        state.construction_dirty[key] = nil
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Bounded one-time bootstrap
-- ---------------------------------------------------------------------------

function Demands.start_bootstrap()
  local state = State.ensure()
  if state.bootstrap_job or state.bootstrap_completed then return false end
  state.bootstrap_job = {
    force_indices = scan_force_indices(),
    force_index = 1,
    surface_indices = nil,
    surface_index = 1,
    networks = nil,
    network_index = 1,
    cells = nil,
    cell_index = 1,
    entities = nil,
    entity_index = 1,
    phase = "force"
  }
  return true
end

function Demands.bootstrap_active()
  return State.ensure().bootstrap_job ~= nil
end

function Demands.step_bootstrap(budget)
  local state = State.ensure()
  local job = state.bootstrap_job
  if not job then return true end
  budget = math.max(1, budget or Constants.bootstrap_work_per_tick)
  local processed = 0
  while processed < budget do
    if job.phase == "force" then
      local force_index = job.force_indices[job.force_index]
      if not force_index then
        state.bootstrap_job = nil
        state.bootstrap_completed = true
        return true
      end
      local force = game.forces[force_index]
      if force and force.valid then
        job.current_force = force
        job.surface_indices = sorted_construction_surfaces(force)
        job.surface_index = 1
        job.phase = "surface"
      else
        job.force_index = job.force_index + 1
      end
      processed = processed + 1
    elseif job.phase == "surface" then
      local surface_index = job.surface_indices[job.surface_index]
      if not surface_index then
        job.force_index = job.force_index + 1
        job.phase = "force"
      else
        job.current_surface = game.get_surface(surface_index)
        job.surface_index = job.surface_index + 1
        if job.current_surface and job.current_surface.valid then
          job.networks = sorted_networks(job.current_force, job.current_surface)
          job.network_index = 1
          job.phase = "network"
        end
      end
      processed = processed + 1
    elseif job.phase == "network" then
      local network = job.networks[job.network_index]
      if not network then
        job.networks = nil
        job.current_surface = nil
        job.phase = "surface"
      else
        job.network_index = job.network_index + 1
        if network.valid ~= false then
          job.current_network = network
          job.cells = sorted_cells(network)
          job.cell_index = 1
          job.phase = "cell"
        end
      end
      processed = processed + 1
    elseif job.phase == "cell" then
      local cell = job.cells[job.cell_index]
      if not cell then
        job.cells = nil
        job.current_network = nil
        job.phase = "network"
      else
        job.cell_index = job.cell_index + 1
        if cell.valid ~= false
          and job.current_network
          and job.current_network.valid ~= false
          and job.current_surface
          and job.current_surface.valid ~= false
        then
          local owner = cell.owner
          if owner and owner.valid ~= false and owner.position then
            local radius = cell.construction_radius or 0
            local position = owner.position
            job.entities = job.current_surface.find_entities_filtered({
              area = {
                {x = position.x - radius, y = position.y - radius},
                {x = position.x + radius, y = position.y + radius}
              },
              type = construction_entity_types,
              force = job.current_force
            }) or {}
            job.entity_index = 1
            job.phase = "entity"
          end
        end
        processed = processed + 1
      end
    elseif job.phase == "entity" then
      if not job.current_network or job.current_network.valid == false then
        job.entities = nil
        job.cells = nil
        job.current_network = nil
        job.phase = "network"
        processed = processed + 1
      else
        local entity = job.entities[job.entity_index]
        if not entity then
          job.entities = nil
          job.phase = "cell"
        else
          job.entity_index = job.entity_index + 1
          if entity.valid and is_construction_type(entity.name)
            and entity.is_registered_for_construction
            and entity.is_registered_for_construction() then
            Demands.track_construction(entity)
          end
          processed = processed + 1
        end
      end
    else
      state.bootstrap_job = nil
      state.bootstrap_completed = true
      return true
    end
  end
  return state.bootstrap_job == nil
end

local function scan_tracked_construction(configured, needed)
  local state = State.ensure()
  -- Group affected (force, surface) pairs from tracked construction
  local surfaces = {}
  for _, key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
    local tracked = state.tracked_construction[key]
    if tracked then
      local pair_key = tracked.force_index .. "|" .. tracked.surface_index
      if not surfaces[pair_key] then
        surfaces[pair_key] = {force_index = tracked.force_index, surface_index = tracked.surface_index}
      end
    end
  end
  local surface_list = {}
  for _, pair in pairs(surfaces) do surface_list[#surface_list + 1] = pair end
  table.sort(surface_list, function(a, b)
    if a.force_index == b.force_index then return a.surface_index < b.surface_index end
    return a.force_index < b.force_index
  end)
  for _, pair in ipairs(surface_list) do
    reaggregate_construction_surface(state, pair.force_index, pair.surface_index, configured, needed)
  end
end

function Demands.scan()
  local state = State.ensure()
  state.scan_job = nil
  local configured = {}
  local needed = {}
  local groups = {}
  for unit_number in pairs(State.get_chests()) do
    local chest = game.get_entity_by_unit_number(unit_number)
    if chest and chest.valid and chest.name == Constants.chest_name then
      collect_chest(chest, configured, groups)
    else
      State.unregister_chest(unit_number)
    end
  end
  publish_chest_groups(groups, needed)
  scan_tracked_construction(configured, needed)
  retire_unseen(configured, needed)
end

local function sorted_scan_chests(chests)
  local ids = {}
  for unit_number in pairs(chests) do ids[#ids + 1] = unit_number end
  table.sort(ids)
  return ids
end

function Demands.start_scan()
  local state = State.ensure()
  if state.scan_job or state.process_job then return false end
  -- Collect (force, surface) pairs from tracked construction
  local construction_surfaces = {}
  for _, key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
    local tracked = state.tracked_construction[key]
    if tracked then
      local pair_key = tracked.force_index .. "|" .. tracked.surface_index
      if not construction_surfaces[pair_key] then
        construction_surfaces[pair_key] = {
          force_index = tracked.force_index,
          surface_index = tracked.surface_index
        }
      end
    end
  end
  local construction_surface_list = {}
  for _, pair in pairs(construction_surfaces) do construction_surface_list[#construction_surface_list + 1] = pair end
  table.sort(construction_surface_list, function(a, b)
    if a.force_index == b.force_index then return a.surface_index < b.surface_index end
    return a.force_index < b.force_index
  end)
  state.scan_job = {
    phase = "chests",
    chest_ids = sorted_scan_chests(State.get_chests()),
    chest_index = 1,
    configured = {},
    needed = {},
    groups = {},
    construction_surfaces = construction_surface_list,
    construction_index = 1,
    construction_aggregate = {},
    construction_aggregate_keys = nil,
    construction_aggregate_index = 1
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
          State.unregister_chest(unit_number)
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
      local pair = job.construction_surfaces[job.construction_index]
      if not pair then
        -- Publish aggregated construction demands
        job.construction_aggregate_keys = {}
        for key in pairs(job.construction_aggregate) do
          job.construction_aggregate_keys[#job.construction_aggregate_keys + 1] = key
        end
        table.sort(job.construction_aggregate_keys)
        job.construction_aggregate_index = 1
        job.phase = "construction-publish"
        return false
      else
        -- Aggregate tracked construction for this (force, surface)
        local surface = game.get_surface(pair.surface_index)
        local force = game.forces[pair.force_index]
        if surface and surface.valid and force and force.valid then
          local context = {
            aggregate = job.construction_aggregate,
            seen = {},
            force = force,
            force_index = pair.force_index
          }
          for _, key in ipairs(sorted_tracked_keys(state.tracked_construction)) do
            local tracked = state.tracked_construction[key]
            if tracked and tracked.surface_index == pair.surface_index
              and tracked.force_index == pair.force_index then
              local entity = tracked.unit_number and game.get_entity_by_unit_number(tracked.unit_number) or nil
              if entity and entity.valid and entity.is_registered_for_construction
                and entity.is_registered_for_construction() then
                local network = find_network_for_position(surface, tracked.position, force)
                aggregate_construction_entity(context, network, surface, entity)
              else
                state.tracked_construction[key] = nil
              end
            end
          end
        end
        job.construction_index = job.construction_index + 1
        processed = processed + 1
      end
    elseif job.phase == "construction-publish" then
      local key = job.construction_aggregate_keys[job.construction_aggregate_index]
      if not key then
        job.retire_keys = {}
        for key in pairs(state.request_by_key) do job.retire_keys[#job.retire_keys + 1] = key end
        table.sort(job.retire_keys)
        job.retire_index = 1
        job.phase = "retire"
        return false
      else
        local entry = job.construction_aggregate[key]
        if entry then
          publish_construction_entry({}, entry, job.configured, job.needed)
        end
        job.construction_aggregate_index = job.construction_aggregate_index + 1
        processed = processed + 1
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

-- Fully remove a Demand from state. Active demands are cancelled first so
-- active transfers, child shipments, pad sections, and temporary schedule
-- records are cleaned up; terminal demands are deleted directly.
function Demands.remove(request_id, reason)
  local state = State.ensure()
  local request = state.demands[request_id]
  if not request then return end
  if Constants.active_statuses[request.status] then
    Platforms.cancel(request, reason or "cleared by player")
  end
  local index = state.shipments_by_demand[request_id]
  if index then
    local ids = {}
    for shipment_id in pairs(index) do ids[#ids + 1] = shipment_id end
    table.sort(ids)
    for _, shipment_id in ipairs(ids) do
      Platforms.remove_shipment(shipment_id, reason or "cleared by player")
    end
  end
  Platforms.remove_pad_section(request_id)
  state.demands[request_id] = nil
  if request.key then
    state.request_by_key[request.key] = nil
    state.suppressions[request.key] = nil
  end
end

return Demands
