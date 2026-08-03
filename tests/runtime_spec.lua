package.path = ".\\?.lua;.\\?\\init.lua;" .. package.path

log = function() end

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

local function test_chest_outstanding_demands()
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
  local player = {valid = true, index = 1, get_alerts = function() return {} end}
  local force = {valid = true, index = 1, players = {player}}
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
  local _, point_two = chest(2)

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

  local first = state.requests[state.request_by_key["chest|1|iron-plate|normal"]]
  local second = state.requests[state.request_by_key["chest|2|iron-plate|normal"]]
  assert_equal(first.amount, 100, "provider inventory must not hide an undelivered chest shortage")
  assert_equal(second.amount, 100, "each requester chest should publish its own outstanding need")

  point_one.targeted_items_deliver = {{name = "iron-plate", quality = "normal", count = 20}}
  Demands.scan()
  assert_equal(first.amount, 80, "only deliveries actually targeted to the chest should reduce its shortage")

  point_one.targeted_items_deliver[1].count = 100
  point_two.targeted_items_deliver = {{name = "iron-plate", quality = "normal", count = 100}}
  Demands.scan()
  assert_equal(first.status, "cancelled", "fully targeted demand should cancel its queued transfer")
  assert_equal(second.status, "cancelled", "fully targeted demand should cancel every fulfilled chest transfer")

  point_one.targeted_items_deliver = {}
  point_two.targeted_items_deliver = {}
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

local function test_scan_scheduler_is_bounded()
  reset_modules()
  storage = {}
  settings = {global = { ["il-auto-approve-seconds"] = {value = 30}, ["il-source-reserve"] = {value = 0} }}
  defines = {alert_type = {no_material_for_construction = 1}}
  local surface = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local prototype = {valid = true, name = "steel-chest", items_to_place_this = {{name = "steel-chest", count = 1}}}
  local player = {
    valid = true,
    index = 1,
    get_alerts = function()
      return {[1] = {[defines.alert_type.no_material_for_construction] = {
        {prototype = prototype, position = {x = 1, y = 1}},
        {prototype = prototype, position = {x = 2, y = 2}}
      }}}
    end
  }
  local force = {valid = true, index = 1, players = {player}}
  local chest = {
    valid = true,
    name = "interplanetary-requester-chest",
    unit_number = 1,
    force = force,
    surface = surface,
    position = {x = 0, y = 0},
    get_requester_point = function() return {filters = {}, targeted_items_deliver = {}} end
  }
  game = {
    tick = 0,
    forces = {force},
    surfaces = {surface},
    get_entity_by_unit_number = function() return chest end,
    get_surface = function() return surface end,
    get_player = function() return player end
  }
  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  state.chests[1] = true
  assert(Demands.start_scan(), "scheduler should accept a new scan")
  assert_equal(Demands.step_scan(1), false, "one budget unit should not complete all scan phases")
  assert(Demands.scan_active(), "scan should remain queued after one budget unit")
  while Demands.scan_active() do Demands.step_scan(1) end
  assert_equal(state.scan_job, nil, "completed scan should clear its job")
  assert_equal(state.scan_job, nil, "bounded demand scan should finish without losing its context")
  state.requests[1] = {id = 1, status = "queued", priority = 0, auto_approve_tick = 100}
  state.next_request_id = 2
  assert(Demands.start_process(), "scheduler should accept request processing")
  assert_equal(Demands.step_process(1), false, "request processing should respect its budget")
  while Demands.process_active() do Demands.step_process(1) end
  assert_equal(state.process_job, nil, "completed request processing should clear its job")
end

