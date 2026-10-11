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

local function spawn_alert(request, icon, message)
  Util.alert_force(request.force_index, Util.alert_entity(request), icon, message)
end

local function clear_approval_alert(request)
  Util.alert_force(request.force_index, Util.alert_entity(request),
    Util.approval_icon, Util.approval_message(request), true)
end

local function create_request(key, data)
  local state = State.ensure()
  local existing_id = state.demand_by_key[key]
  local existing = existing_id and state.demands[existing_id]
  if existing and (Constants.active_statuses[existing.status] or existing.status == "denied") then
    existing.amount = data.amount
    existing.requested = data.requested
    existing.current = data.current
    existing.observed_shortage = data.amount
    existing.active_shipment_amount = State.active_shipment_amount(existing.id)
    existing.unplanned_amount = math.max(0, existing.observed_shortage - existing.active_shipment_amount)
    existing.last_seen_tick = game.tick
    if existing.reconcile_pending and existing.active_shipment_amount == 0
      and existing.observed_shortage > 0 and existing.status ~= "denied" then
      existing.reconcile_pending = nil
      State.set_status(existing, "approved")
      existing.completed_tick = nil
      existing.last_reason = nil
    end
    return existing
  end
  if (data.amount or 0) <= 0 then
    return nil
  end
  if state.suppressions[key] then
    return nil
  end
  local request = data
  request.id = state.next_demand_id
  state.next_demand_id = state.next_demand_id + 1
  request.key = key
  request.status = "queued"
  request.status_tick = game.tick
  request.created_tick = game.tick
  request.last_seen_tick = game.tick
  request.auto_approve_tick = auto_approve_tick()
  request.priority = request.priority or 0
  request.observed_shortage = request.observed_shortage or request.amount or 0
  request.active_shipment_amount = 0
  request.unplanned_amount = request.observed_shortage
  state.demands[request.id] = request
  state.demand_by_key[key] = request.id
  spawn_alert(request, {type = "item", name = request.item},
    {"il-gui.alert-new-delivery", request.item or "?", Util.location_rich(request.destination) or "?"})
  if settings.global["il-auto-approve-seconds"].value > 0 then
    spawn_alert(request, Util.approval_icon, Util.approval_message(request))
  end
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
          position = {x = chest.position.x, y = chest.position.y},
          alert_entity = chest
        }
      }
    end
  end
end

local function publish_chest_group(group, needed)
  table.sort(group.entries, function(a, b)
    return a.data.chest_unit_number < b.data.chest_unit_number
  end)
  for _, entry in ipairs(group.entries) do
    if entry.local_need > 0 then needed[entry.key] = true end
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

local function add_construction_item(context, network, surface, position, name, quality, count, entity)
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
      entity = entity,
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
      item.count or item.amount or 1,
      entity
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
        request.count,
        entity
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
  create_request(request_key, {
    origin = "construction-alert",
    force_index = force_index,
    destination_surface_index = surface.index,
    destination = Util.surface_location(surface),
    logistic_network_id = (entry.network_id or 0) ~= 0 and entry.network_id or nil,
    item = entry.item,
    quality = entry.quality,
    amount = shortage,
    requested = entry.amount,
    current = math.min(available, entry.amount),
    position = entry.position,
    alert_entity = entry.entity
  })
  if shortage <= 0 then return end
  needed[request_key] = true
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

local function retire_request(state, key, configured, needed)
  local request_id = state.demand_by_key[key]
  local request = request_id and state.demands[request_id]
  if request then
    if request.status == "denied" and not needed[key] then
      state.suppressions[key] = nil
      if configured[key] then
        Platforms.fulfill(request, "Destination need is fulfilled")
      else
        state.demand_by_key[key] = nil
        State.set_status(request, "cancelled")
        clear_approval_alert(request)
        request.last_reason = "Original request was removed"
      end
    elseif Constants.active_statuses[request.status] and not needed[key] then
      if configured[key] then
        Platforms.fulfill(request, "Destination need is fulfilled")
      else
        Platforms.cancel(request, "Need was removed")
      end
    end
  end
end

