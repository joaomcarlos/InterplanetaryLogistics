local chest_name = "interplanetary-requester-chest"
local icon = "__base__/graphics/icons/requester-chest.png"

local gui_styles = data.raw["gui-style"] and data.raw["gui-style"].default
if gui_styles then
  gui_styles.il_dashboard_frame = {type = "frame_style", parent = "frame", padding = 8}
  gui_styles.il_content_flow = {type = "vertical_flow_style", vertical_spacing = 6}
  gui_styles.il_section_title = {type = "label_style", parent = "heading_2_label", top_margin = 2, bottom_margin = 2}
  gui_styles.il_muted_label = {type = "label_style", parent = "label", font_color = {0.62, 0.62, 0.62}}
  gui_styles.il_column_header = {type = "label_style", parent = "label", font = "default-bold", font_color = {0.86, 0.86, 0.86}}
  gui_styles.il_table_header_flow = {
    type = "horizontal_flow_style", vertical_align = "center", left_padding = 8,
    right_padding = 8, top_padding = 4, bottom_padding = 4
  }
  gui_styles.il_scroll_pane = {
    type = "scroll_pane_style", parent = "scroll_pane", padding = 0,
    vertical_scroll_bar_spacing = 6
  }
  gui_styles.il_list_row = {
    type = "frame_style", parent = "inside_shallow_frame", height = 44,
    left_padding = 8, right_padding = 8, top_padding = 4, bottom_padding = 4
  }
  gui_styles.il_list_row_attention = {
    type = "frame_style", parent = "inside_shallow_frame_with_padding", height = 44,
    left_padding = 8, right_padding = 8, top_padding = 4, bottom_padding = 4
  }
  gui_styles.il_compact_button = {
    type = "button_style", parent = "button", height = 28, minimal_width = 0,
    left_padding = 8, right_padding = 8, top_padding = 0, bottom_padding = 0
  }
  gui_styles.il_metric_frame = {
    type = "frame_style", parent = "inside_shallow_frame_with_padding",
    minimal_width = 142, height = 54, horizontally_stretchable = "on"
  }
  gui_styles.il_metric_value = {type = "label_style", parent = "heading_2_label", horizontal_align = "center"}
  gui_styles.il_metric_caption = {type = "label_style", parent = "label", horizontal_align = "center", font_color = {0.65, 0.65, 0.65}}
  gui_styles.il_empty_state = {type = "label_style", parent = "label", top_margin = 20, left_margin = 8, font_color = {0.65, 0.65, 0.65}}
end

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
