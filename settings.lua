data:extend({
  {
    type = "int-setting",
    name = "il-auto-approve-seconds",
    setting_type = "runtime-global",
    default_value = 10,
    minimum_value = 0,
    maximum_value = 3600,
    order = "a"
  },
  {
    type = "int-setting",
    name = "il-scan-interval",
    setting_type = "runtime-global",
    default_value = 120,
    minimum_value = 30,
    maximum_value = 3600,
    order = "b"
  },
  {
    type = "bool-setting",
    name = "il-enable-ready-signal",
    setting_type = "runtime-global",
    default_value = false,
    order = "c"
  },
  {
    type = "string-setting",
    name = "il-ready-signal",
    setting_type = "runtime-global",
    default_value = "signal-green",
    allowed_values = {"signal-green", "signal-check", "signal-R"},
    order = "d"
  }
})
