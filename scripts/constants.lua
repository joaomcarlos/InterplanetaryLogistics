return {
  chest_name = "interplanetary-requester-chest",
  dashboard_name = "il-dashboard",
  shortcut_name = "il-toggle-dashboard",
  schema_version = 5,
  -- Items that genuinely cannot or should not be transported via space platform.
  -- This is a blocklist: every item NOT in this set is considered shippable.
  -- send_to_orbit_mode controls the rocket silo's own launch button, not
  -- whether a platform hub logistic request can trigger a launch, so most
  -- "not-sendable" items (cliff explosives, buildings, etc.) are shippable.
  non_shippable_items = {
    ["rocket-silo"] = true,
    ["captive-biter-spawner"] = true,
  },
  history_limit = 200,
  transfer_timeout = 60 * 60 * 30,
  source_wait_timeout = 60 * 60 * 5,
  delivery_confirmation_timeout = 60 * 60 * 5,
  monitor_interval = 60,
  monitor_offset = 5,
  shipment_maintenance_offset = 10,
  fleet_refresh_offset = 30,
  gui_refresh_interval = 120,
  gui_refresh_offset = 15,
  scan_work_per_tick = 1,
  chest_dirty_work_per_tick = 8,
  construction_dirty_work_per_tick = 8,
  shipment_dirty_work_per_tick = 8,
  shipment_execution_work_per_tick = 4,
  shipment_maintenance_work_per_tick = 4,
  bootstrap_work_per_tick = 16,
  process_work_per_tick = 1,
  monitor_work_per_tick = 1,
  fleet_work_per_tick = 1,
  gui_work_per_tick = 1,
  planning_work_per_tick = 1,
  stuck_timeout = 60 * 60 * 3,
  default_leg_ticks = 60 * 60 * 5,
  active_statuses = {
    queued = true,
    approved = true,
    dispatching = true,
    loading = true,
    delivering = true
  },
  shipment_statuses = {
    planned = true,
    loading = true,
    delivering = true,
    completed = true,
    failed = true,
    cancelled = true
  },
  pickup_leg_statuses = {
    pending = true,
    loading = true,
    completed = true,
    skipped = true
  }
}
