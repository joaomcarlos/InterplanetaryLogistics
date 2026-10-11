local Util = {}

local Constants = require("scripts.constants")

function Util.deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local result = {}
  seen[value] = result
  for key, child in pairs(value) do
    result[Util.deep_copy(key, seen)] = Util.deep_copy(child, seen)
  end
  return result
end

function Util.item_id(name, quality)
  return {name = name, quality = quality or "normal"}
end

function Util.item_signal(name, quality)
  return {type = "item", name = name, quality = quality or "normal"}
end

function Util.is_shippable(item_name)
  if not prototypes or not prototypes.item then return true end
  local proto = prototypes.item[item_name]
  if not proto then return false end
  if Constants.non_shippable_items[item_name] then return false end
  return true
end

function Util.surface_location(surface)
  if surface and surface.valid and surface.planet then
    return surface.planet.name
  end
  if surface and surface.valid and surface.platform then
    local platform = surface.platform
    if platform.valid then return platform.name end
  end
  return surface and surface.name or "unknown"
end

-- Display translation for persisted location names: space-platform surfaces
-- are named "platform-N"; show the owning platform's actual name instead.
function Util.location_display(location)
  if type(location) ~= "string" or not string.match(location, "^platform%-") then
    return location
  end
  local surface = game.get_surface and game.get_surface(location)
  if surface and surface.valid and surface.platform then
    local platform = surface.platform
    if platform.valid then return platform.name end
  end
  return location
end

-- Rich-text display: planet locations render as space-location icons,
-- platform names and other locations fall back to translated text.
function Util.location_rich(location)
  if type(location) ~= "string" then return location end
  if prototypes and prototypes.space_location and prototypes.space_location[location] then
    return "[space-location=" .. location .. "]"
  end
  return Util.location_display(location)
end

function Util.group_destinations_by_planet(entities)
  local by_planet = {}
  for _, entity in ipairs(entities) do
    local planet = Util.surface_location(entity.surface)
    by_planet[planet] = by_planet[planet] or {}
    by_planet[planet][#by_planet[planet] + 1] = entity
  end
  local list = {}
  for planet, pads in pairs(by_planet) do
    table.sort(pads, function(a, b) return a.unit_number < b.unit_number end)
    list[#list + 1] = {planet = planet, pads = pads}
  end
  table.sort(list, function(a, b) return a.planet < b.planet end)
  return list
end

function Util.get_platform(force, platform_index)
  if not force or not force.valid then
    return nil
  end
  for _, platform in pairs(force.platforms) do
    if platform.valid and platform.index == platform_index then
      return platform
    end
  end
  return nil
end

function Util.format_ticks(ticks)
  local seconds = math.max(0, math.floor((ticks or 0) / 60))
  if seconds < 60 then
    return seconds .. "s"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return minutes .. "m " .. (seconds % 60) .. "s"
  end
  return math.floor(minutes / 60) .. "h " .. (minutes % 60) .. "m"
end

function Util.route_locations(platform)
  local locations = {}
  local seen = {}
  local schedule = platform and platform.schedule
  for _, record in pairs(schedule and schedule.records or {}) do
    if not record.temporary and record.station and not seen[record.station] then
      seen[record.station] = true
      locations[#locations + 1] = record.station
    end
  end
  return locations
end

function Util.schedule_ordered_sources(platform, sources, destination)
  local locations = Util.route_locations(platform)
  local current = platform.space_location and platform.space_location.name
  local source_set = {}
  for _, source in ipairs(sources) do
    source_set[source.location] = source
  end
  local current_index = nil
  for index, location in ipairs(locations) do
    if location == current then
      current_index = index
      break
    end
  end
  local ordered = {}
  local seen = {}
  if current_index then
    for offset = 0, #locations - 1 do
      local index = ((current_index + offset - 1) % #locations) + 1
      local location = locations[index]
      if location ~= destination and source_set[location] and not seen[location] then
        seen[location] = true
        ordered[#ordered + 1] = source_set[location]
      end
    end
  else
    for _, location in ipairs(locations) do
      if location ~= destination and source_set[location] and not seen[location] then
        seen[location] = true
        ordered[#ordered + 1] = source_set[location]
      end
    end
  end
  return ordered
end

function Util.sorted_values(dictionary, predicate)
  local values = {}
  for _, value in pairs(dictionary or {}) do
    if not predicate or predicate(value) then
      values[#values + 1] = value
    end
  end
  table.sort(values, function(a, b)
    return (a.id or 0) < (b.id or 0)
  end)
  return values
end

function Util.gps(entity)
  if not entity or not entity.valid then
    return ""
  end
  return string.format("[gps=%.1f,%.1f,%s]", entity.position.x, entity.position.y, entity.surface.name)
end

function Util.is_ghost_item_name(name)
  return type(name) == "string"
    and (name == "entity-ghost" or name == "tile-ghost" or string.match(name, "%-ghost$") ~= nil)
end

function Util.request_sprite(request)
  if not request or Util.is_ghost_item_name(request.item) or not request.item then
    return "utility/warning_white"
  end
  return "item/" .. request.item
end

-- Resolve a cargo pod destination/origin to its station LuaEntity.
-- Factorio normally exposes CargoDestination as a table containing `station`,
-- but some 2.1 event payloads expose the station LuaEntity directly. Do not
-- index a LuaEntity with the table-only field.
Util.approval_icon = {type = "virtual", name = "signal-deny"}

function Util.approval_message(request)
  return {"il-gui.alert-needs-approval", request.item or "?", Util.location_rich(request.destination) or "?"}
end

-- Resolve the entity a demand alert should zoom to. Uses the persisted
-- LuaEntity ref (never surface searches), falling back to unit lookup.
function Util.alert_entity(request)
  if not request then return nil end
  local entity = request.alert_entity
  if not (entity and entity.valid) then
    entity = request.chest_unit_number and game.get_entity_by_unit_number
      and game.get_entity_by_unit_number(request.chest_unit_number)
  end
  return (entity and entity.valid) and entity or nil
end

function Util.alert_force(force_index, entity, icon, message, remove)
  if not (entity and entity.valid) then return end
  local force = game.forces and game.forces[force_index]
  if not force then return end
  for _, player in pairs(force.players or {}) do
    if player.valid then
      if remove and player.remove_alert then
        player.remove_alert{entity = entity, icon = icon, message = message}
      elseif not remove and player.add_custom_alert then
        player.add_custom_alert(entity, icon, message, true)
      end
    end
  end
end

function Util.resolve_cargo_endpoint(destination)
  if not destination then return nil end
  if type(destination) == "table" then
    if destination.valid ~= nil or destination.unit_number ~= nil then return destination end
    return destination.station
  end
  return destination
end

return Util
