return {
  chest_name = "interplanetary-requester-chest",
  dashboard_name = "il-dashboard",
  shortcut_name = "il-toggle-dashboard",
  schema_version = 2,
  history_limit = 200,
  transfer_timeout = 60 * 60 * 30,
  source_wait_timeout = 60 * 60 * 5,
  monitor_interval = 60,
  gui_refresh_interval = 120,
  stuck_timeout = 60 * 60 * 3,
  default_leg_ticks = 60 * 60 * 5,
  active_statuses = {
    queued = true,
    approved = true,
    dispatching = true,
    loading = true,
    delivering = true
  }
}
