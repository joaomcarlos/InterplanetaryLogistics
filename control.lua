local Constants = require("scripts.constants")
local State = require("scripts.state")
local Demands = require("scripts.demands")
local Platforms = require("scripts.platforms")
local Gui = require("scripts.gui")
local Util = require("scripts.util")
local Scheduler = require("scripts.scheduler")

local function destination_kind(entity)
  if not entity or not entity.valid then return nil end
  if entity.name == Constants.chest_name then return "chest" end
  if entity.type == "cargo-landing-pad" then return "landing-pad" end
  return nil
end

local function is_construction_type(name)
  return name == "entity-ghost" or name == "tile-ghost" or name == "item-request-proxy"
end

local function register_destination(entity)
  local kind = destination_kind(entity)
  if not kind or not entity.unit_number then return end
  local state = State.ensure()
  if kind == "chest" then
    state.chests[entity.unit_number] = true
  else
    state.landing_pads[entity.unit_number] = true
  end
end

local function refresh_force_destinations(force_index)
  if not force_index then return end
  for _, player in pairs(game.connected_players or {}) do
    if player.valid and player.force and player.force.index == force_index then
      Gui.refresh_destinations_structure(player)
    end
  end
end

local function unregister_destination(entity, kind)
  if not entity or not entity.unit_number or not kind then return end
  local state = State.ensure()
  if kind == "chest" then
    state.chests[entity.unit_number] = nil
  else
    state.landing_pads[entity.unit_number] = nil
  end
end

local function on_built(event)
  local entity = event.entity or event.created_entity or event.destination
  if not entity or not entity.valid then return end
  local kind = destination_kind(entity)
  register_destination(entity)
  if kind then
    refresh_force_destinations(entity.force.index)
    if kind == "chest" and entity.unit_number then
      Demands.mark_chest_dirty(entity.unit_number)
    end
  end
  -- Track construction ghosts/proxies
  if is_construction_type(entity.name) then
    Demands.track_construction(entity)
  end
  -- Roboport topology change: re-associate tracked construction
  if entity.type == "roboport" and entity.force and entity.surface then
    Demands.reassociate_construction(entity.surface.index, entity.force.index)
  end
end

local function on_removed(event)
  local entity = event.entity
  if not entity then return end
  local kind = destination_kind(entity)
  local force_index = kind and entity.force and entity.force.index or nil
  if kind == "chest" and entity.unit_number then
    Demands.retire_chest(entity.unit_number)
  end
  unregister_destination(entity, kind)
  refresh_force_destinations(force_index)
  -- Untrack construction ghosts/proxies
  if entity.valid and is_construction_type(entity.name) then
    Demands.untrack_construction(entity)
  end
  -- Roboport topology change: re-associate tracked construction
  if entity.valid and entity.type == "roboport" and entity.force and entity.surface then
    Demands.reassociate_construction(entity.surface.index, entity.force.index)
  end
end

local function on_revive(event)
  local entity = event.entity or event.created_entity or event.destination
  if not entity or not entity.valid then return end
  -- A revived ghost becomes a real entity; untrack the ghost that was at this position
  if is_construction_type(entity.name) then
    Demands.untrack_construction(entity)
  elseif entity.surface and entity.position then
    -- The revived entity is a real entity; find and untrack any ghost at this position
    Demands.untrack_construction_at_position(entity.surface.index, entity.position)
  end
  -- The revived entity might be a destination or roboport
  local kind = destination_kind(entity)
  register_destination(entity)
  if kind then
    refresh_force_destinations(entity.force.index)
    if kind == "chest" and entity.unit_number then
      Demands.mark_chest_dirty(entity.unit_number)
    end
  end
  if entity.type == "roboport" and entity.force and entity.surface then
    Demands.reassociate_construction(entity.surface.index, entity.force.index)
  end
end

local function on_upgraded(event)
  local entity = event.entity or event.created_entity or event.destination
  if not entity or not entity.valid then return end
  -- Re-track with new quality if it's still a construction type
  if is_construction_type(entity.name) then
    Demands.track_construction(entity)
  end