local function test_construction_alert_surface_uses_target()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local prototype = {
    valid = true,
    name = "steel-chest",
    items_to_place_this = {
      {name = "steel-chest", count = 1}
    }
  }
  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local vulcanus = {valid = true, index = 2, name = "vulcanus", planet = {name = "vulcanus"}}
  local force = {valid = true, index = 1, players = {}}
  local player = {
    valid = true,
    index = 1,
    force = force,
    get_alerts = function()
      return {
        [2] = {
          [defines.alert_type.no_material_for_construction] = {
            {
              prototype = prototype,
              position = {x = 12, y = 34},
              target = {
                valid = true,
                name = "entity-ghost",
                surface = vulcanus,
                position = {x = 56, y = 78},
                ghost_prototype = prototype,
                ghost_name = "steel-chest"
              }
            }
          }
        }
      }
    end
  }
  force.players = {player}
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = nauvis, [2] = vulcanus},
    get_surface = function(index)
      return ({[1] = nauvis, [2] = vulcanus})[index]
    end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  Demands.scan()

  local request_id = state.request_by_key["alert|1|2|steel-chest|normal"]
  assert(request_id, "construction alert should use the target surface")
  local request = state.requests[request_id]
  assert_equal(request.destination_surface_index, 2, "destination surface should come from the alert target")
  assert_equal(request.destination, "vulcanus", "destination name should use the alert target surface")
  assert_equal(request.position.x, 56, "alert target position should be preferred")
  assert_equal(request.origin, "construction-alert", "construction alert should be marked as such")
end

local function test_construction_alert_summary_is_ignored()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}
  log = function() end

  local prototype = {
    valid = true,
    items_to_place_this = {
      {name = "steel-chest", count = 1}
    }
  }
  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local force = {valid = true, index = 1, players = {}}
  local player = {
    valid = true,
    index = 1,
    force = force,
    get_alerts = function()
      return {
        [1] = {
          [defines.alert_type.no_material_for_construction] = {
            {
              prototype = prototype
            }
          }
        }
      }
    end
  }

  force.players = {player}
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = nauvis},
    get_surface = function(index)
      return ({[1] = nauvis})[index]
    end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  Demands.scan()

  assert_equal(next(state.requests), nil, "summary construction alerts should not create interplanetary requests")
  assert_equal(state.request_by_key["alert|1|1|steel-chest|normal"], nil, "summary alerts should stay ignored")
end

local function test_construction_alert_non_ghost_entity_target()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local prototype = {
    valid = true,
    name = "fast-inserter",
    items_to_place_this = {
      {name = "fast-inserter", count = 1}
    }
  }
  local unrelated_target_prototype = {
    valid = true,
    name = "construction-robot",
    items_to_place_this = {{name = "construction-robot", count = 1}}
  }
  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local force = {valid = true, index = 1, players = {}}
  local player = {
    valid = true,
    index = 1,
    force = force,
    get_alerts = function()
      return {
        [1] = {
          [defines.alert_type.no_material_for_construction] = {
            {
              prototype = prototype,
              position = {x = 10, y = 20},
              target = setmetatable({
                valid = true,
                name = "fast-inserter",
                surface = nauvis,
                position = {x = 10, y = 20},
                prototype = unrelated_target_prototype
              }, {
                __index = function(_, key)
                  assert_equal(key, "item_requests", "ordinary entities must not read item_requests")
                  error("unexpected property access: " .. key)
                end
              })
            }
          }
        }
      }
    end
  }

  local offline_player = {
    valid = true,
    connected = false,
    index = 2,
    force = force,
    get_alerts = function()
      return {[1] = {[defines.alert_type.no_material_for_construction] = {{
        prototype = unrelated_target_prototype,
        position = {x = 99, y = 99}
      }}}}
    end
  }
  force.players = {player, offline_player}
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = nauvis},
    get_surface = function(index)
      return ({[1] = nauvis})[index]
    end,
    get_entity_by_unit_number = function() return nil end
  }
  game.connected_players = {player}

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  Demands.scan()

  local request_id = state.request_by_key["alert|1|1|fast-inserter|normal"]
  assert(request_id, "non-ghost entity target alert should create a request")
  assert_equal(state.request_by_key["alert|1|1|construction-robot|normal"], nil, "ordinary alert targets must not replace the missing prototype")
  assert_equal(state.next_request_id, 2, "disconnected players' personal alerts must not become force requests")
  local request = state.requests[request_id]
  assert_equal(request.destination_surface_index, 1, "destination surface should come from the alert target")
  assert_equal(request.destination, "nauvis", "destination name should use the alert target surface")
  assert_equal(request.position.x, 10, "alert target position should be used")
  assert_equal(request.origin, "construction-alert", "non-ghost alert should be marked as construction-alert")
end

