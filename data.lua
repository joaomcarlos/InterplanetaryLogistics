local chest_name = "interplanetary-requester-chest"
local icon = "__base__/graphics/icons/requester-chest.png"

local chest = table.deepcopy(data.raw["logistic-container"]["requester-chest"])
chest.name = chest_name
chest.icon = icon
chest.icon_size = 64
chest.minable = {mining_time = 0.2, result = chest_name}
chest.next_upgrade = nil

data:extend({
  chest,
  {
    type = "item",
    name = chest_name,
    icon = icon,
    icon_size = 64,
    subgroup = "logistic-network",
    order = "b[storage]-d[interplanetary-requester-chest]",
    inventory_move_sound = data.raw.item["requester-chest"].inventory_move_sound,
    pick_sound = data.raw.item["requester-chest"].pick_sound,
    drop_sound = data.raw.item["requester-chest"].drop_sound,
    place_result = chest_name,
    stack_size = 50
  },
  {
    type = "recipe",
    name = chest_name,
    enabled = true,
    energy_required = 1,
    ingredients = {
      {type = "item", name = "steel-chest", amount = 1},
      {type = "item", name = "advanced-circuit", amount = 5},
      {type = "item", name = "processing-unit", amount = 1}
    },
    results = {{type = "item", name = chest_name, amount = 1}}
  },
  {
    type = "shortcut",
    name = "il-toggle-dashboard",
    action = "lua",
    toggleable = true,
    associated_control_input = "il-toggle-dashboard-input",
    order = "zz[interplanetary-logistics]",
    icon = icon,
    icon_size = 64,
    small_icon = icon,
    small_icon_size = 64
  },
  {
    type = "custom-input",
    name = "il-toggle-dashboard-input",
    key_sequence = "ALT + I",
    consuming = "none"
  }
})