end

local function on_chest_logistic_slot_changed(event)
  local entity = event.entity
  if not entity or not entity.valid or entity.name ~= Constants.chest_name then return end
  if not entity.unit_number then return end
  Demands.mark_chest_dirty(entity.unit_number)
end

local function on_platform_logistic_slot_changed(event)
  local entity = event.entity
  if not entity or not entity.valid then return end
  -- Mark shipments dirty for platforms whose hub or pad logistic slots change
  local state = State.ensure()
  if entity.type == "cargo-landing-pad" and entity.unit_number then
    for _, demand in pairs(state.demands) do
      local pad_record = state.pad_sections[demand.id]
      if pad_record and pad_record.pad_unit_number == entity.unit_number then
        local index = state.shipments_by_demand[demand.id]
        if index then
          for shipment_id in pairs(index) do
            Platforms.mark_shipment_dirty(shipment_id)
          end
        end
      end
    end
  end
end

local function on_platform_state_changed(event)
  -- When a platform changes state (arrives/leaves), mark related shipments dirty
  local platform = event.platform or event.entity
  if not platform then return end
  local state = State.ensure()
  local shipment_id = state.platform_shipments[platform.index]
  if shipment_id then
    Platforms.mark_shipment_dirty(shipment_id)
  end
end

local function on_cargo_pod_arrived(event)
  -- When cargo arrives at a platform or landing pad, mark related shipments dirty
  local entity = event.entity or event.pod
  if not entity or not entity.valid then return end
  local state = State.ensure()
  if entity.type == "cargo-landing-pad" and entity.unit_number then
    for _, demand in pairs(state.demands) do
      local pad_record = state.pad_sections[demand.id]
      if pad_record and pad_record.pad_unit_number == entity.unit_number then
        local index = state.shipments_by_demand[demand.id]
        if index then
          for shipment_id in pairs(index) do
            Platforms.mark_shipment_dirty(shipment_id)
          end
        end
      end
    end
  end
  -- If the entity is a space platform hub, mark its shipment dirty
  if entity.type == "space-platform-hub" or entity.type == "hub" then
    local force = entity.force
    if force then
      for _, platform in pairs(force.platforms or {}) do
        if platform.hub == entity then
          local shipment_id = state.platform_shipments[platform.index]
          if shipment_id then
            Platforms.mark_shipment_dirty(shipment_id)
          end
        end
      end
    end
  end
end

local function parse_id(name, prefix)
  local value = string.match(name, "^" .. prefix .. "(%d+)$")
  return value and tonumber(value) or nil
end

