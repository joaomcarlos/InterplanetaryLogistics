local State = require("scripts.state")
local Util = require("scripts.util")

local SourceStock = {}

local cache_tick
local provider_cache = {}

local function source_reserve()
  local setting = settings and settings.global and settings.global["il-source-reserve"]
  return setting and (setting.value or setting) or 0
end

local function planet_surfaces()
  local surfaces = {}
  for _, surface in pairs(game.surfaces or {}) do
    if surface.valid and surface.planet then
      surfaces[#surfaces + 1] = surface
    end
  end
  return surfaces
end

local function provider_count(surface, force, request, fresh)
  if cache_tick ~= game.tick then
    cache_tick = game.tick
    provider_cache = {}
  end
  local cache_key = table.concat({force.index, surface.index, request.item, request.quality or "normal"}, "|")
  if not fresh and provider_cache[cache_key] ~= nil then
    return provider_cache[cache_key]
  end

  local total = 0
  local networks = {}
  for _, silo in pairs(surface.find_entities_filtered({type = "rocket-silo", force = force}) or {}) do
    if silo.valid then
      local network = force.find_logistic_network_by_position(silo.position, surface)
      if network and network.valid and not networks[network.network_id] then
        networks[network.network_id] = true
        total = total + (network.get_item_count(Util.item_id(request.item, request.quality), "providers") or 0)
      end
    end
  end
  if not fresh then
    provider_cache[cache_key] = total
  end
  return total
end

local function available_on_surface(request, force, surface, fresh)
  local location = Util.surface_location(surface)
  return math.max(0, provider_count(surface, force, request, fresh)
    - State.reserved_count(location, request.item, request.quality, request.id))
end

function SourceStock.available(request, force, location, fresh)
  if not location or not force or not force.valid then
    return 0
  end
  local total = 0
  for _, surface in ipairs(planet_surfaces()) do
    if surface.index ~= request.destination_surface_index
      and Util.surface_location(surface) == location
    then
      total = total + provider_count(surface, force, request, fresh)
    end
  end
  return math.max(0, total - State.reserved_count(location, request.item, request.quality, request.id) - source_reserve())
end

function SourceStock.rank(request, force)
  local sources = {}
  local reserve = source_reserve()
  for _, surface in ipairs(planet_surfaces()) do
    if surface.index ~= request.destination_surface_index then
      local location = Util.surface_location(surface)
      local available = math.max(0, available_on_surface(request, force, surface, false) - reserve)
      if available >= request.amount then
        sources[#sources + 1] = {
          surface_index = surface.index,
          location = location,
          available = available
        }
      end
    end
  end
  return sources
end

return SourceStock
