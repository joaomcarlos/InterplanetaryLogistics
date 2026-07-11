data:extend({
  {
    type = "int-setting",
    name = "il-auto-approve-seconds",
    setting_type = "runtime-global",
    default_value = 30,
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
    type = "int-setting",
    name = "il-source-reserve",
    setting_type = "runtime-global",
    default_value = 0,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "c"
  },
  {
    type = "bool-setting",
    name = "il-enable-ready-signal",
    setting_type = "runtime-global",
    default_value = false,
    order = "d"
  },
  {
    type = "string-setting",
    name = "il-ready-signal",
    setting_type = "runtime-global",
    default_value = "signal-green",
    allowed_values = {"signal-green", "signal-check", "signal-R"},
    order = "e"
  }
})
