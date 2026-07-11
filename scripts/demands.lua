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

local function publish_chest_group(group, needed)
  table.sort(group.entries, function(a, b)
    return a.data.chest_unit_number < b.data.chest_unit_number
  end)
  local available = group.supply
  for _, entry in ipairs(group.entries) do
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

local function publish_chest_groups(groups, needed)
  for _, group in pairs(groups) do
    publish_chest_group(group, needed)
  end
end

local function item_to_place(prototype)
  if not prototype or not prototype.valid then
    return nil
  end
  local items = prototype.items_to_place_this
  if not items then
    return nil
  end
  local first = items[1] or items
  if not first or not first.name then
    return nil
  end
  return first.name, first.count or first.amount or 1
end

local function normalize_construction_alert(alert, surface_index)
  if not alert then
    return nil
  end

  local target = alert.target
  local prototype = alert.prototype
  local position = alert.position
  local surface_idx = surface_index
  local items = {}

  if target and target.valid then
    local target_name = target.name
    if target.surface and target.surface.valid then
      surface_idx = target.surface.index
    end
    if target.position then
      position = target.position
    end
    if target_name == "entity-ghost" or target_name == "item-request-proxy" then
      if target.item_requests then
        for _, req in pairs(target.item_requests) do
          if req.name and req.count and req.count > 0 then
            items[#items + 1] = {
              name = req.name,
              quality = req.quality or "normal",
              count = req.count
            }
          end
        end
      end
    end
    if target_name == "entity-ghost" then
      if target.ghost_prototype and target.ghost_prototype.valid then
        prototype = target.ghost_prototype
      end
    elseif target_name == "item-request-proxy" then
      local proxy_target = target.proxy_target
      if proxy_target and proxy_target.valid and proxy_target.name == "entity-ghost" then
        if proxy_target.ghost_prototype and proxy_target.ghost_prototype.valid then
          prototype = proxy_target.ghost_prototype
        end
      end
    elseif target.prototype and target.prototype.valid then
      prototype = target.prototype
    end
  end

  if not position then
    return nil
  end

  local place_item, place_count = item_to_place(prototype)
  if place_item then
    items[#items + 1] = {name = place_item, quality = "normal", count = place_count}
  end

  if #items == 0 then
    return nil
  end

  return surface_idx, position, items
end

local function scan_alert_player(force, player, configured, needed)
  local alerts_by_surface = player.get_alerts({type = defines.alert_type.no_material_for_construction})
  local seen = {}
  local aggregate = {}
  for surface_index, alerts_by_type in pairs(alerts_by_surface) do
    local alerts = alerts_by_type[defines.alert_type.no_material_for_construction] or {}
    for _, alert in pairs(alerts) do
      local surface_idx, position, items = normalize_construction_alert(alert, surface_index)
      if surface_idx and position and items then
        for _, req in pairs(items) do
          local dedup_key = table.concat({surface_idx, req.name, req.quality, position.x, position.y}, "|")
          if not seen[dedup_key] then
            seen[dedup_key] = true
            local agg_key = table.concat({surface_idx, req.name, req.quality}, "|")
            local entry = aggregate[agg_key] or {
              surface_index = surface_idx,
              item = req.name,
              quality = req.quality,
              amount = 0,
              position = position,
              alert_origin = req.name
            }
            entry.amount = entry.amount + req.count
            aggregate[agg_key] = entry
          end
        end
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

local function scan_alerts(configured, needed)
  for _, force in pairs(game.forces) do
    local players = {}
    for _, candidate in pairs(force.players) do
      if candidate.valid then players[#players + 1] = candidate end
    end
    table.sort(players, function(a, b) return a.index < b.index end)
    for _, player in ipairs(players) do
      scan_alert_player(force, player, configured, needed)
    end
  end
end

local function start_alert_context(force, player)
  local alerts_by_surface = player.get_alerts({type = defines.alert_type.no_material_for_construction})
  local surface_indices = {}
  for surface_index in pairs(alerts_by_surface) do surface_indices[#surface_indices + 1] = surface_index end
  table.sort(surface_indices)
  return {
    force = force,
    alerts_by_surface = alerts_by_surface,
    surface_indices = surface_indices,
    surface_index = 1,
    alerts = nil,
    alert_index = 1,
    seen = {},
    aggregate = {},
    aggregate_keys = nil,
    aggregate_index = 1,
    phase = "alerts"
  }
end

local function step_alert_context(context, budget, configured, needed)
  local processed = 0
  while processed < budget do
    if context.phase == "publish" then
      local key = context.aggregate_keys[context.aggregate_index]
      if not key then return true, processed end
      local entry = context.aggregate[key]
      local surface = game.get_surface(entry.surface_index)
      if surface then
        local request_key = table.concat({"alert", context.force.index, entry.surface_index, entry.item, entry.quality}, "|")
        configured[request_key] = true
        needed[request_key] = true
        create_request(request_key, {
          origin = "construction-alert",
          force_index = context.force.index,
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
      context.aggregate_index = context.aggregate_index + 1
      processed = processed + 1
    else
    if not context.alerts then
      local surface_index = context.surface_indices[context.surface_index]
      if not surface_index then
        context.aggregate_keys = {}
        for key in pairs(context.aggregate) do context.aggregate_keys[#context.aggregate_keys + 1] = key end
        table.sort(context.aggregate_keys)
        context.aggregate_index = 1
        context.phase = "publish"
        return false, processed
      else
        local alerts_by_type = context.alerts_by_surface[surface_index]
        context.alerts = alerts_by_type[defines.alert_type.no_material_for_construction] or {}
        context.alert_index = 1
        context.surface_index = context.surface_index + 1
      end
    end

    local alerts = context.alerts
    if context.phase == "alerts" and alerts then
      local alert = alerts[context.alert_index]
      if not alert then
        context.alerts = nil
      else
        local surface_index = context.surface_indices[context.surface_index - 1]
        local surface_idx, position, items = normalize_construction_alert(alert, surface_index)
        if surface_idx and position and items then
          for _, req in pairs(items) do
            local dedup_key = table.concat({surface_idx, req.name, req.quality, position.x, position.y}, "|")
            if not context.seen[dedup_key] then
              context.seen[dedup_key] = true
              local agg_key = table.concat({surface_idx, req.name, req.quality}, "|")
              local entry = context.aggregate[agg_key] or {
                surface_index = surface_idx,
                item = req.name,
                quality = req.quality,
                amount = 0,
                position = position,
                alert_origin = req.name
              }
              entry.amount = entry.amount + req.count
              context.aggregate[agg_key] = entry
            end
          end
        end
        context.alert_index = context.alert_index + 1
        processed = processed + 1
      end
    end
    end
  end
  return false, processed
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
  scan_alerts(configured, needed)
  retire_unseen(configured, needed)
end

local function sorted_scan_chests(chests)
  local ids = {}
  for unit_number in pairs(chests) do ids[#ids + 1] = unit_number end
  table.sort(ids)
  return ids
end

local function scan_players()
  local force_indices = {}
  for force_index in pairs(game.forces) do force_indices[#force_indices + 1] = force_index end
  table.sort(force_indices)
  local players = {}
  for _, force_index in ipairs(force_indices) do
    local force = game.forces[force_index]
    local force_players = {}
    for _, player in pairs(force.players or {}) do
      if player.valid then force_players[#force_players + 1] = player end
    end
    table.sort(force_players, function(a, b) return a.index < b.index end)
    for _, player in ipairs(force_players) do
      players[#players + 1] = {force_index = force_index, player_index = player.index}
    end
  end
  return players
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
    alert_players = scan_players(),
    alert_index = 1,
    alert_context = nil
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
        job.phase = "alerts"
        return false
      else
        publish_chest_group(job.groups[key], job.needed)
        job.group_index = job.group_index + 1
        processed = processed + 1
      end
    elseif job.phase == "alerts" then
      local work = job.alert_players[job.alert_index]
      if not work then
        job.retire_keys = {}
        for key in pairs(state.request_by_key) do job.retire_keys[#job.retire_keys + 1] = key end
        table.sort(job.retire_keys)
        job.retire_index = 1
        job.phase = "retire"
        return false
      else
        if not job.alert_context then
          local force = game.forces[work.force_index]
          local player = game.get_player(work.player_index)
          if force and player and player.valid then
            job.alert_context = start_alert_context(force, player)
          else
            job.alert_index = job.alert_index + 1
          end
          processed = processed + 1
          return state.scan_job == nil
        else
          local done, used = step_alert_context(job.alert_context, budget - processed, job.configured, job.needed)
          processed = processed + used
          if done then
            job.alert_context = nil
            job.alert_index = job.alert_index + 1
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
