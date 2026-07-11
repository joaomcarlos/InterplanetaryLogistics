local Util = {}

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

function Util.surface_location(surface)
  if surface and surface.valid and surface.planet then
    return surface.planet.name
  end
  return surface and surface.name or "unknown"
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

function Util.route_pairs(platform)
  local locations = Util.route_locations(platform)
  local pairs_list = {}
  if #locations < 2 then
    return pairs_list
  end
  for index, source in ipairs(locations) do
    for _, destination in ipairs(locations) do
      if source ~= destination then
        pairs_list[#pairs_list + 1] = {source = source, destination = destination}
      end
    end
  end
  table.sort(pairs_list, function(a, b)
    if a.source == b.source then return a.destination < b.destination end
    return a.source < b.source
  end)
  return pairs_list
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

return Util
