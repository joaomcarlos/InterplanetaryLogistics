local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = deepcopy(child)
  end
  return result
end

table.deepcopy = deepcopy

local extended = {}
data = {
  raw = {
    ["logistic-container"] = {
      ["requester-chest"] = {
        type = "logistic-container",
        name = "requester-chest",
        minable = {result = "requester-chest"},
        next_upgrade = nil
      }
    },
    item = {
      ["requester-chest"] = {
        inventory_move_sound = {filename = "move.ogg"},
        pick_sound = {filename = "pick.ogg"},
        drop_sound = {filename = "drop.ogg"}
      }
    },
    ["gui-style"] = {default = {}}
  },
  extend = function(_, prototypes)
    for _, prototype in ipairs(prototypes) do
      extended[prototype.type .. "/" .. prototype.name] = prototype
    end
  end
}

package.loaded.data = nil
require("data")

assert(extended["logistic-container/interplanetary-requester-chest"])
assert(extended["item/interplanetary-requester-chest"].place_result == "interplanetary-requester-chest")
assert(extended["recipe/interplanetary-requester-chest"].enabled == true)
assert(type(extended["shortcut/il-toggle-dashboard"].icon) == "string")
assert(extended["custom-input/il-toggle-dashboard-input"].key_sequence == "ALT + I")
assert(data.raw["gui-style"].default.il_dashboard_frame.parent == "frame")
assert(data.raw["gui-style"].default.il_content_flow.parent == "vertical_flow")
assert(data.raw["gui-style"].default.il_main_content_frame.parent == "inside_shallow_frame")
assert(data.raw["gui-style"].default.il_navigation_frame.parent == "inside_shallow_frame")
assert(data.raw["gui-style"].default.il_table_header_frame.parent == "subheader_frame")
assert(data.raw["gui-style"].default.il_scroll_pane.parent == "scroll_pane_in_shallow_frame")
assert(data.raw["gui-style"].default.il_list_row.height == 48)
assert(data.raw["gui-style"].default.il_metric_frame.height == 76)
assert(data.raw["gui-style"].default.il_square_tool_button.width == 32)
assert(data.raw["gui-style"].default.il_square_tool_button.height == 32)
for name, style in pairs(data.raw["gui-style"].default) do
  if string.match(name, "^il_") then
    assert(type(style.parent) == "string", name .. " must inherit from a Factorio base style")
  end
end

print("data_stage_spec: OK")