local function test_construction_alert_prototype_position_only()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local prototype = {
    valid = true,
    name = "assembling-machine-1",
    items_to_place_this = {
      {name = "assembling-machine-1", count = 1}
    }
  }
  local vulcanus = {valid = true, index = 2, name = "vulcanus", planet = {name = "vulcanus"}}
  local force = {valid = true, index = 1, players = {}}
  local player = {
    valid = true,
    index = 1,
    force = force,
    get_alerts = function()
      return {
        [2] = {
          [defines.alert_type.no_material_for_construction] = {
            {
              prototype = prototype,
              position = {x = 30, y = 40}
            }
          }
        }
      }
    end
  }

  force.players = {player}
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[2] = vulcanus},
    get_surface = function(index)
      return ({[2] = vulcanus})[index]
    end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  Demands.scan()

  local request_id = state.request_by_key["alert|1|2|assembling-machine-1|normal"]
  assert(request_id, "prototype+position alert without target should create a request")
  local request = state.requests[request_id]
  assert_equal(request.destination_surface_index, 2, "surface should come from the get_alerts surface key")
  assert_equal(request.destination, "vulcanus", "destination should use the surface from the alert key")
  assert_equal(request.position.x, 30, "alert position should be used when no target is present")
end

local function test_construction_alert_dedup()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local prototype = {
    valid = true,
    name = "solar-panel",
    items_to_place_this = {
      {name = "solar-panel", count = 1}
    }
  }
  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local force = {valid = true, index = 1, players = {}}
  local player = {
    valid = true,
    index = 1,
    force = force,
    get_alerts = function()
      return {
        [1] = {
          [defines.alert_type.no_material_for_construction] = {
            {
              prototype = prototype,
              position = {x = 5, y = 5},
              target = {
                valid = true,
                name = "entity-ghost",
                surface = nauvis,
                position = {x = 5, y = 5},
                ghost_prototype = prototype,
                ghost_name = "solar-panel"
              }
            },
            {
              prototype = prototype,
              position = {x = 5, y = 5},
              target = {
                valid = true,
                name = "entity-ghost",
                surface = nauvis,
                position = {x = 5, y = 5},
                ghost_prototype = prototype,
                ghost_name = "solar-panel"
              }
            },
            {
              prototype = prototype,
              position = {x = 6, y = 6},
              target = {
                valid = true,
                name = "entity-ghost",
                surface = nauvis,
                position = {x = 6, y = 6},
                ghost_prototype = prototype,
                ghost_name = "solar-panel"
              }
            }
          }
        }
      }
    end
  }

  force.players = {player}
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = nauvis},
    get_surface = function(index)
      return ({[1] = nauvis})[index]
    end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  Demands.scan()

  local request_id = state.request_by_key["alert|1|1|solar-panel|normal"]
  assert(request_id, "deduped construction alerts should create a request")
  local request = state.requests[request_id]
  assert_equal(request.amount, 2, "two unique positions should aggregate to count 2, not 3")
end

local function test_construction_alert_item_request_proxy()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local force = {valid = true, index = 1, players = {}}
  local player = {
    valid = true,
    index = 1,
    force = force,
    get_alerts = function()
      return {
        [1] = {
          [defines.alert_type.no_material_for_construction] = {
            {
              prototype = {valid = true, name = "item-request-proxy"},
              position = {x = 15, y = 25},
              target = {
                valid = true,
                name = "item-request-proxy",
                surface = nauvis,
                position = {x = 15, y = 25},
                item_requests = {
                  {name = "speed-module", count = 2, quality = "normal"},
                  {name = "efficiency-module", count = 1}
                }
              }
            }
          }
        }
      }
    end
  }

  force.players = {player}
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = nauvis},
    get_surface = function(index)
      return ({[1] = nauvis})[index]
    end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  Demands.scan()

  local speed_id = state.request_by_key["alert|1|1|speed-module|normal"]
  assert(speed_id, "item-request-proxy alert should create a request for speed-module")
  local speed_req = state.requests[speed_id]
  assert_equal(speed_req.amount, 2, "speed-module amount should come from item_requests")
  assert_equal(speed_req.destination_surface_index, 1, "surface should come from the proxy target")
  assert_equal(speed_req.position.x, 15, "position should come from the proxy target")

  local eff_id = state.request_by_key["alert|1|1|efficiency-module|normal"]
  assert(eff_id, "item-request-proxy alert should create a request for efficiency-module")
  local eff_req = state.requests[eff_id]
  assert_equal(eff_req.amount, 1, "efficiency-module amount should come from item_requests")