-- Retire every construction Demand on one (force, surface) pair. With no
-- tracked entities left the aggregate is empty, so pass empty sets to cancel;
-- callers that just re-aggregated pass their computed sets so only entries
-- that truly disappeared are retired.
local function retire_surface_construction(state, force_index, surface_index, configured, needed)
  local prefix = table.concat({"alert", force_index, surface_index, ""}, "|")
  local to_retire = {}
  for demand_key in pairs(state.demand_by_key) do
    if string.sub(demand_key, 1, #prefix) == prefix then
      to_retire[#to_retire + 1] = demand_key
    end
  end
  table.sort(to_retire)
  for _, demand_key in ipairs(to_retire) do
    retire_request(state, demand_key, configured or {}, needed or {})
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
  for key in pairs(state.demand_by_key) do
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
  for key in pairs(state.demand_by_key) do
    if string.sub(key, 1, #prefix) == prefix then
      to_remove[#to_remove + 1] = key
    end
  end
  table.sort(to_remove)
  for _, key in ipairs(to_remove) do
    local request_id = state.demand_by_key[key]
    local request = request_id and state.demands[request_id]
    if request then
      if Constants.active_statuses[request.status] then
        Platforms.cancel(request, "Chest removed")
      end
      state.suppressions[key] = nil
      state.demand_by_key[key] = nil
      State.set_status(request, "cancelled")
      clear_approval_alert(request)
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

local function sorted_tracked_keys(tracked)
  local keys = {}
  for key in pairs(tracked) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

-- Runtime-only index of tracked construction keys by "force|surface" pair.
-- Rebuilt lazily once per session (and whenever the persisted tracked table
-- is replaced) so the dirty queue, reassociation, and the bounded scan can
-- iterate one surface's keys without sorting the whole tracked table.
local tracked_by_surface = nil
local tracked_index_source = nil

local function construction_pair_key(force_index, surface_index)
  return tostring(force_index or 0) .. "|" .. tostring(surface_index or 0)
end

local function tracked_surface_index(state)
  if tracked_by_surface == nil or tracked_index_source ~= state.tracked_construction then
    tracked_index_source = state.tracked_construction
    tracked_by_surface = {}
    for key, tracked in pairs(tracked_index_source) do
      if tracked then
        local pair_key = construction_pair_key(tracked.force_index, tracked.surface_index)
        local set = tracked_by_surface[pair_key]
        if not set then
          set = {}
          tracked_by_surface[pair_key] = set
        end
        set[key] = true
      end
    end
  end
  return tracked_by_surface
end

local function track_index_add(state, key, tracked)
  local index = tracked_surface_index(state)
  local pair_key = construction_pair_key(tracked.force_index, tracked.surface_index)
  local set = index[pair_key]
  if not set then
    set = {}
    index[pair_key] = set
  end
  set[key] = true
end

local function track_index_remove(state, key, tracked)
  if not tracked_by_surface then return end
  if tracked then
    local pair_key = construction_pair_key(tracked.force_index, tracked.surface_index)
    local set = tracked_by_surface[pair_key]
    if set then
      set[key] = nil
      if not next(set) then tracked_by_surface[pair_key] = nil end
    end
    return
  end
  for pair_key, set in pairs(tracked_by_surface) do
    if set[key] then
      set[key] = nil
      if not next(set) then tracked_by_surface[pair_key] = nil end
    end
  end
end

local function surface_has_tracked(state, force_index, surface_index)
  local set = tracked_surface_index(state)[construction_pair_key(force_index, surface_index)]
  return set ~= nil and next(set) ~= nil
end

local function sorted_surface_tracked_keys(state, force_index, surface_index)
  local set = tracked_surface_index(state)[construction_pair_key(force_index, surface_index)]
  local keys = {}
  for key in pairs(set or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

-- The construction dirty queue is marked per (force, surface) pair rather
-- than per entity: re-aggregation always recounts the whole surface, so
-- entity-granularity entries only caused the same surface to be re-aggregated
-- once per budget batch while a large queue drained.
local function mark_construction_surface_dirty(state, force_index, surface_index)
  state.construction_dirty[construction_pair_key(force_index, surface_index)] = true
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
    entity = entity,
    name = entity.name,
    position = {x = entity.position.x, y = entity.position.y},
    force_index = entity.force and entity.force.index or 0
  }
  track_index_add(state, key, state.tracked_construction[key])
  mark_construction_surface_dirty(state, state.tracked_construction[key].force_index, surface.index)
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
  track_index_remove(state, key, tracked)
  if tracked then
    -- Re-aggregate the (force, surface) so demand quantities update in place.
    -- Existing Demands keep their approval and Shipments; only the observed
    -- amounts change. With nothing left tracked on the surface the aggregate
    -- is empty, so retire the surface's construction demands now instead of
    -- waiting for the dirty step.
    if surface_has_tracked(state, tracked.force_index, tracked.surface_index) then
      mark_construction_surface_dirty(state, tracked.force_index, tracked.surface_index)
    else
      retire_surface_construction(state, tracked.force_index, tracked.surface_index)
    end
  end
end

function Demands.untrack_construction_at_position(surface_index, position)
  if not surface_index or not position then return end
  local state = State.ensure()
  -- Collect tracked keys on this surface across every force pair.
  local index = tracked_surface_index(state)
  local surface_keys = {}
  for pair_key, set in pairs(index) do
    local sep = string.find(pair_key, "|", 1, true)
    if tonumber(string.sub(pair_key, sep + 1)) == surface_index then
      for key in pairs(set) do surface_keys[#surface_keys + 1] = key end
    end
  end
  table.sort(surface_keys)
  local to_untrack = {}
  for _, key in ipairs(surface_keys) do
    local tracked = state.tracked_construction[key]
    if tracked and tracked.position.x == position.x and tracked.position.y == position.y then
      to_untrack[#to_untrack + 1] = key
    end
  end
  local removed_pairs = {}
  for _, key in ipairs(to_untrack) do
    local tracked = state.tracked_construction[key]
    state.tracked_construction[key] = nil
    track_index_remove(state, key, tracked)
    if tracked then
      removed_pairs[construction_pair_key(tracked.force_index, tracked.surface_index)] = tracked
    end
  end
  -- Same live-update rule as untrack_construction: re-aggregate surfaces with
  -- survivors so quantities adjust, retire only where nothing is tracked.
  local sorted_pairs = {}
  for pair_key in pairs(removed_pairs) do sorted_pairs[#sorted_pairs + 1] = pair_key end
  table.sort(sorted_pairs)
  for _, pair_key in ipairs(sorted_pairs) do
    local tracked = removed_pairs[pair_key]
    if surface_has_tracked(state, tracked.force_index, tracked.surface_index) then
      mark_construction_surface_dirty(state, tracked.force_index, tracked.surface_index)
    else
      retire_surface_construction(state, tracked.force_index, tracked.surface_index)
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
  for _, key in ipairs(sorted_surface_tracked_keys(state, force_index, surface_index)) do
    local tracked = state.tracked_construction[key]
    if tracked and tracked.surface_index == surface_index and tracked.force_index == force_index then
      local entity = tracked.entity
      if entity and entity.valid and entity.is_registered_for_construction
        and entity.is_registered_for_construction() then
        tracked.position = {x = entity.position.x, y = entity.position.y}
        local network = find_network_for_position(surface, tracked.position, force)
        aggregate_construction_entity(context, network, surface, entity)
      else
        -- Entity no longer valid/registered; remove from tracking
        state.tracked_construction[key] = nil
        track_index_remove(state, key, tracked)
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
  local pairs_list = {}
  for pair_key in pairs(state.construction_dirty) do
    local sep = string.find(pair_key, "|", 1, true)
    if sep then
      pairs_list[#pairs_list + 1] = {
        key = pair_key,
        force_index = tonumber(string.sub(pair_key, 1, sep - 1)),
        surface_index = tonumber(string.sub(pair_key, sep + 1))
      }
    else
      state.construction_dirty[pair_key] = nil
    end
  end
  table.sort(pairs_list, function(a, b)
    if a.force_index == b.force_index then return a.surface_index < b.surface_index end
    return a.force_index < b.force_index
  end)
  local processed = 0
  local configured = {}
  local needed = {}
  for _, pair in ipairs(pairs_list) do
    if processed >= budget then break end
    state.construction_dirty[pair.key] = nil
    reaggregate_construction_surface(state, pair.force_index, pair.surface_index, configured, needed)
    -- Retire demands for the surface: both unconfigured and configured-but-not-needed
    retire_surface_construction(state, pair.force_index, pair.surface_index, configured, needed)
    processed = processed + 1
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
  -- Mark the whole (force, surface) for re-aggregation when it still has
  -- tracked entities; the re-aggregation pass itself refreshes tracked
  -- positions and drops invalid ones. Surfaces with no tracked entities are
  -- untouched, matching the previous entity-at-a-time behavior.
  if surface_has_tracked(state, force_index, surface_index) then
    mark_construction_surface_dirty(state, force_index, surface_index)
  end
end

function Demands.mark_demand_dirty(demand)
  if not demand then return end
  if demand.origin == "chest" and demand.chest_unit_number then
    Demands.mark_chest_dirty(demand.chest_unit_number)
  elseif demand.destination_surface_index and demand.force_index then
    Demands.reassociate_construction(demand.destination_surface_index, demand.force_index)
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

function Demands.ensure_bootstrap()
  local state = State.ensure()
  if state.bootstrap_completed or state.bootstrap_job then return false end
  return Demands.start_bootstrap()
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

-- Synchronous driver over the bounded scan job. Used by tests and callers
-- that need a full reconciliation in one call; the tick loop uses the
-- start/step pair directly.
function Demands.scan()
  if Demands.start_scan() then
    while not Demands.step_scan(math.huge) do end
  end
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
          for _, key in ipairs(sorted_surface_tracked_keys(state, pair.force_index, pair.surface_index)) do
            local tracked = state.tracked_construction[key]
            if tracked and tracked.surface_index == pair.surface_index
              and tracked.force_index == pair.force_index then
              local entity = tracked.entity
              if entity and entity.valid and entity.is_registered_for_construction
                and entity.is_registered_for_construction() then
                local network = find_network_for_position(surface, tracked.position, force)
                aggregate_construction_entity(context, network, surface, entity)
              else
                state.tracked_construction[key] = nil
                track_index_remove(state, key, tracked)
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
        for key in pairs(state.demand_by_key) do job.retire_keys[#job.retire_keys + 1] = key end
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
  local request = State.ensure().demands[request_id]
  if not request or (request.status ~= "queued" and request.status ~= "denied") then
    return false
  end
  State.set_status(request, "approved")
  clear_approval_alert(request)
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
  local request = state.demands[request_id]
  if not request or request.status ~= "queued" then
    return false
  end
  State.set_status(request, "denied")
  clear_approval_alert(request)
  request.denied_tick = game.tick
  local denying_player = player_index and game.get_player(player_index)
  request.denied_by = denying_player and denying_player.name or "script"
  request.last_reason = "Denied; retained for manual review"
  state.suppressions[request.key] = true
  State.add_history(request, "denied", request.last_reason)
  return true
end

-- Synchronous driver over the bounded process job (see Demands.scan).
function Demands.process()
  if Demands.start_process() then
    while not Demands.step_process(math.huge) do end
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
  local ids_by_priority = {[1] = {}, [0] = {}, [-1] = {}}
  for request_id, request in pairs(state.demands or {}) do
    local priority = request.priority or 0
    if ids_by_priority[priority] then ids_by_priority[priority][#ids_by_priority[priority] + 1] = request_id end
  end
  for _, ids in pairs(ids_by_priority) do table.sort(ids) end
  state.process_job = {
    priority_index = 1,
    request_index = 1,
    ids_by_priority = ids_by_priority
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
    elseif job.request_index > #(job.ids_by_priority[priority] or {}) then
      job.priority_index = job.priority_index + 1
      job.request_index = 1
    else
      local request_id = job.ids_by_priority[priority][job.request_index]
      local request = state.demands[request_id]
      if request then process_request(request) end
      job.request_index = job.request_index + 1
      processed = processed + 1
    end
  end
  return state.process_job == nil
end

function Demands.set_priority(request_id, priority)
  local request = State.ensure().demands[request_id]
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
  clear_approval_alert(request)
  if Constants.active_statuses[request.status] then
    Platforms.cancel(request, reason or "cleared by player")
  end
  State.for_each_sorted_shipment(request_id, function(shipment_id)
    Platforms.remove_shipment(shipment_id, reason or "cleared by player")
  end)
  Platforms.remove_pad_section(request_id)
  state.demands[request_id] = nil
  if request.key then
    state.demand_by_key[request.key] = nil
    state.suppressions[request.key] = nil
  end
end

return Demands
