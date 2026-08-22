local Util = require("scripts.util")

local SourceStock = {}

local cache_tick
local network_cache = {}

local function planet_surfaces()
  local surfaces = {}
  for _, surface in pairs(game.surfaces or {}) do
    if surface.valid and surface.planet then
      surfaces[#surfaces + 1] = surface
    end
  end
  return surfaces
end

local function network_id_less(a, b)
  if a == nil then
    return false
  end
  if b == nil then
    return true
  end
  return a < b
end

local function largest_network_result(surface, force, demand, fresh)
  if cache_tick ~= game.tick then
    cache_tick = game.tick
    network_cache = {}
  end

  local cache_key = table.concat({
    tostring(force.index),
    tostring(surface.index),
    demand.item,
    demand.quality or "normal"
  }, "|")
  if not fresh and network_cache[cache_key] then
    return network_cache[cache_key]
  end

  local largest = {network_id = nil, available = 0}
  local logistic_networks = force.logistic_networks
  local networks = logistic_networks and (logistic_networks[surface.name] or logistic_networks[surface.index])
  for _, network in pairs(networks or {}) do
    if network.valid then
      local available = network.get_item_count(Util.item_id(demand.item, demand.quality)) or 0
      if available > largest.available
        or (available == largest.available and network_id_less(network.network_id, largest.network_id))
      then
        largest = {network_id = network.network_id, available = available}
      end
    end
  end

  if not fresh then
    network_cache[cache_key] = largest
  end
  return largest
end

local function planning_amount(demand)
  if demand.unplanned_amount ~= nil then
    return demand.unplanned_amount
  end
  return demand.amount or 0
end

local function source_less(a, b, needed)
  local a_full = a.available >= needed
  local b_full = b.available >= needed
  if a_full ~= b_full then
    return a_full
  end
  if a.available ~= b.available then
    return a.available > b.available
  end
  if a.location ~= b.location then
    return a.location < b.location
  end
  if a.surface_index ~= b.surface_index then
    return a.surface_index < b.surface_index
  end
  return network_id_less(a.network_id, b.network_id)
end

function SourceStock.snapshot(demand, force)
  local sources = {}
  if not force or not force.valid then
    return sources
  end

  for _, surface in ipairs(planet_surfaces()) do
    if surface.index ~= demand.destination_surface_index then
      local largest = largest_network_result(surface, force, demand, false)
      if largest.available > 0 then
        sources[#sources + 1] = {
          surface_index = surface.index,
          location = Util.surface_location(surface),
          network_id = largest.network_id,
          available = largest.available
        }
      end
    end
  end

  local needed = planning_amount(demand)
  table.sort(sources, function(a, b)
    return source_less(a, b, needed)
  end)
  return sources
end

function SourceStock.available(demand, force, location, fresh)
  if not location or not force or not force.valid then
    return 0
  end

  local available = 0
  for _, surface in ipairs(planet_surfaces()) do
    if surface.index ~= demand.destination_surface_index
      and Util.surface_location(surface) == location
    then
      available = math.max(available, largest_network_result(surface, force, demand, fresh).available)
    end
  end
  return available
end

function SourceStock.rank(demand, force)
  local ranked = {}
  local needed = demand.amount or 0
  for _, source in ipairs(SourceStock.snapshot(demand, force)) do
    if source.available >= needed then
      ranked[#ranked + 1] = source
    end
  end
  return ranked
end

return SourceStock
