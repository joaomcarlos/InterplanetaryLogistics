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
    }
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

print("data_stage_spec: OK")
