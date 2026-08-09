local Scheduler = {}

local function routing_active(callbacks)
  return callbacks.scan_active() or callbacks.process_active()
end

local function maintenance_active(callbacks)
  return callbacks.monitor_active()
    or callbacks.fleet_refresh_active()
    or callbacks.gui_refresh_active()
end

function Scheduler.step(event_tick, scan_interval, constants, callbacks)
  local routing = routing_active(callbacks)
  local scan_due = scan_interval > 0 and event_tick % scan_interval == 0

  if scan_due and not routing then
    callbacks.start_scan()
    routing = routing_active(callbacks)
  end

  if routing then
    if callbacks.scan_active() then
      local scan_finished = callbacks.step_scan(constants.scan_work_per_tick)
      if scan_finished then callbacks.start_process() end
    else
      callbacks.step_process(constants.process_work_per_tick)
    end
    return "routing"
  end

  local maintenance = maintenance_active(callbacks)
  if event_tick % constants.monitor_interval == constants.monitor_offset then
    if not maintenance then callbacks.start_monitor() end
  elseif event_tick % constants.monitor_interval == constants.fleet_refresh_offset then
    if not maintenance then callbacks.start_fleet_refresh() end
  elseif event_tick % constants.gui_refresh_interval == constants.gui_refresh_offset then
    if not maintenance then callbacks.start_gui_refresh() end
  end

  if callbacks.monitor_active() then
    callbacks.step_monitor(constants.monitor_work_per_tick)
  elseif callbacks.fleet_refresh_active() then
    callbacks.step_fleet_refresh(constants.fleet_work_per_tick)
  elseif callbacks.gui_refresh_active() then
    callbacks.step_gui_refresh(constants.gui_work_per_tick)
  end
  return "maintenance"
end

return Scheduler
