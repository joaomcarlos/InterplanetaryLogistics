local Constants = require("scripts.constants")
local State = require("scripts.state")
local Demands = require("scripts.demands")
local Platforms = require("scripts.platforms")
local Gui = require("scripts.gui")
local Util = require("scripts.util")

local function register_chest(entity)
  if entity and entity.valid and entity.name == Constants.chest_name and entity.unit_number then
    State.ensure().chests[entity.unit_number] = true
  end
end

local function unregister_chest(entity)
  if entity and entity.unit_number then
    State.ensure().chests[entity.unit_number] = nil
  end
end

local function on_built(event)
  register_chest(event.entity or event.created_entity or event.destination)
end

local function on_removed(event)
  unregister_chest(event.entity)
end

local function remember_tab_selection(event)
  local element = event.element
  if not element or not element.valid or element.type ~= "tabbed-pane" then
    return
  end
  local state = State.ensure()
  local gui_tabs = state.gui_tabs[event.player_index] or {}
  state.gui_tabs[event.player_index] = gui_tabs
  if gui_tabs.rebuilding then return end
  if element.name == "il-tabs" then
    gui_tabs.main_tab_index = element.selected_tab_index or 1
  elseif element.name == "il-platform-tabs" then
    gui_tabs.platform_tab_index = element.selected_tab_index or 1
  elseif element.name == "il-request-tabs" then
    gui_tabs.request_tab_index = element.selected_tab_index or 1
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

  local id = parse_id(element.name, "il%-approve%-")
  if id then
    Demands.approve(id, event.player_index, false)
    Gui.refresh_structure(player)
    return
  end
  id = parse_id(element.name, "il%-deny%-")
  if id then
    Demands.deny(id, event.player_index)
    Gui.refresh_structure(player)
    return
  end
  id = parse_id(element.name, "il%-reopen%-")
  if id then
    Demands.approve(id, event.player_index, false)
    Gui.refresh_structure(player)
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
    Gui.refresh_structure(player)
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
  State.rebuild_chests()
  Platforms.refresh_fleet()
end

script.on_init(initialize)
script.on_configuration_changed(initialize)

script.on_event(defines.events.on_built_entity, on_built)
script.on_event(defines.events.on_robot_built_entity, on_built)
script.on_event(defines.events.script_raised_built, on_built)
script.on_event(defines.events.script_raised_revive, on_built)
script.on_event(defines.events.on_entity_cloned, on_built)

script.on_event(defines.events.on_player_mined_entity, on_removed)
script.on_event(defines.events.on_robot_mined_entity, on_removed)
script.on_event(defines.events.on_entity_died, on_removed)
script.on_event(defines.events.script_raised_destroy, on_removed)

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
script.on_event(defines.events.on_gui_selected_tab_changed, remember_tab_selection)
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
  local maintenance_tick = false
  local maintenance_active = Platforms.monitor_active()
    or Platforms.fleet_refresh_active()
    or Gui.refresh_active()
  if event.tick % Constants.monitor_interval == Constants.monitor_offset then
    if not maintenance_active then Platforms.start_monitor() end
    maintenance_tick = true
  elseif event.tick % Constants.monitor_interval == Constants.fleet_refresh_offset then
    if not maintenance_active then Platforms.start_fleet_refresh() end
    maintenance_tick = true
  elseif event.tick % Constants.gui_refresh_interval == Constants.gui_refresh_offset then
    if not maintenance_active then Gui.start_refresh() end
    maintenance_tick = true
  end

  if Platforms.monitor_active() then
    Platforms.step_monitor(Constants.monitor_work_per_tick)
    maintenance_tick = true
  elseif Platforms.fleet_refresh_active() then
    Platforms.step_fleet_refresh(Constants.fleet_work_per_tick)
    maintenance_tick = true
  elseif Gui.refresh_active() then
    Gui.step_refresh(Constants.gui_work_per_tick)
    maintenance_tick = true
  end

  local interval = settings.global["il-scan-interval"].value
  if not maintenance_tick and event.tick % interval == 0 then
    Demands.start_scan()
  end
  local scan_finished = false
  if not maintenance_tick and Demands.scan_active() then
    scan_finished = Demands.step_scan(Constants.scan_work_per_tick)
    if scan_finished then Demands.start_process() end
  end
  if not maintenance_tick and not scan_finished and Demands.process_active() then
    Demands.step_process(Constants.process_work_per_tick)
  end
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
  end
})