local function on_gui_click(event)
  local element = event.element
  if not element or not element.valid then
    return
  end
  local player = game.get_player(event.player_index)
  if not player then
    return
  end
  if element.name == "il-close" then
    Gui.close(player)
    return
  elseif element.name == "il-refresh" then
    Demands.start_scan()
    Platforms.refresh_fleet()
    Gui.refresh_structure(player)
    return
  end

  local view = string.match(element.name or "", "^il%-nav%-(%a+)$")
  if view then
    Gui.set_view(player, view)
    return
  end

  local selected_request = parse_id(element.name or "", "il%-request%-select%-")
  if selected_request then
    Gui.select_request(player, selected_request)
    return
  end

  local demand_link_id = parse_id(element.name or "", "il%-shipment%-demand%-link%-")
  if demand_link_id then
    local shipment = State.get_shipment(demand_link_id)
    if shipment and shipment.demand_id then
      Gui.select_request(player, shipment.demand_id)
    end
    return
  end

  local cancel_shipment_id = parse_id(element.name or "", "il%-cancel%-shipment%-")
  if cancel_shipment_id then
    Platforms.cancel_shipment(cancel_shipment_id, "user cancel")
    Gui.refresh_shipments_structure(player)
    return
  end

  local id = parse_id(element.name, "il%-approve%-")
  if id then
    Demands.approve(id, event.player_index, false)
    Gui.refresh_request_structure(player)
    return
  end
  id = parse_id(element.name, "il%-deny%-")
  if id then
    Demands.deny(id, event.player_index)
    Gui.refresh_request_structure(player)
    return
  end
  id = parse_id(element.name, "il%-reopen%-")
  if id then
    Demands.approve(id, event.player_index, false)
    Gui.refresh_request_structure(player)
    return
  end
  id = parse_id(element.name, "il%-priority%-up%-")
  if id then
    local request = State.ensure().requests[id]
    if request then Demands.set_priority(id, (request.priority or 0) + 1) end
    Gui.refresh_player(player)
    return
  end
  id = parse_id(element.name, "il%-priority%-down%-")
  if id then
    local request = State.ensure().requests[id]
    if request then Demands.set_priority(id, (request.priority or 0) - 1) end
    Gui.refresh_player(player)
    return
  end
  id = parse_id(element.name, "il%-platform%-enrollment%-")
  if id then
    local enrolled = Platforms.is_enrolled(player.force.index, id)
    if enrolled and State.ensure().platform_transfers[id] then
      return
    end
    enrolled = not enrolled
    Platforms.set_enrolled(player.force.index, id, enrolled)
    Gui.refresh_fleet_structure(player)
    return
  end
  id = parse_id(element.name, "il%-platform%-pin%-")
  if id then
    local platform = Util.get_platform(player.force, id)
    if platform then Platforms.pin_routes(player.force.index, platform) end
    Gui.refresh_player(player)
    return
  end
  id = parse_id(element.name, "il%-platform%-ready%-")
  if id then
    Platforms.toggle_ready_signal(player.force.index, id)
    Gui.refresh_player(player)
  end
end

local function initialize()
  State.ensure()
  State.rebuild_destinations()
  Platforms.refresh_fleet()
  Demands.start_bootstrap()
end

script.on_init(initialize)
script.on_configuration_changed(initialize)

script.on_event(defines.events.on_built_entity, on_built)
script.on_event(defines.events.on_robot_built_entity, on_built)
script.on_event(defines.events.script_raised_built, on_built)
script.on_event(defines.events.script_raised_revive, on_revive)
script.on_event(defines.events.on_entity_cloned, on_built)
if defines.events.on_entity_upgraded then
  script.on_event(defines.events.on_entity_upgraded, on_upgraded)
end

script.on_event(defines.events.on_player_mined_entity, on_removed)
script.on_event(defines.events.on_robot_mined_entity, on_removed)
script.on_event(defines.events.on_entity_died, on_removed)
script.on_event(defines.events.script_raised_destroy, on_removed)

script.on_event(defines.events.on_entity_logistic_slot_changed, on_chest_logistic_slot_changed)

-- Factorio 2.0 Space Age event handlers for shipment progress
if defines.events.on_space_platform_state_changed then
  script.on_event(defines.events.on_space_platform_state_changed, on_platform_state_changed)
end
if defines.events.on_cargo_pod_arrived then
  script.on_event(defines.events.on_cargo_pod_arrived, on_cargo_pod_arrived)
end
if defines.events.on_space_platform_logistic_slot_changed then
  script.on_event(defines.events.on_space_platform_logistic_slot_changed, on_platform_logistic_slot_changed)
end

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == Constants.shortcut_name then
    local player = game.get_player(event.player_index)
    if player then
      Gui.toggle(player)
    end
  end
end)

script.on_event("il-toggle-dashboard-input", function(event)
  local player = game.get_player(event.player_index)
  if player then
    Gui.toggle(player)
  end
end)

script.on_event(defines.events.on_gui_click, on_gui_click)
local function rebuild_open_dashboard(event)
  local player = game.get_player(event.player_index)
  if player and player.gui.screen[Constants.dashboard_name] then Gui.build(player) end
