local State = require("scripts.state")
local Platforms = require("scripts.platforms")
local SourceStock = require("scripts.source_stock")

local Router = {}

local function clear_dispatch_candidate(request)
  request.source = nil
  request.source_surface_index = nil
  request.source_available = nil
  request.source_score = nil
  request.platform_index = nil
  request.platform_name = nil
  request.dispatched_tick = nil
  request.eta_tick = nil
end

local function reliability_score(location, available, needed)
  local metrics = State.ensure().source_metrics[location] or {successes = 0, failures = 0}
  local attempts = metrics.successes + metrics.failures
  local success_ratio = (metrics.successes + 4) / (attempts + 5)
  local coverage = math.min(available / math.max(needed, 1), 2)
  return success_ratio * 100 + coverage * 5 + math.min(attempts, 10) * 0.1
end

function Router.rank_sources(request, force)
  local sources = SourceStock.rank(request, force)
  for _, source in ipairs(sources) do
    source.score = reliability_score(source.location, source.available, request.amount)
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
  clear_dispatch_candidate(request)
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
  local match_reason
  local dispatch_reason
  for _, source in ipairs(sources) do
    local platform, reason = Platforms.find_matching(request, force, source.location, request.destination)
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
      clear_dispatch_candidate(request)
      dispatch_reason = dispatch_reason or reason
    elseif not match_reason then
      match_reason = reason
    end
  end
  request.last_reason = dispatch_reason or match_reason or request.last_reason or "No enrolled platform is currently eligible"
  return false
end

return Router
