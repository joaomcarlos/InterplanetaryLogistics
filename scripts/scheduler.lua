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
  local primary

  -- Observation queues retain their ordering, but Shipment work is an
  -- independent bounded lane below and must not be starved by them.
  if callbacks.bootstrap_active and callbacks.bootstrap_active() then
    callbacks.step_bootstrap(constants.bootstrap_work_per_tick)
    primary = "bootstrap"
  elseif callbacks.chest_dirty_active() then
    callbacks.step_chest_dirty(constants.chest_dirty_work_per_tick)
    primary = "chest-dirty"
  elseif callbacks.construction_dirty_active and callbacks.construction_dirty_active() then
    callbacks.step_construction_dirty(constants.construction_dirty_work_per_tick)
    primary = "construction-dirty"
  end

  local shipment_dirty_work = false
  if callbacks.shipment_dirty_active and callbacks.shipment_dirty_active() then
    callbacks.step_shipment_dirty(constants.shipment_dirty_work_per_tick)
    shipment_dirty_work = true
  end

  local shipment_execution_work = false
  if callbacks.start_shipment_execution and callbacks.shipment_execution_active
    and not callbacks.shipment_execution_active() then
    callbacks.start_shipment_execution()
  end
  if callbacks.shipment_execution_active and callbacks.shipment_execution_active() then
    callbacks.step_shipment_execution(constants.shipment_execution_work_per_tick)
    shipment_execution_work = true
  end

  if primary then return primary end
  if shipment_dirty_work then return "shipment-dirty" end
  if shipment_execution_work then return "shipment-execution" end

  -- Shipment maintenance has its own bounded cadence and continues while a
  -- long demand scan or routing pass is active.
  if event_tick % constants.monitor_interval == constants.shipment_maintenance_offset
    and callbacks.start_shipment_maintenance and callbacks.shipment_maintenance_active
    and not callbacks.shipment_maintenance_active() then
    callbacks.start_shipment_maintenance()
  end

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
    if callbacks.shipment_maintenance_active and callbacks.shipment_maintenance_active() then
      callbacks.step_shipment_maintenance(constants.shipment_maintenance_work_per_tick)
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

  if callbacks.shipment_maintenance_active and callbacks.shipment_maintenance_active() then
    callbacks.step_shipment_maintenance(constants.shipment_maintenance_work_per_tick)
  elseif callbacks.monitor_active() then
    callbacks.step_monitor(constants.monitor_work_per_tick)
  elseif callbacks.fleet_refresh_active() then
    callbacks.step_fleet_refresh(constants.fleet_work_per_tick)
  elseif callbacks.gui_refresh_active() then
    callbacks.step_gui_refresh(constants.gui_work_per_tick)
  end
  return "maintenance"
end

return Scheduler
