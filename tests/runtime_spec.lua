package.path = ".\\?.lua;.\\?\\init.lua;" .. package.path

local function reset_modules()
  for name in pairs(package.loaded) do
    if string.match(name, "^scripts%.") then
      package.loaded[name] = nil
    end
  end
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function test_shared_network_shortages()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local supply = 150
  local network = {
    valid = true,
    network_id = 7,
    get_item_count = function()
      return supply
    end
  }
  local surface = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local force = {valid = true, index = 1, players = {}}
  local entities = {}
  local function chest(unit_number)
    local point = {
      logistic_network = network,
      filters = {{type = "item", name = "iron-plate", quality = "normal", count = 100}},
      targeted_items_deliver = {}
    }
    local entity = {
      valid = true,
      name = "interplanetary-requester-chest",
      unit_number = unit_number,
      force = force,
      surface = surface,
      position = {x = unit_number, y = 0},
      get_requester_point = function() return point end,
      get_item_count = function() return 0 end
    }
    entities[unit_number] = entity
    return entity, point
  end
  local chest_one, point_one = chest(1)
  chest(2)

  game = {
    tick = 0,
    forces = {force},
    surfaces = {surface},
    get_entity_by_unit_number = function(unit_number) return entities[unit_number] end,
    get_surface = function() return surface end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  state.chests[1] = true
  state.chests[2] = true
  Demands.scan()

  local active = {}
  for _, request in pairs(state.requests) do
    if request.status == "queued" then
      active[#active + 1] = request
    end
  end
  assert_equal(#active, 1, "shared supply should create one shortage")
  assert_equal(active[1].chest_unit_number, 2, "allocation should be deterministic")
  assert_equal(active[1].amount, 50, "shared supply should only be counted once")

  supply = 200
  Demands.scan()
  assert_equal(active[1].status, "cancelled", "fulfilled local need should cancel queued transfer")

  supply = 0
  Demands.scan()
  local first_request = state.requests[state.request_by_key["chest|1|iron-plate|normal"]]
  assert_equal(first_request.amount, 100, "new shortage should be created after local stock disappears")
  Demands.deny(first_request.id, nil)
  local denied_id = first_request.id
  Demands.scan()
  assert_equal(state.request_by_key[first_request.key], denied_id, "denied shortage should not be raised again")

  point_one.filters = {}
  Demands.scan()
  assert_equal(state.suppressions[first_request.key], nil, "suppression should clear after request filter removal")
  assert_equal(first_request.status, "cancelled", "removed denied request should leave manual review")
  assert(chest_one.valid)
end

local function make_sections()
  local sections = {sections = {}, valid = true}
  sections.add_section = function()
    local section
    section = {
      index = #sections.sections + 1,
      valid = true,
      is_manual = true,
      group = "",
      set_slot = function(_, filter)
        section.filter = filter
      end
    }
    sections.sections[#sections.sections + 1] = section
    return section
  end
  sections.get_section = function(index)
    return sections.sections[index]
  end
  sections.remove_section = function(index)
    local section = sections.sections[index]
    if not section then
      return false
    end
    section.valid = false
    table.remove(sections.sections, index)
    for position, remaining in ipairs(sections.sections) do
      remaining.index = position
    end
    return true
  end
  return sections
end

local function test_platform_commandeering()
  reset_modules()
  storage = {}
  defines = {}
  settings = {global = {}}

  local cargo_count = 10
  local inventory = {
    get_item_count = function() return cargo_count end,
    get_insertable_count = function() return 1000 end
  }
  local hub_sections = make_sections()
  local pad_sections = make_sections()
  local hub = {
    valid = true,
    get_main_inventory = function() return inventory end,
    get_logistic_sections = function() return hub_sections end
  }
  local pad = {
    valid = true,
    unit_number = 50,
    logistic_network = {valid = true, network_id = 7},
    get_item_count = function() return 20 end,
    get_logistic_sections = function() return pad_sections end
  }
  local destination_surface = {
    valid = true,
    index = 1,
    find_entities_filtered = function() return {pad} end
  }
  local platform = {
    valid = true,
    index = 4,
    name = "Courier",
    hub = hub,
    space_location = {name = "fulgora"},
    schedule = {
      current = 2,
      records = {
        {station = "nauvis", wait_conditions = {{type = "time", ticks = 60}}},
        {station = "fulgora", wait_conditions = {{type = "time", ticks = 60}}}
      }
    }
  }
  local force = {valid = true, index = 1, platforms = {platform}}
  game = {
    tick = 100,
    forces = {[1] = force},
    get_surface = function() return destination_surface end,
    get_entity_by_unit_number = function(unit_number) return unit_number == 50 and pad or nil end
  }

  local State = require("scripts.state")
  local Platforms = require("scripts.platforms")
  local request = {
    id = 1,
    key = "test",
    status = "approved",
    force_index = 1,
    destination_surface_index = 1,
    logistic_network_id = 7,
    source = "fulgora",
    destination = "nauvis",
    item = "holmium-plate",
    quality = "normal",
    amount = 50,
    origin = "chest"
  }
  local state = State.ensure()
  state.requests[1] = request
  state.request_by_key.test = 1
  local dispatched, reason = Platforms.dispatch(request, platform, force)
  assert(dispatched, reason)
  assert_equal(#platform.schedule.records, 4, "dispatch should append two temporary records")
  assert_equal(platform.schedule.current, 3, "dispatch should activate source record")
  assert_equal(hub_sections.sections[1].filter.min, 60, "hub request should preserve baseline cargo")
  assert_equal(pad_sections.sections[1].filter.min, 70, "pad request should preserve baseline cargo")

  cargo_count = 60
  Platforms.monitor()
  assert_equal(request.status, "delivering", "full platform cargo should release source stop")

  cargo_count = 10
  platform.space_location = {name = "nauvis"}
  game.tick = 200
  Platforms.monitor()
  assert_equal(request.status, "completed", "unloaded cargo should complete transfer")
  assert_equal(#platform.schedule.records, 2, "completion should remove temporary records")
  assert_equal(platform.schedule.current, 2, "completion should restore original schedule position")
  assert_equal(#hub_sections.sections, 0, "completion should remove hub request section")
  assert_equal(#pad_sections.sections, 0, "completion should remove landing-pad request section")

  local second = {
    id = 2,
    key = "test-two",
    status = "approved",
    force_index = 1,
    destination_surface_index = 1,
    logistic_network_id = 999,
    source = "fulgora",
    destination = "nauvis",
    item = "holmium-plate",
    quality = "normal",
    amount = 50,
    origin = "chest"
  }
  state.requests[2] = second
  state.request_by_key[second.key] = 2
  platform.space_location = {name = "fulgora"}
  local mismatched, mismatch_reason = Platforms.dispatch(second, platform, force)
  assert_equal(mismatched, false, "chest transfer should reject a pad on another logistics network")
  assert_equal(mismatch_reason, "Destination has no cargo landing pad", "network mismatch should explain dispatch failure")

  second.logistic_network_id = 7
  assert(Platforms.dispatch(second, platform, force))
  platform.space_location = {name = "nauvis"}
  game.tick = 300
  Platforms.monitor()
  assert_equal(second.status, "failed", "empty source timeout must not be reported as a delivery")
  assert_equal(#platform.schedule.records, 2, "failed transfer should also restore the route")
  assert_equal(#hub_sections.sections, 0, "failed transfer should remove hub request section")
  assert_equal(#pad_sections.sections, 0, "failed transfer should remove landing-pad request section")
end

test_shared_network_shortages()
test_platform_commandeering()
print("runtime_spec: OK")
