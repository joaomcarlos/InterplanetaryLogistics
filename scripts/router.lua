local State = require("scripts.state")
local Platforms = require("scripts.platforms")
local SourceStock = require("scripts.source_stock")
local Util = require("scripts.util")

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
  local sources = {}
  for _, ranked in ipairs(SourceStock.rank(request, force)) do
    sources[#sources + 1] = {
      surface_index = ranked.surface_index,
      location = ranked.location,
      available = ranked.available,
      score = reliability_score(ranked.location, ranked.available, request.amount)
    }
  end
  table.sort(sources, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.available ~= b.available then
      return a.available > b.available
    end
    if a.location ~= b.location then
      return a.location < b.location
    end
    return a.surface_index < b.surface_index
  end)
  return sources
end

local function schedule_has_location(platform, location)
  local schedule = platform and platform.schedule
  if not schedule then return false end
  for _, record in pairs(schedule.records or {}) do
    if not record.temporary and record.station == location then
      return true
    end
  end
  return false
end

local function collect_eligible_platforms(state, force, demand, sources, destination)
  local enrolled = state.enrolled[force.index] or {}
  local source_locations = {}
  for _, source in ipairs(sources) do
    source_locations[source.location] = true
  end
  local platforms = {}
  for _, platform in pairs(force.platforms or {}) do
    if platform.valid and enrolled[platform.index] and not state.platform_shipments[platform.index] then
      local has_destination = schedule_has_location(platform, destination)
      local has_any_source = false
      for _, source in ipairs(sources) do
        if schedule_has_location(platform, source.location) then
          has_any_source = true
          break
        end
      end
      if has_destination and has_any_source then
        local capacity = Platforms.platform_capacity(platform, demand.item, demand.quality)
        if capacity >= 1 then
          local pinned = false
          for _, source in ipairs(sources) do
            if State.get_route_preference(force.index, source.location, destination) == platform.index then
              pinned = true
              break
            end
          end
          local first_source = sources[1] and sources[1].location
          local eta = Platforms.estimate_ticks_to(platform, first_source) or math.huge
          platforms[#platforms + 1] = {
            platform = platform,
            capacity = capacity,
            eta = eta,
            pinned = pinned
          }
        end
      end
    end
  end
  table.sort(platforms, function(a, b)
    if a.pinned ~= b.pinned then return a.pinned end
    if a.eta ~= b.eta then return a.eta < b.eta end
    return a.platform.index < b.platform.index
  end)
  return platforms
end

local function build_ephemeral_availability(sources)
  local available = {}
  for _, source in ipairs(sources) do
    local key = source.location
    if not available[key] or source.available > available[key] then
      available[key] = source.available
    end
  end
  return available
end

function Router.plan(demand, force)
  if demand.status ~= "approved" then
    return false
  end
  local state = State.ensure()
  local unplanned_amount = demand.unplanned_amount or demand.amount or 0
  if unplanned_amount <= 0 then
    return false
  end
  local sources = SourceStock.snapshot(demand, force)
  if #sources == 0 then
    demand.last_reason = "No planet has enough provider stock"
    return false
  end
  local ephemeral = build_ephemeral_availability(sources)
  local destination = demand.destination
  local eligible = collect_eligible_platforms(state, force, demand, sources, destination)
  if #eligible == 0 then
    demand.last_reason = "No enrolled platform is currently eligible"
    return false
  end
  local any_shipment = false
  for _, entry in ipairs(eligible) do
    if unplanned_amount <= 0 then break end
    local platform = entry.platform
    local capacity = entry.capacity
    local schedule_sources = {}
    for _, source in ipairs(sources) do
      if schedule_has_location(platform, source.location) and (ephemeral[source.location] or 0) > 0 then
        schedule_sources[#schedule_sources + 1] = source
      end
    end
    if #schedule_sources > 0 then
      local ordered_sources = Util.schedule_ordered_sources(platform, schedule_sources, destination)
      if #ordered_sources > 0 then
        local legs = {}
        local cumulative = 0
        local remaining_unplanned = unplanned_amount
        local remaining_capacity = capacity
        for _, source in ipairs(ordered_sources) do
          if remaining_unplanned <= 0 or remaining_capacity <= 0 then break end
          local available = ephemeral[source.location] or 0
          if available > 0 then
            local allocate = math.min(available, remaining_unplanned, remaining_capacity)
            if allocate > 0 then
              cumulative = cumulative + allocate
              legs[#legs + 1] = {
                source = source.location,
                planned_amount = allocate,
                cumulative_target = cumulative,
                status = "pending"
              }
              ephemeral[source.location] = available - allocate
              remaining_unplanned = remaining_unplanned - allocate
              remaining_capacity = remaining_capacity - allocate
            end
          end
        end
        if #legs > 0 then
          State.create_shipment(demand, platform, legs)
          any_shipment = true
          unplanned_amount = remaining_unplanned
        end
      end
    end
  end
  if any_shipment then
    demand.active_shipment_amount = State.active_shipment_amount(demand.id)
    demand.unplanned_amount = math.max(0, (demand.observed_shortage or demand.amount or 0) - demand.active_shipment_amount)
    demand.status = "dispatching"
    demand.last_reason = nil
    return true
  end
  demand.last_reason = demand.last_reason or "No enrolled platform is currently eligible"
  return false
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
  return Router.plan(request, force)
end

return Router
