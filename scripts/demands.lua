local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")
local Router = require("scripts.router")
local Platforms = require("scripts.platforms")

local Demands = {}

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
      local quality = filter.quality or "normal"
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
          group = {
            supply = network and network.valid and network.get_item_count(item, "providers") or 0,
            entries = {}
          }
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

local function publish_chest_groups(groups, needed)
  for _, group in pairs(groups) do
    table.sort(group.entries, function(a, b)
      return a.data.chest_unit_number < b.data.chest_unit_number
    end)
    local available = group.supply
    for _, entry in pairs(group.entries) do
      local covered = math.min(available, entry.local_need)
      available = available - covered
      local missing = entry.local_need - covered
      if missing > 0 then
        needed[entry.key] = true
        entry.data.amount = missing
        create_request(entry.key, entry.data)
      end
    end
  end
end

local function item_to_place(prototype)
  if not prototype or not prototype.valid then
    return nil
  end
  local items = prototype.items_to_place_this
  local first = items and items[1]
  if not first then
    return nil, 0
  end
  return first.name, first.count or 1
end

local function scan_alerts(configured, needed)
  for _, force in pairs(game.forces) do
    local player
    for _, candidate in pairs(force.players) do
      player = candidate
      break
    end
    if player and player.valid then
      local alerts_by_surface = player.get_alerts({type = defines.alert_type.no_material_for_construction})
      local aggregate = {}
      for surface_index, alerts_by_type in pairs(alerts_by_surface) do
        local alerts = alerts_by_type[defines.alert_type.no_material_for_construction] or {}
        for _, alert in pairs(alerts) do
          local prototype = alert.prototype
          if (not prototype or not prototype.valid) and alert.target and alert.target.valid then
            prototype = alert.target.ghost_prototype
          end
          local item, count = item_to_place(prototype)
          if item then
            local key = table.concat({surface_index, item, "normal"}, "|")
            local entry = aggregate[key] or {
              surface_index = surface_index,
              item = item,
              quality = "normal",
              amount = 0,
              position = alert.position
            }
            entry.amount = entry.amount + count
            aggregate[key] = entry
          end
        end
      end
      for _, entry in pairs(aggregate) do
        local surface = game.get_surface(entry.surface_index)
        if surface then
          local key = table.concat({"alert", force.index, entry.surface_index, entry.item, entry.quality}, "|")
          configured[key] = true
          needed[key] = true
          create_request(key, {
            origin = "construction-alert",
            force_index = force.index,
            destination_surface_index = surface.index,
            destination = Util.surface_location(surface),
            item = entry.item,
            quality = entry.quality,
            amount = entry.amount,
            requested = entry.amount,
            current = 0,
            position = entry.position
          })
        end
      end
    end
  end
end

local function retire_unseen(configured, needed)
  local state = State.ensure()
  for key, request_id in pairs(state.request_by_key) do
    local request = state.requests[request_id]
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
end

function Demands.scan()
  local state = State.ensure()
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
  scan_alerts(configured, needed)
  retire_unseen(configured, needed)
end

function Demands.approve(request_id, player_index, automatic)
  local request = State.ensure().requests[request_id]
  if not request or (request.status ~= "queued" and request.status ~= "denied") then
    return false
  end
  request.status = "approved"
  request.approved_tick = game.tick
  request.approved_by = automatic and "automatic" or (player_index and game.get_player(player_index).name or "script")
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
  request.denied_by = player_index and game.get_player(player_index).name or "script"
  request.last_reason = "Denied; retained for manual review"
  state.suppressions[request.key] = true
  State.add_history(request, "denied", request.last_reason)
  return true
end

function Demands.process()
  local state = State.ensure()
  for _, request in pairs(state.requests) do
    if request.status == "queued" and game.tick >= request.auto_approve_tick then
      Demands.approve(request.id, nil, true)
    elseif request.status == "approved" then
      Router.try_dispatch(request)
    end
  end
  Platforms.monitor()
end

return Demands
