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

return Util
