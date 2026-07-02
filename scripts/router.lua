local State = require("scripts.state")
local Util = require("scripts.util")
local Platforms = require("scripts.platforms")

local Router = {}

local function planet_surfaces()
  local surfaces = {}
  for _, surface in pairs(game.surfaces) do
    if surface.valid and surface.planet then
      surfaces[#surfaces + 1] = surface
    end
  end
  return surfaces
end

local function provider_count(surface, force, request)
  local total = 0
  local networks = {}
  for _, silo in pairs(surface.find_entities_filtered({type = "rocket-silo", force = force})) do
    local network = force.find_logistic_network_by_position(silo.position, surface)
    if network and network.valid and not networks[network.network_id] then
      networks[network.network_id] = true
      total = total + network.get_item_count(Util.item_id(request.item, request.quality), "providers")
    end
  end
  return total
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
  for _, source in pairs(sources) do
    local platform = Platforms.find_matching(request, force, source.location, request.destination)
    if platform then
      request.source = source.location
      request.source_surface_index = source.surface_index
      request.source_available = source.available
      request.source_score = source.score
      local ok, reason = Platforms.dispatch(request, platform, force)
      if ok then
        return true
      end
      request.last_reason = reason
    end
  end
  request.last_reason = request.last_reason or "No enrolled platform has this route and enough cargo space"
  return false
end

return Router
