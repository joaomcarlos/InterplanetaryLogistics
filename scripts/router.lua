local State = require("scripts.state")
local Util = require("scripts.util")
local Platforms = require("scripts.platforms")

local Router = {}

-- A scan can approve several requests in the same tick. Provider inventories
-- do not change between those lookups except for our own reservations, so keep
-- the expensive surface/silo/network query for the duration of that tick.
local provider_cache_tick
local provider_cache = {}
local planet_surface_cache_tick
local planet_surface_cache

local function planet_surfaces()
  if planet_surface_cache_tick == game.tick then
    return planet_surface_cache
  end
  local surfaces = {}
  for _, surface in pairs(game.surfaces) do
    if surface.valid and surface.planet then
      surfaces[#surfaces + 1] = surface
    end
  end
  planet_surface_cache_tick = game.tick
  planet_surface_cache = surfaces
  return surfaces
end

local function provider_count(surface, force, request)
  local cache_key = table.concat({force.index, surface.index, request.item, request.quality or "normal"}, "|")
  if provider_cache_tick ~= game.tick then
    provider_cache_tick = game.tick
    provider_cache = {}
  end
  local cached = provider_cache[cache_key]
  if cached == nil then
    local total = 0
    local networks = {}
    for _, silo in pairs(surface.find_entities_filtered({type = "rocket-silo", force = force})) do
      local network = force.find_logistic_network_by_position(silo.position, surface)
      if network and network.valid and not networks[network.network_id] then
        networks[network.network_id] = true
        total = total + network.get_item_count(Util.item_id(request.item, request.quality), "providers")
      end
    end
    cached = total
    provider_cache[cache_key] = total
  end
  local location = Util.surface_location(surface)
  return math.max(0, cached - State.reserved_count(location, request.item, request.quality, request.id))
end

local function reliability_score(location, available, needed)
  local metrics = State.ensure().source_metrics[location] or {successes = 0, failures = 0}
  local attempts = metrics.successes + metrics.failures
  local success_ratio = (metrics.successes + 4) / (attempts + 5)
  local coverage = math.min(available / math.max(needed, 1), 2)
  return success_ratio * 100 + coverage * 5 + math.min(attempts, 10) * 0.1
end

function Router.rank_sources(request, force)
  local reserve = settings.global["il-source-reserve"].value
  local sources = {}
  for _, surface in pairs(planet_surfaces()) do
    if surface.index ~= request.destination_surface_index then
      local available = math.max(0, provider_count(surface, force, request) - reserve)
      if available >= request.amount then
        local location = Util.surface_location(surface)
        sources[#sources + 1] = {
          surface_index = surface.index,
          location = location,
          available = available,
          score = reliability_score(location, available, request.amount)
        }
      end
    end
  end
  table.sort(sources, function(a, b)
    if a.score == b.score then
      if a.available == b.available then
        return a.location < b.location
      end
      return a.available > b.available
    end
    return a.score > b.score
  end)
  return sources
end

function Router.try_dispatch(request)
  if request.status ~= "approved" then
    return false
  end
  local force = game.forces[request.force_index]
  if not force then
    request.last_reason = "Force no longer exists"
    return false
  end
  local sources = Router.rank_sources(request, force)
  if #sources == 0 then
    request.last_reason = "No planet has enough provider stock"
    return false
  end
  for _, source in ipairs(sources) do
    local platform = Platforms.find_matching(request, force, source.location, request.destination)
    if platform then
      request.source = source.location
      request.source_surface_index = source.surface_index
      request.source_available = source.available
      request.source_score = source.score
      State.reserve(request)
      local ok, reason = Platforms.dispatch(request, platform, force)
      if ok then
        return true
      end
      State.release_reservation(request.id)
      request.last_reason = reason
    end
  end
  request.last_reason = request.last_reason or "No enrolled platform has this route and enough cargo space"
  return false
end

return Router