end

local function test_construction_alert_quality_and_proxy_count()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local biochamber = {valid = true, name = "biochamber", items_to_place_this = {{name = "biochamber", count = 1}}}
  local fusion = {valid = true, name = "fusion-reactor-equipment", items_to_place_this = {{name = "fusion-reactor-equipment", count = 1}}}
  local force = {valid = true, index = 1, players = {}}
  local player = {
    valid = true,
    index = 1,
    force = force,
    get_alerts = function()
      return {[1] = {[defines.alert_type.no_material_for_construction] = {
        {
          prototype = biochamber,
          target = {valid = true, name = "entity-ghost", quality = {name = "legendary"}, surface = nauvis, position = {x = 1, y = 1}, ghost_prototype = biochamber},
          position = {x = 1, y = 1}
        },
        {
          prototype = {valid = true, name = "item-request-proxy"},
          target = {
            valid = true, name = "item-request-proxy", surface = nauvis, position = {x = 2, y = 2},
            item_requests = {{name = "fusion-reactor-equipment", count = 22, quality = {name = "legendary"}}},
            proxy_target = {valid = true, name = "entity-ghost", ghost_prototype = fusion}
          },
          position = {x = 2, y = 2}
        }
      }}}
    end
  }
  force.players = {player}
  game = {
    tick = 0, forces = {force}, surfaces = {[1] = nauvis},
    get_surface = function() return nauvis end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  require("scripts.demands").scan()
  local state = State.ensure()
  local chamber = state.requests[state.request_by_key["alert|1|1|biochamber|legendary"]]
  assert(chamber, "legendary entity ghost should retain its quality")
  assert_equal(chamber.amount, 1, "entity placement count should be preserved")
  local reactors = state.requests[state.request_by_key["alert|1|1|fusion-reactor-equipment|legendary"]]
  assert(reactors, "proxy item request should retain its quality")
  assert_equal(reactors.amount, 22, "proxy request must not gain an extra placement item")
  assert_equal(state.request_by_key["alert|1|1|biochamber|normal"], nil, "legendary ghost must not create a normal request")
end

local function test_bounded_scan_unions_player_destinations()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local vulcanus = {valid = true, index = 2, name = "vulcanus", planet = {name = "vulcanus"}}
  local prototype = {valid = true, name = "concrete", items_to_place_this = {{name = "concrete", count = 1}}}
  local force = {valid = true, index = 1, players = {}}
  local function player(index, surface)
    return {
      valid = true, index = index, force = force,
      get_alerts = function()
        return {[surface.index] = {[defines.alert_type.no_material_for_construction] = {
          {prototype = prototype, position = {x = index, y = index}}
        }}}
      end
    }
  end
  local first, second = player(1, nauvis), player(2, vulcanus)
  force.players = {first, second}
  game = {
    tick = 0, forces = {force}, surfaces = {[1] = nauvis, [2] = vulcanus}, connected_players = {first, second},
    get_player = function(index) return index == 1 and first or second end,
    get_surface = function(index) return ({[1] = nauvis, [2] = vulcanus})[index] end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  assert(Demands.start_scan())
  while Demands.scan_active() do Demands.step_scan(1) end
  local state = State.ensure()
  assert(state.request_by_key["alert|1|1|concrete|normal"], "first player's destination should be detected")
  assert(state.request_by_key["alert|1|2|concrete|normal"], "second player's destination should be detected")
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
  settings = {global = {
    ["il-enable-ready-signal"] = {value = false},
    ["il-ready-signal"] = {value = "signal-green"}
  }}

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
    position = {x = 10, y = 20},
    get_item_count = function() return 20 end,
    get_logistic_sections = function() return pad_sections end
  }
  local destination_network = {valid = true, network_id = 7}
  local destination_surface = {
    valid = true,
    index = 1,
    find_entities_filtered = function() return {pad} end,
    find_logistic_network_by_position = function() return destination_network end
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
  assert_equal(#platform.schedule.records[3].wait_conditions, 2, "default pickup should use cargo and timeout conditions")
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
  State.get_platform_options(1, platform.index).ready_signal = true
  assert(Platforms.dispatch(second, platform, force))
  assert_equal(platform.schedule.records[3].wait_conditions[2].type, "circuit", "platform ready option should add a circuit condition")
  assert_equal(platform.schedule.records[3].wait_conditions[2].condition.first_signal.name, "signal-green", "ready condition should use the configured signal")
  platform.space_location = {name = "nauvis"}
  game.tick = 300
  Platforms.monitor()
  assert_equal(second.status, "failed", "empty source timeout must not be reported as a delivery")
  assert_equal(#platform.schedule.records, 2, "failed transfer should also restore the route")
  assert_equal(#hub_sections.sections, 0, "failed transfer should remove hub request section")
  assert_equal(#pad_sections.sections, 0, "failed transfer should remove landing-pad request section")
end

local function test_fleet_preferences_eta_and_reservations()
  reset_modules()
  storage = {}
  settings = {global = {}}
  game = {tick = 10}

  local inventory = {get_insertable_count = function() return 1000 end}
  local function platform(index, name, location)
    return {
      valid = true,
      index = index,
      name = name,
      hub = {valid = true, get_main_inventory = function() return inventory end},
      space_location = {name = location},
      schedule = {current = 1, records = {
        {station = "nauvis"},
        {station = "fulgora"}
      }}
    }
  end
  local fast = platform(1, "Fast", "fulgora")
  local pinned = platform(2, "Pinned", "nauvis")
  local force = {valid = true, index = 1, platforms = {pinned, fast}}
  local State = require("scripts.state")
  local Platforms = require("scripts.platforms")
  local state = State.ensure()
  state.enrolled[1] = {[1] = true, [2] = true}
  local request = {id = 1, item = "iron-plate", quality = "normal", amount = 50}

  assert_equal(Platforms.find_matching(request, force, "fulgora", "nauvis").index, 1, "platform already at source should have the earliest ETA")
  State.set_route_preference(1, "fulgora", "nauvis", 2)
  assert_equal(Platforms.find_matching(request, force, "fulgora", "nauvis").index, 2, "pinned platform should override ETA ranking")

  state.platform_transfers[1] = 10
  state.platform_transfers[2] = 11
  local unavailable, reason = Platforms.find_matching(request, force, "fulgora", "nauvis")
  assert_equal(unavailable, nil, "busy platforms should not be selected")
  assert_equal(reason, "All enrolled platforms are currently delivering other requests", "matcher should report the actual eligibility failure")
  state.platform_transfers = {}

  request.source = "fulgora"
  State.reserve(request)
  assert_equal(State.reserved_count("fulgora", "iron-plate", "normal"), 50, "active request should reserve source stock")
  State.release_reservation(1)
  assert_equal(State.reserved_count("fulgora", "iron-plate", "normal"), 0, "finishing a request should release source stock")
end

local function test_router_rank_and_dispatch()
  reset_modules()
  storage = {}
  defines = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}

  local nauvis = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local fulgora = {valid = true, index = 2, name = "fulgora", planet = {name = "fulgora"}}

  local nauvis_network = {
    valid = true,
    network_id = 1,
    get_item_count = function() return 100 end
  }
  local fulgora_network = {
    valid = true,
    network_id = 2,
    get_item_count = function() return 200 end
  }

  local nauvis_silo = {valid = true, position = {x = 0, y = 0}}
  local fulgora_silo = {valid = true, position = {x = 0, y = 0}}

  local cargo_count = 0
  local provider_queries = 0
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
    get_item_count = function() return 0 end,
    get_logistic_sections = function() return pad_sections end
  }

  local nauvis_surface = {
    valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"},
    find_entities_filtered = function(filter)
      if filter.type == "cargo-landing-pad" then return {pad} end
      return {nauvis_silo}
    end
  }
  local fulgora_surface = {
    valid = true, index = 2, name = "fulgora", planet = {name = "fulgora"},
    find_entities_filtered = function(filter)
      if filter.type == "rocket-silo" then provider_queries = provider_queries + 1 end
      return {fulgora_silo}
    end
  }

  local platform = {
    valid = true,
    index = 4,
    name = "Courier",
    hub = hub,
    space_location = {name = "fulgora"},
    schedule = {
      current = 1,
      records = {
        {station = "nauvis", wait_conditions = {{type = "time", ticks = 60}}},
        {station = "fulgora", wait_conditions = {{type = "time", ticks = 60}}}
      }
    }
  }
  local force = {
    valid = true,
    index = 1,
    platforms = {platform},
    find_logistic_network_by_position = function(_, surface)
      if surface.index == 1 then return nauvis_network end
      return fulgora_network
    end
  }
  game = {
    tick = 100,
    forces = {[1] = force},
    surfaces = {[1] = nauvis_surface, [2] = fulgora_surface},
    get_surface = function(index)
      return ({[1] = nauvis_surface, [2] = fulgora_surface})[index]
    end,
    get_entity_by_unit_number = function(unit_number) return unit_number == 50 and pad or nil end
  }

  local State = require("scripts.state")
  local Router = require("scripts.router")
  local Platforms = require("scripts.platforms")
  local state = State.ensure()
  state.enrolled[1] = {[4] = true}

  local request = {
    id = 1,
    key = "test",
    status = "approved",
    force_index = 1,
    destination_surface_index = 1,
    logistic_network_id = 7,
    destination = "nauvis",
    item = "holmium-plate",
    quality = "normal",
    amount = 50,
    origin = "chest"
  }
  state.requests[1] = request
  state.request_by_key.test = 1

  local sources = Router.rank_sources(request, force)
  assert_equal(#sources, 1, "only fulgora should qualify (nauvis is destination)")
  assert_equal(sources[1].location, "fulgora", "fulgora should be the ranked source")
  assert_equal(sources[1].available, 200, "fulgora available should be 200")

  local ok = Router.try_dispatch(request)
  assert(ok, "dispatch should succeed")
  assert_equal(provider_queries, 1, "same-tick source ranking should reuse provider queries")
  assert_equal(request.status, "loading", "request should be loading after dispatch")
  assert_equal(request.source, "fulgora", "source should be set to fulgora")
  assert_equal(#platform.schedule.records, 4, "two temporary records should be appended")

  cargo_count = 50
  Platforms.monitor()
  assert_equal(request.status, "delivering", "loaded cargo should transition to delivering")

  cargo_count = 0
  platform.space_location = {name = "nauvis"}
  game.tick = 200
  Platforms.monitor()
  assert_equal(request.status, "completed", "unloaded cargo should complete transfer")

  local metrics = state.source_metrics["fulgora"]
  assert(metrics, "source metrics should be recorded for fulgora")
  assert_equal(metrics.successes, 1, "successful transfer should increment successes")
  assert_equal(metrics.failures, 0, "no failures should be recorded")

  local second = {
    id = 2,
    key = "test-two",
    status = "approved",
    force_index = 1,
    destination_surface_index = 1,
    logistic_network_id = 7,
    destination = "nauvis",
    item = "holmium-plate",
    quality = "normal",
    amount = 999,
    origin = "chest"
  }
  state.requests[2] = second
  state.request_by_key["test-two"] = 2
  local no_match = Router.try_dispatch(second)
  assert_equal(no_match, false, "dispatch should fail when no source has enough stock")
  assert_equal(second.status, "approved", "failed dispatch should leave request approved")
  assert(second.last_reason, "failed dispatch should set a reason")

  local third = {
    id = 3,
    key = "test-three",
    status = "queued",
    force_index = 1,
    destination_surface_index = 1,
    logistic_network_id = 7,
    destination = "nauvis",
    item = "holmium-plate",
    quality = "normal",
    amount = 50,
    origin = "chest"
  }
  state.requests[3] = third
  state.request_by_key["test-three"] = 3
  local wrong_status = Router.try_dispatch(third)
  assert_equal(wrong_status, false, "try_dispatch should reject non-approved requests")
end

local function test_construction_network_scan_matches_game_alerts()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local nauvis_entities = {}
  local vulcanus_entities = {}
  local next_unit = 1
  local function placement(target, wrapper, item, quality, registered)
    local entity = {
      valid = true,
      unit_number = next_unit,
      name = wrapper,
      position = {x = next_unit, y = next_unit},
      quality = quality,
      ghost_prototype = {
        valid = true,
        name = item,
        items_to_place_this = {{name = item, count = 1}}
      },
      is_registered_for_construction = function() return registered ~= false end
    }
    next_unit = next_unit + 1
    target[#target + 1] = entity
  end
  local function proxy(target, item, count, quality)
    local entity = {
      valid = true,
      unit_number = next_unit,
      name = "item-request-proxy",
      position = {x = next_unit, y = next_unit},
      item_requests = {{name = item, count = count, quality = quality}},
      is_registered_for_construction = function() return true end
    }
    next_unit = next_unit + 1
    target[#target + 1] = entity
  end
  local function add_placements(target, wrapper, item, count, quality)
    for _ = 1, count do placement(target, wrapper, item, quality, true) end
  end

  add_placements(nauvis_entities, "tile-ghost", "concrete", 42, "normal")
  proxy(nauvis_entities, "fusion-reactor-equipment", 22, "normal")
  proxy(nauvis_entities, "fusion-reactor-equipment", 1, "normal")
  add_placements(nauvis_entities, "entity-ghost", "spidertron", 15, {name = "legendary"})
  add_placements(nauvis_entities, "entity-ghost", "biochamber", 7, {name = "legendary"})
  add_placements(nauvis_entities, "entity-ghost", "active-provider-chest", 6, {name = "legendary"})
  add_placements(nauvis_entities, "entity-ghost", "beacon", 6, {name = "legendary"})
  placement(nauvis_entities, "entity-ghost", "steel-chest", "normal", false)
  proxy(vulcanus_entities, "efficiency-module-3", 240, {name = "legendary"})
  proxy(vulcanus_entities, "energy-shield-equipment", 80, "normal")

  local function surface(index, name, entities)
    return {
      valid = true,
      index = index,
      name = name,
      planet = {name = name},
      find_entities_filtered = function() return entities end
    }
  end
  local nauvis = surface(1, "nauvis", nauvis_entities)
  local vulcanus = surface(2, "vulcanus", vulcanus_entities)
  local function cell(unit_number)
    return {
      valid = true,
      construction_radius = 1000,
      owner = {valid = true, unit_number = unit_number, position = {x = 0, y = 0}}
    }
  end
  local supply = {}
  local function network(id, cells)
    return {
      valid = true,
      network_id = id,
      cells = cells,
      get_item_count = function(item) return supply[item.name .. "|" .. item.quality] or 0 end
    }
  end
  local nauvis_network = network(101, {cell(1), cell(2)})
  local vulcanus_network = network(202, {cell(3)})
  local force = {
    valid = true,
    index = 1,
    logistic_networks = {nauvis = {nauvis_network}, vulcanus = {vulcanus_network}}
  }
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = nauvis, [2] = vulcanus},
    get_surface = function(index)
      return ({[1] = nauvis, [2] = vulcanus})[index]
    end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  assert(Demands.start_scan(), "scheduler should accept a new scan")
  assert_equal(Demands.step_scan(1), false, "construction scan should yield after its per-tick budget")
  while Demands.scan_active() do Demands.step_scan(3) end
  assert_equal(state.scan_job, nil, "completed scan should clear its job")
  local function request(surface_index, network_id, item, quality)
    local key = table.concat({"alert", 1, surface_index, network_id, item, quality}, "|")
    local id = state.request_by_key[key]
    return id and state.requests[id]
  end

  assert_equal(request(1, 101, "concrete", "normal").amount, 42, "Nauvis concrete must match the game alert")
  assert_equal(request(1, 101, "fusion-reactor-equipment", "normal").amount, 23, "proxy counts must aggregate exactly")
  assert_equal(request(1, 101, "spidertron", "legendary").amount, 15, "legendary spidertrons must not collapse to normal")
  assert_equal(request(1, 101, "biochamber", "legendary").amount, 7, "all legendary biochambers must be counted")
  assert_equal(request(1, 101, "active-provider-chest", "legendary").amount, 6, "legendary provider chests must be detected")
  assert_equal(request(1, 101, "beacon", "legendary").amount, 6, "legendary beacons must be detected")
  assert_equal(request(2, 202, "efficiency-module-3", "legendary").amount, 240, "Vulcanus quality and count must be preserved")
  assert_equal(request(2, 202, "energy-shield-equipment", "normal").amount, 80, "Vulcanus must be scanned as its own destination")
  assert_equal(request(1, 101, "steel-chest", "normal"), nil, "unregistered stale ghosts must be ignored")
  assert_equal(request(1, 101, "spidertron", "normal"), nil, "legendary ghosts must never create normal-quality requests")

  supply["concrete|normal"] = 10
  Demands.scan()
  assert_equal(request(1, 101, "concrete", "normal").amount, 32, "local network inventory must reduce only the actual shortage")
end

local function test_bounded_scan_skips_invalidated_logistic_cells()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local surface = {
    valid = true,
    index = 1,
    name = "nauvis",
    planet = {name = "nauvis"},
    find_entities_filtered = function()
      error("an invalidated logistic cell must not trigger an entity search")
    end
  }
  local cell = {
    valid = true,
    construction_radius = 50,
    owner = {valid = true, unit_number = 1, position = {x = 0, y = 0}}
  }
  local network = {
    valid = true,
    network_id = 1,
    cells = {cell},
    get_item_count = function() return 0 end
  }
  local force = {
    valid = true,
    index = 1,
    logistic_networks = {nauvis = {network}}
  }
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = surface},
    get_surface = function() return surface end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  assert(Demands.start_scan(), "scheduler should accept a new scan")
  while not (state.scan_job.construction_context
    and state.scan_job.construction_context.phase == "cell")
  do
    Demands.step_scan(1)
  end

  cell.valid = false
  cell.owner = nil
  while Demands.scan_active() do Demands.step_scan(1) end
  assert_equal(state.scan_job, nil, "invalidated cached logistic cells should be skipped safely")
end

local function test_bounded_scan_skips_invalidated_logistic_networks()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-source-reserve"] = {value = 0}
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local surface = {
    valid = true,
    index = 1,
    name = "nauvis",
    planet = {name = "nauvis"},
    find_entities_filtered = function() return {} end
  }
  local network_valid = true
  local network_data = {
    network_id = 1,
    cells = {{
      valid = true,
      construction_radius = 50,
      owner = {valid = true, unit_number = 1, position = {x = 0, y = 0}}
    }},
    get_item_count = function() return 0 end
  }
  local network = setmetatable({}, {
    __index = function(_, key)
      if key == "valid" then return network_valid end
      if not network_valid then error("LuaLogisticNetwork API call when LuaLogisticNetwork was invalid") end
      return network_data[key]
    end
  })
  local force = {
    valid = true,
    index = 1,
    logistic_networks = {nauvis = {network}}
  }
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = surface},
    get_surface = function() return surface end,
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  assert(Demands.start_scan(), "scheduler should accept a new scan")
  while not (state.scan_job.construction_context
    and state.scan_job.construction_context.phase == "network"
    and state.scan_job.construction_context.networks)
  do
    Demands.step_scan(1)
  end

  network_valid = false
  while Demands.scan_active() do Demands.step_scan(1) end
  assert_equal(state.scan_job, nil, "invalidated cached logistic networks should be skipped safely")
end

local function test_destination_registry_includes_landing_pads()
  reset_modules()
  storage = {}
  local chest = {valid = true, unit_number = 10}
  local nauvis_pad = {valid = true, unit_number = 20}
  local vulcanus_pad = {valid = true, unit_number = 30}
  local function surface(chests, pads)
    return {
      find_entities_filtered = function(filter)
        if filter.type == "cargo-landing-pad" then return pads end
        return chests
      end
    }
  end
  game = {surfaces = {surface({chest}, {nauvis_pad}), surface({}, {vulcanus_pad})}}

  local State = require("scripts.state")
  local state = State.ensure()
  assert_equal(state.destinations_initialized, false, "old saves should request a one-time destination backfill")
  state = State.ensure_destinations()
  assert(state.chests[10], "requester chests should remain registered destinations")
  assert(state.landing_pads[20], "Nauvis cargo landing pads should be registered")
  assert(state.landing_pads[30], "other-planet cargo landing pads should be registered")
  assert_equal(state.destinations_initialized, true, "destination backfill should run only once")
end

test_construction_network_scan_matches_game_alerts()
test_bounded_scan_skips_invalidated_logistic_cells()
test_bounded_scan_skips_invalidated_logistic_networks()
test_destination_registry_includes_landing_pads()
test_chest_outstanding_demands()
test_scan_scheduler_is_bounded()
test_platform_commandeering()
test_router_rank_and_dispatch()
test_fleet_preferences_eta_and_reservations()
print("runtime_spec: OK")