end
script.on_event(defines.events.on_player_display_resolution_changed, rebuild_open_dashboard)
script.on_event(defines.events.on_player_display_scale_changed, rebuild_open_dashboard)
script.on_event(defines.events.on_gui_closed, function(event)
  if event.element and event.element.valid and event.element.name == Constants.dashboard_name then
    local player = game.get_player(event.player_index)
    if player then
      Gui.close(player)
    end
  end
end)

script.on_event(defines.events.on_tick, function(event)
  Scheduler.step(event.tick, settings.global["il-scan-interval"].value, Constants, {
    bootstrap_active = Demands.bootstrap_active,
    step_bootstrap = Demands.step_bootstrap,
    chest_dirty_active = Demands.chest_dirty_active,
    step_chest_dirty = Demands.step_chest_dirty,
    construction_dirty_active = Demands.construction_dirty_active,
    step_construction_dirty = Demands.step_construction_dirty,
    shipment_dirty_active = Platforms.shipment_dirty_active,
    step_shipment_dirty = Platforms.step_shipment_dirty,
    shipment_execution_active = Platforms.shipment_execution_active,
    step_shipment_execution = Platforms.step_shipment_execution,
    scan_active = Demands.scan_active,
    process_active = Demands.process_active,
    start_scan = Demands.start_scan,
    step_scan = Demands.step_scan,
    start_process = Demands.start_process,
    step_process = Demands.step_process,
    shipment_maintenance_active = Platforms.shipment_maintenance_active,
    start_shipment_maintenance = Platforms.start_shipment_maintenance,
    step_shipment_maintenance = Platforms.step_shipment_maintenance,
    monitor_active = Platforms.monitor_active,
    fleet_refresh_active = Platforms.fleet_refresh_active,
    gui_refresh_active = Gui.refresh_active,
    start_monitor = Platforms.start_monitor,
    start_fleet_refresh = Platforms.start_fleet_refresh,
    start_gui_refresh = Gui.start_refresh,
    step_monitor = Platforms.step_monitor,
    step_fleet_refresh = Platforms.step_fleet_refresh,
    step_gui_refresh = Gui.step_refresh
  })
end)

remote.add_interface("interplanetary_logistics", {
  enroll_platform = function(force_index, platform_index)
    Platforms.set_enrolled(force_index, platform_index, true)
  end,
  unenroll_platform = function(force_index, platform_index)
    if not State.ensure().platform_transfers[platform_index] then
      Platforms.set_enrolled(force_index, platform_index, false)
    end
  end,
  rescan = function()
    Demands.start_scan()
  end,
  -- Temporary diagnostic interface for headless testing (read-only)
  dump_state = function()
    local state = State.ensure()
    local lines = {}
    lines[#lines + 1] = "=== Mod State ==="
    lines[#lines + 1] = "schema: " .. tostring(state.schema_version)
    lines[#lines + 1] = "bootstrap: " .. tostring(state.bootstrap_completed)
    lines[#lines + 1] = "demands: " .. tostring(state.demands and table_size(state.demands) or 0)
    lines[#lines + 1] = "shipments: " .. tostring(state.shipments and table_size(state.shipments) or 0)
    lines[#lines + 1] = "enrolled[1]: " .. tostring(state.enrolled and state.enrolled[1] and table_size(state.enrolled[1]) or 0)
    lines[#lines + 1] = "chests: " .. tostring(state.chests and table_size(state.chests) or 0)
    lines[#lines + 1] = "pads: " .. tostring(state.landing_pads and table_size(state.landing_pads) or 0)
    if state.demands then
      for id, d in pairs(state.demands) do
        lines[#lines + 1] = string.format("  Demand %s: item=%s x%s status=%s dest=%s obs=%s active=%s unplanned=%s",
          tostring(id), tostring(d.item), tostring(d.amount or 0), tostring(d.status),
          tostring(d.destination), tostring(d.observed_shortage or 0),
          tostring(d.active_shipment_amount or 0), tostring(d.unplanned_amount or 0))
      end
    end
    if state.shipments then
      for id, s in pairs(state.shipments) do
        lines[#lines + 1] = string.format("  Shipment %s: status=%s platform=%s item=%s amount=%s legs=%s",
          tostring(id), tostring(s.status), tostring(s.platform_name),
          tostring(s.item), tostring(s.amount or 0), tostring(#(s.pickup_legs or {})))
        for i, leg in ipairs(s.pickup_legs or {}) do
          lines[#lines + 1] = string.format("    Leg %d: source=%s planned=%s cum_target=%s status=%s",
            i, tostring(leg.source), tostring(leg.planned_amount or 0),
            tostring(leg.cumulative_target or 0), tostring(leg.status))
        end
      end
    end
    return table.concat(lines, "\n")
  end,
  dump_surfaces = function()
    local lines = {}
    for name, surface in pairs(game.surfaces) do
      lines[#lines + 1] = string.format("Surface %s: index=%s valid=%s planet=%s",
        name, tostring(surface.index), tostring(surface.valid),
        tostring(surface.planet and surface.planet.name or "none"))
    end
    return table.concat(lines, "\n")
  end,
  dump_platforms = function()
    local lines = {}
    for _, force in pairs(game.forces) do
      for _, platform in pairs(force.platforms or {}) do
        local loc = platform.space_location and platform.space_location.name or "none"
        local sched = platform.schedule and #platform.schedule.records or 0
        lines[#lines + 1] = string.format("Platform %s (idx=%s, force=%s): location=%s schedule_records=%s valid=%s",
          tostring(platform.name), tostring(platform.index), tostring(force.index),
          loc, tostring(sched), tostring(platform.valid))
        if platform.schedule then
          for i, rec in pairs(platform.schedule.records) do
            lines[#lines + 1] = string.format("  Record %d: station=%s temp=%s",
              i, tostring(rec.station), tostring(rec.temporary or false))
          end
        end
      end
    end
    return table.concat(lines, "\n")
  end,
  dump_entities = function()
    local lines = {}
    for name, surface in pairs(game.surfaces) do
      local pads = surface.find_entities_filtered({type = "cargo-landing-pad"})
      for _, pad in pairs(pads) do
        lines[#lines + 1] = string.format("Pad on %s: %s at %s,%s iron=%s",
          name, tostring(pad.name), tostring(pad.position.x), tostring(pad.position.y),
          tostring(pad.get_item_count("iron-plate")))
      end
      local chests = surface.find_entities_filtered({name = "interplanetary-requester-chest"})
      for _, chest in pairs(chests) do
        local point = chest.get_requester_point()
        local filters = point and point.filters or {}
        local filter_str = ""
        for _, f in pairs(filters) do
          filter_str = filter_str .. string.format("%s x%s, ", f.name, f.count)
        end
        lines[#lines + 1] = string.format("Requester chest on %s at %s,%s: iron=%s filters=[%s]",
          name, tostring(chest.position.x), tostring(chest.position.y),
          tostring(chest.get_item_count("iron-plate")), filter_str)
      end
      local providers = surface.find_entities_filtered({name = "logistic-chest-passive-provider"})
      for _, prov in pairs(providers) do
        lines[#lines + 1] = string.format("Provider on %s at %s,%s: iron=%s",
          name, tostring(prov.position.x), tostring(prov.position.y),
          tostring(prov.get_item_count("iron-plate")))
      end
    end
    return table.concat(lines, "\n")
  end,
  test_gui = function()
    local player = game.players[1]
    if not player then return "No player" end
    local results = {}
    -- Build dashboard
    local ok, err = pcall(Gui.build, player)
    results[#results + 1] = "build: " .. (ok and "OK" or "FAIL: " .. tostring(err))
    -- Navigate to each view
    local views = {"fleet", "requests", "shipments", "destinations", "history"}
    for _, view in ipairs(views) do
      local ok2, err2 = pcall(Gui.set_view, player, view)
      results[#results + 1] = "set_view(" .. view .. "): " .. (ok2 and "OK" or "FAIL: " .. tostring(err2))
    end
    -- Check if frame exists
    local frame = player.gui.screen["il-dashboard"]
    results[#results + 1] = "frame exists: " .. tostring(frame and frame.valid or false)
    -- Check each view container
    if frame then
      local view_names = {
        fleet = "il-content-fleet",
        requests = "il-content-requests",
        shipments = "il-content-shipments",
        destinations = "il-content-destinations",
        history = "il-content-history"
      }
      for view, name in pairs(view_names) do
        local found = false
        for _, child in pairs(frame.children or {}) do
          for _, c2 in pairs(child.children or {}) do
            for _, c3 in pairs(c2.children or {}) do
              if c3.name == name then
                found = true
                results[#results + 1] = "  " .. view .. " container: found, visible=" .. tostring(c3.visible)
              end
            end
          end
        end
        if not found then
          results[#results + 1] = "  " .. view .. " container: NOT FOUND"
        end
      end
    end
    return table.concat(results, "\n")
  end,
  enroll_and_scan = function()
    local force = game.forces[1]
    local results = {}
    -- Enroll all platforms
    for _, platform in pairs(force.platforms or {}) do
      Platforms.set_enrolled(force.index, platform.index, true)
      results[#results + 1] = "Enrolled: " .. platform.name
    end
    -- Start scan
    Demands.start_scan()
    results[#results + 1] = "Scan started"
    return table.concat(results, "\n")
  end,
  step_scan = function(n)
    local results = {}
    for i = 1, n or 50 do
      if Demands.scan_active() then
        Demands.step_scan(100)
      else
        results[#results + 1] = "Scan complete after " .. i .. " steps"
        break
      end
    end
    if Demands.process_active() then
      results[#results + 1] = "Process active"
    end
    return table.concat(results, "\n")
  end,
  step_process = function(n)
    local results = {}
    for i = 1, n or 50 do
      if Demands.process_active() then
        Demands.step_process(100)
      else
        results[#results + 1] = "Process complete after " .. i .. " steps"
        break
      end
    end
    return table.concat(results, "\n")
  end,
  approve_all = function()
    local state = State.ensure()
    local results = {}
    for id, demand in pairs(state.demands or {}) do
      if demand.status == "queued" then
        Demands.approve(id, nil, false)
        results[#results + 1] = "Approved demand " .. tostring(id)
      end
    end
    if #results == 0 then results[#results + 1] = "No queued demands" end
    return table.concat(results, "\n")
  end,
  step_execution = function(n)
    local results = {}
    if not Platforms.shipment_execution_active() then
      Platforms.start_shipment_execution()
      results[#results + 1] = "Started execution"
    end
    for i = 1, n or 50 do
      if Platforms.shipment_execution_active() then
        Platforms.step_shipment_execution(100)
      else
        results[#results + 1] = "Execution complete after " .. i .. " steps"
        break
      end
    end
    return table.concat(results, "\n")
  end,
  run_ticks = function(n)
    -- Just let the game run for n ticks by doing nothing
    -- The scheduler will process everything
    return "Requested " .. tostring(n or 600) .. " ticks (game.tick=" .. tostring(game.tick) .. ")"
  end,
  step_maintenance = function(n)
    local results = {}
    for i = 1, n or 50 do
      if Platforms.shipment_maintenance_active() then
        Platforms.step_shipment_maintenance(100)
      else
        results[#results + 1] = "Maintenance complete after " .. i .. " steps"
        break
      end
    end
    return table.concat(results, "\n")
  end,
  force_maintenance = function()
    Platforms.start_shipment_maintenance()
    return "Maintenance started"
  end,
  rebuild_destinations = function()
    State.rebuild_destinations()
    local state = State.ensure()
    return "Rebuilt: chests=" .. tostring(table_size(state.chests)) .. " pads=" .. tostring(table_size(state.landing_pads))
  end
})
