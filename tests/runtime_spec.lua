package.path = ".\\?.lua;.\\?\\init.lua;" .. package.path

log = function() end

local function reset_modules()
  for name in pairs(package.loaded) do
    if string.match(name, "^scripts%.") then
      package.loaded[name] = nil
    end
  end
  prototypes = nil
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
  State.register_chest(1)
  State.register_chest(2)
  Demands.scan()

  local first = state.demands[state.demand_by_key["chest|1|iron-plate|normal"]]
  local second = state.demands[state.demand_by_key["chest|2|iron-plate|normal"]]
  assert_equal(first.amount, 100, "provider inventory must not hide an undelivered chest shortage")
  assert_equal(second.amount, 100, "each requester chest should publish its own outstanding need")

  point_one.targeted_items_deliver = {{name = "iron-plate", quality = "normal", count = 20}}
  Demands.scan()
  assert_equal(first.amount, 80, "only deliveries actually targeted to the chest should reduce its shortage")

  point_one.targeted_items_deliver[1].count = 100
  point_two.targeted_items_deliver = {{name = "iron-plate", quality = "normal", count = 100}}
  Demands.scan()
  assert_equal(first.status, "completed", "fully targeted demand should complete its queued transfer")
  assert_equal(second.status, "completed", "fully targeted demand should complete every fulfilled chest transfer")

  point_one.targeted_items_deliver = {}
  point_two.targeted_items_deliver = {}
  Demands.scan()
  local first_request = state.demands[state.demand_by_key["chest|1|iron-plate|normal"]]
  assert_equal(first_request.amount, 100, "new shortage should be created after local stock disappears")
  Demands.deny(first_request.id, nil)
  local denied_id = first_request.id
  Demands.scan()
  assert_equal(state.demand_by_key[first_request.key], denied_id, "denied shortage should not be raised again")

  point_one.filters = {}
  Demands.scan()
  assert_equal(state.suppressions[first_request.key], nil, "suppression should clear after request filter removal")
  assert_equal(first_request.status, "cancelled", "removed denied request should leave manual review")
  assert(chest_one.valid)
end

local function test_scan_scheduler_is_bounded()
  reset_modules()
  storage = {}
  settings = {global = { ["il-auto-approve-seconds"] = {value = 30} }}
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
  State.register_chest(1)
  assert(Demands.start_scan(), "scheduler should accept a new scan")
  assert_equal(Demands.step_scan(1), false, "one budget unit should not complete all scan phases")
  assert(Demands.scan_active(), "scan should remain queued after one budget unit")
  while Demands.scan_active() do Demands.step_scan(1) end
  assert_equal(state.scan_job, nil, "completed scan should clear its job")
  assert_equal(state.scan_job, nil, "bounded demand scan should finish without losing its context")
  state.demands[1] = {id = 1, status = "queued", priority = 0, auto_approve_tick = 100}
  state.next_demand_id = 2
  assert(Demands.start_process(), "scheduler should accept request processing")
  assert_equal(Demands.step_process(1), false, "request processing should respect its budget")
  while Demands.process_active() do Demands.step_process(1) end
  assert_equal(state.process_job, nil, "completed request processing should clear its job")
end

local function test_scheduler_prioritizes_routing_over_fleet_refresh()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {scan = false, process = false, fleet = true}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8
  }
  local callbacks = {
    chest_dirty_active = function() return false end,
    step_chest_dirty = function() return true end,
    scan_active = function() return state.scan end,
    process_active = function() return state.process end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1; state.scan = true end,
    step_scan = function()
      calls.step_scan = (calls.step_scan or 0) + 1
      return false
    end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1; state.process = true end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1; state.process = false end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return state.fleet end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }

  assert_equal(Scheduler.step(120, 120, constants, callbacks), "routing", "scan boundary should prioritize routing")
  assert_equal(calls.start_scan, 1, "scan should start even while fleet refresh is active")
  assert_equal(calls.step_scan, 1, "scan should advance on its starting tick")
  assert_equal(calls.step_fleet_refresh, nil, "fleet refresh must yield to routing")

  callbacks.step_scan = function()
    calls.step_scan = calls.step_scan + 1
    state.scan = false
    return true
  end
  assert_equal(Scheduler.step(121, 120, constants, callbacks), "routing", "scan completion should remain on routing lane")
  assert_equal(calls.start_process, 1, "scan completion should start request processing")
  assert_equal(calls.step_fleet_refresh, nil, "fleet refresh must remain paused during processing")

  assert_equal(Scheduler.step(122, 120, constants, callbacks), "routing", "request processing should keep routing priority")
  assert_equal(calls.step_process, 1, "request processing should advance")
end

local function test_construction_alert_surface_uses_target()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
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

  local request_id = state.demand_by_key["alert|1|2|steel-chest|normal"]
  assert(request_id, "construction alert should use the target surface")
  local request = state.demands[request_id]
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

  assert_equal(next(state.demands), nil, "summary construction alerts should not create interplanetary requests")
  assert_equal(state.demand_by_key["alert|1|1|steel-chest|normal"], nil, "summary alerts should stay ignored")
end

local function test_construction_alert_non_ghost_entity_target()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
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

  local request_id = state.demand_by_key["alert|1|1|fast-inserter|normal"]
  assert(request_id, "non-ghost entity target alert should create a request")
  assert_equal(state.demand_by_key["alert|1|1|construction-robot|normal"], nil, "ordinary alert targets must not replace the missing prototype")
  assert_equal(state.next_demand_id, 2, "disconnected players' personal alerts must not become force requests")
  local request = state.demands[request_id]
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

  local request_id = state.demand_by_key["alert|1|2|assembling-machine-1|normal"]
  assert(request_id, "prototype+position alert without target should create a request")
  local request = state.demands[request_id]
  assert_equal(request.destination_surface_index, 2, "surface should come from the get_alerts surface key")
  assert_equal(request.destination, "vulcanus", "destination should use the surface from the alert key")
  assert_equal(request.position.x, 30, "alert position should be used when no target is present")
end

local function test_construction_alert_dedup()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
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

  local request_id = state.demand_by_key["alert|1|1|solar-panel|normal"]
  assert(request_id, "deduped construction alerts should create a request")
  local request = state.demands[request_id]
  assert_equal(request.amount, 2, "two unique positions should aggregate to count 2, not 3")
end

local function test_construction_alert_item_request_proxy()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
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

  local speed_id = state.demand_by_key["alert|1|1|speed-module|normal"]
  assert(speed_id, "item-request-proxy alert should create a request for speed-module")
  local speed_req = state.demands[speed_id]
  assert_equal(speed_req.amount, 2, "speed-module amount should come from item_requests")
  assert_equal(speed_req.destination_surface_index, 1, "surface should come from the proxy target")
  assert_equal(speed_req.position.x, 15, "position should come from the proxy target")

  local eff_id = state.demand_by_key["alert|1|1|efficiency-module|normal"]
  assert(eff_id, "item-request-proxy alert should create a request for efficiency-module")
  local eff_req = state.demands[eff_id]
  assert_equal(eff_req.amount, 1, "efficiency-module amount should come from item_requests")
end

local function test_construction_alert_quality_and_proxy_count()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
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
  local chamber = state.demands[state.demand_by_key["alert|1|1|biochamber|legendary"]]
  assert(chamber, "legendary entity ghost should retain its quality")
  assert_equal(chamber.amount, 1, "entity placement count should be preserved")
  local reactors = state.demands[state.demand_by_key["alert|1|1|fusion-reactor-equipment|legendary"]]
  assert(reactors, "proxy item request should retain its quality")
  assert_equal(reactors.amount, 22, "proxy request must not gain an extra placement item")
  assert_equal(state.demand_by_key["alert|1|1|biochamber|normal"], nil, "legendary ghost must not create a normal request")
end

local function test_bounded_scan_unions_player_destinations()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
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
  assert(state.demand_by_key["alert|1|1|concrete|normal"], "first player's destination should be detected")
  assert(state.demand_by_key["alert|1|2|concrete|normal"], "second player's destination should be detected")
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
  defines = {inventory = {hub_main = 1}}
  settings = {global = {
    ["il-enable-ready-signal"] = {value = false},
    ["il-ready-signal"] = {value = "signal-green"},
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
    get_inventory = function(inventory_index)
      assert_equal(inventory_index, 1, "platform routing should read the hub_main inventory")
      return inventory
    end,
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
  local source_network = {
    valid = true,
    network_id = 8,
    get_item_count = function(_, provider_filter)
      if provider_filter ~= nil then error("source inventory must not be filtered to providers") end
      return 100
    end
  }
  local source_surface = {
    valid = true,
    index = 2,
    name = "fulgora",
    planet = {name = "fulgora"},
    find_entities_filtered = function() error("source inventory must not search entities") end
  }
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
  local force = {
    valid = true,
    index = 1,
    platforms = {platform},
    logistic_networks = {fulgora = {source_network}},
    find_logistic_network_by_position = function(_, surface)
      return surface.index == 2 and source_network or destination_network
    end
  }
  game = {
    tick = 100,
    forces = {[1] = force},
    surfaces = {[1] = destination_surface, [2] = source_surface},
    get_surface = function(index) return ({[1] = destination_surface, [2] = source_surface})[index] end,
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
  state.demands[1] = request
  state.demand_by_key.test = 1
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
  state.demands[2] = second
  state.demand_by_key[second.key] = 2
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
end

local function test_source_stock_exact_network_snapshots()
  reset_modules()
  storage = {}
  settings = {global = {}}

  local query_counts = {}
  local function surface(index, name, planet_name)
    return {
      valid = true,
      index = index,
      name = name,
      planet = {name = planet_name or name},
      find_entities_filtered = function()
        error("source stock must not search surface entities")
      end
    }
  end
  local function network(id, count)
    return {
      valid = true,
      network_id = id,
      get_item_count = function(item, provider_filter)
        assert_equal(provider_filter, nil, "source stock must not pass a provider-member filter")
        assert_equal(item.name, "quantum-processor", "source stock must query the exact item")
        assert_equal(item.quality, "legendary", "source stock must query the exact quality")
        query_counts[id] = (query_counts[id] or 0) + 1
        return count
      end
    }
  end

  local destination = surface(1, "nauvis")
  local fulgora = surface(2, "fulgora")
  local vulcanus = surface(3, "vulcanus")
  local second_fulgora = surface(4, "fulgora-secondary", "fulgora")
  local aquilo = surface(5, "aquilo")
  local empty = surface(6, "gleba")
  local orbit = {valid = true, index = 7, name = "platform-orbit"}
  local invalid_surface = {valid = false, index = 8, name = "invalid", planet = {name = "invalid"}}
  local destination_network = network(99, 1000)
  local force = {
    valid = true,
    index = 1,
    logistic_networks = {
      nauvis = {destination_network},
      fulgora = {
        {valid = false, network_id = 1, get_item_count = function() error("invalid network queried") end},
        network(9, 120),
        network(4, 120)
      },
      vulcanus = {network(3, 120), network(8, 20)},
      [4] = {network(7, 120)},
      [5] = {network(2, 80)},
      gleba = {network(6, 0)}
    }
  }
  game = {
    tick = 400,
    surfaces = {
      [1] = destination,
      [2] = fulgora,
      [3] = vulcanus,
      [4] = second_fulgora,
      [5] = aquilo,
      [6] = empty,
      [7] = orbit,
      [8] = invalid_surface
    }
  }

  package.preload["scripts.state"] = function()
    error("source stock must not load reservation state")
  end
  local loaded, SourceStock = pcall(require, "scripts.source_stock")
  package.preload["scripts.state"] = nil
  assert(loaded, SourceStock)

  local demand = {
    destination_surface_index = 1,
    item = "quantum-processor",
    quality = "legendary",
    amount = 130,
    unplanned_amount = 100
  }
  local sources = SourceStock.snapshot(demand, force)
  assert_equal(#sources, 4, "snapshot should include every positive-stock non-destination planet surface")
  assert_equal(sources[1].location, "fulgora", "equal full sources should sort by location")
  assert_equal(sources[1].surface_index, 2, "equal location sources should sort by surface index")
  assert_equal(sources[1].network_id, 4, "equal-count networks should select the lowest network id")
  assert_equal(sources[1].available, 120, "snapshot should expose the largest exact network count")
  assert_equal(sources[2].location, "fulgora", "a second surface for the same planet location should remain deterministic")
  assert_equal(sources[2].surface_index, 4, "surface index should break equal location/count ties")
  assert_equal(sources[3].location, "vulcanus", "location should precede surface and network tie breakers")
  assert_equal(sources[4].location, "aquilo", "partial stock should sort after sources covering the planning amount")
  assert_equal(sources[4].available, 80, "partial stock should remain visible in snapshots")
  assert_equal(query_counts[99], nil, "the destination surface must be excluded before network reads")

  local ranked = SourceStock.rank(demand, force)
  assert_equal(#ranked, 0, "legacy rank should require the full legacy demand amount")
  assert_equal(SourceStock.available(demand, force, "fulgora", false), 120,
    "compatibility availability should use the largest matching surface, without reserves or reservations")
end

local function test_source_stock_same_tick_cache_and_fresh_bypass()
  reset_modules()
  storage = {}
  settings = {global = {}}

  local first_count = 50
  local second_count = 40
  local queries = 0
  local function network(id, read_count)
    return {
      valid = true,
      network_id = id,
      get_item_count = function(item, provider_filter)
        assert_equal(provider_filter, nil, "cached source reads must never use a provider filter")
        assert_equal(item.name, "iron-plate")
        assert_equal(item.quality, "legendary")
        queries = queries + 1
        return read_count()
      end
    }
  end
  local function source_surface(index, name)
    return {
      valid = true,
      index = index,
      name = name,
      planet = {name = "fulgora"},
      find_entities_filtered = function()
        error("cached source reads must not discover entities")
      end
    }
  end
  local destination = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local first = source_surface(2, "fulgora")
  local second = source_surface(3, "fulgora-moon")
  local force = {
    valid = true,
    index = 2,
    logistic_networks = {
      fulgora = {network(10, function() return first_count end)},
      [3] = {network(11, function() return second_count end)}
    }
  }
  game = {tick = 500, surfaces = {[1] = destination, [2] = first, [3] = second}}

  local SourceStock = require("scripts.source_stock")
  local demand = {
    destination_surface_index = 1,
    item = "iron-plate",
    quality = "legendary",
    amount = 45
  }
  local initial = SourceStock.snapshot(demand, force)
  assert_equal(initial[1].available, 50, "initial snapshot should read current network inventory")
  assert_equal(queries, 2, "initial snapshot should read each matching surface once")

  first_count = 70
  second_count = 60
  local cached = SourceStock.snapshot(demand, force)
  assert_equal(cached[1].available, 50, "same-tick snapshots should reuse raw largest-network results")
  assert_equal(queries, 2, "same-tick snapshots should not re-query networks")
  assert_equal(SourceStock.available(demand, force, "fulgora", true), 70,
    "fresh compatibility reads should bypass same-tick cached data")
  assert_equal(queries, 4, "fresh availability should re-read every matching surface")
  assert_equal(SourceStock.available(demand, force, "fulgora", false), 50,
    "fresh bypass should not replace the existing same-tick snapshot cache")
  assert_equal(queries, 4, "cached availability should remain query-free after a fresh bypass")

  game.tick = 501
  assert_equal(SourceStock.available(demand, force, "fulgora", false), 70,
    "a new tick should invalidate cached network results")
  assert_equal(queries, 6, "new-tick availability should read matching surfaces again")
end

local function make_planning_env()
  reset_modules()
  storage = {}
  defines = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
  }}

  local surfaces = {}
  local platforms_list = {}
  local force = {valid = true, index = 1, platforms = platforms_list, logistic_networks = {}}

  local function surface(index, name)
    local s = {valid = true, index = index, name = name, planet = {name = name},
      find_entities_filtered = function() return {} end}
    surfaces[index] = s
    return s
  end

  local function network(surface_name, net_id, stock)
    local n = {valid = true, network_id = net_id,
      get_item_count = function() return stock end}
    force.logistic_networks[surface_name] = force.logistic_networks[surface_name] or {}
    table.insert(force.logistic_networks[surface_name], n)
    return n
  end

  local function platform(index, name, location, stations, capacity)
    local inv = {get_insertable_count = function() return capacity or 1000 end}
    local records = {}
    for _, st in ipairs(stations) do
      records[#records + 1] = {station = st, wait_conditions = {{type = "time", ticks = 60}}}
    end
    local p = {valid = true, index = index, name = name,
      hub = {valid = true, get_main_inventory = function() return inv end},
      space_location = {name = location},
      schedule = {current = 1, records = records}}
    platforms_list[#platforms_list + 1] = p
    return p
  end

  game = {tick = 100, forces = {[1] = force}, surfaces = surfaces,
    get_surface = function(idx) return surfaces[idx] end,
    get_entity_by_unit_number = function() return nil end}

  surface(1, "nauvis")
  surface(2, "fulgora")
  surface(3, "vulcanus")
  surface(4, "aquilo")

  local State = require("scripts.state")
  local Router = require("scripts.router")
  local state = State.ensure()

  local function make_demand(id, amount, item)
    local d = {id = id, key = "test-" .. id, status = "approved", force_index = 1,
      destination_surface_index = 1, logistic_network_id = 7,
      destination = "nauvis", item = item or "iron-plate", quality = "normal",
      amount = amount, observed_shortage = amount, origin = "chest"}
    state.demands[id] = d
    state.demand_by_key[d.key] = id
    return d
  end

  return {State = State, Router = Router, state = state, force = force,
    surface = surface, network = network, platform = platform, make_demand = make_demand}
end

local function test_plan_single_source_single_ship()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 50)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with one source and one ship")
  assert_equal(demand.status, "dispatching", "demand should be dispatching after planning")
  assert_equal(demand.active_shipment_amount, 50, "active shipment amount should match demand")
  assert_equal(demand.unplanned_amount, 0, "unplanned amount should be zero after full coverage")
  local shipment = env.state.shipments[1]
  assert(shipment, "a shipment should be created")
  assert_equal(shipment.status, "planned", "shipment should be in planned status")
  assert_equal(shipment.demand_id, 1, "shipment should reference the demand")
  assert_equal(shipment.platform_index, 4, "shipment should reference the platform")
  assert_equal(shipment.amount, 50, "shipment amount should be 50")
  assert_equal(shipment.allocated_amount, 50, "allocated amount should match amount")
  assert_equal(#shipment.pickup_legs, 1, "single source should produce one pickup leg")
  assert_equal(shipment.pickup_legs[1].source, "fulgora", "leg source should be fulgora")
  assert_equal(shipment.pickup_legs[1].planned_amount, 50, "leg planned amount should be 50")
  assert_equal(shipment.pickup_legs[1].cumulative_target, 50, "cumulative target should be 50")
  assert_equal(shipment.pickup_legs[1].status, "pending", "leg status should be pending")
  assert_equal(env.state.platform_shipments[4], 1, "platform should be indexed by shipment")
end

local function test_plan_multi_source_single_ship()
  local env = make_planning_env()
  env.network("fulgora", 2, 50)
  env.network("vulcanus", 3, 30)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora", "vulcanus"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 80)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with two sources and one ship")
  local shipment = env.state.shipments[1]
  assert(shipment, "a shipment should be created")
  assert_equal(shipment.amount, 80, "shipment amount should be 80")
  assert_equal(#shipment.pickup_legs, 2, "two sources should produce two pickup legs")
  assert_equal(shipment.pickup_legs[1].source, "fulgora", "first leg should be fulgora (schedule order from current)")
  assert_equal(shipment.pickup_legs[1].planned_amount, 50, "first leg should take all 50 from fulgora")
  assert_equal(shipment.pickup_legs[1].cumulative_target, 50, "first leg cumulative should be 50")
  assert_equal(shipment.pickup_legs[2].source, "vulcanus", "second leg should be vulcanus")
  assert_equal(shipment.pickup_legs[2].planned_amount, 30, "second leg should take remaining 30 from vulcanus")
  assert_equal(shipment.pickup_legs[2].cumulative_target, 80, "second leg cumulative should be 80")
end

local function test_plan_multi_ship()
  local env = make_planning_env()
  env.network("fulgora", 2, 150)
  env.platform(4, "Alpha", "fulgora", {"nauvis", "fulgora"}, 100)
  env.platform(5, "Beta", "fulgora", {"nauvis", "fulgora"}, 100)
  env.state.enrolled[1] = {[4] = true, [5] = true}
  local demand = env.make_demand(1, 150)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with one source and two ships")
  assert_equal(demand.active_shipment_amount, 150, "two shipments should cover the full demand")
  assert_equal(demand.unplanned_amount, 0, "unplanned amount should be zero")
  local s1 = env.state.shipments[1]
  local s2 = env.state.shipments[2]
  assert(s1 and s2, "two shipments should be created")
  assert_equal(s1.amount + s2.amount, 150, "combined shipment amounts should equal demand")
  assert_equal(#s1.pickup_legs, 1, "each shipment should have one leg")
  assert_equal(#s2.pickup_legs, 1, "each shipment should have one leg")
  assert_equal(s1.pickup_legs[1].planned_amount + s2.pickup_legs[1].planned_amount, 150,
    "combined leg amounts should equal demand")
  assert_equal(env.state.platform_shipments[4], s1.id, "first platform assigned to first shipment")
  assert_equal(env.state.platform_shipments[5], s2.id, "second platform assigned to second shipment")
end

local function test_plan_ephemeral_availability()
  local env = make_planning_env()
  env.network("fulgora", 2, 50)
  env.network("vulcanus", 3, 50)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora", "vulcanus"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 80)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with ephemeral availability tracking")
  local shipment = env.state.shipments[1]
  assert(shipment, "a shipment should be created")
  assert_equal(shipment.amount, 80, "shipment amount should be 80")
  assert_equal(#shipment.pickup_legs, 2, "two legs for two sources")
  assert_equal(shipment.pickup_legs[1].planned_amount, 50, "first leg should take all 50 from fulgora")
  assert_equal(shipment.pickup_legs[2].planned_amount, 30, "second leg should take only 30, not 50")
  assert_equal(shipment.pickup_legs[2].cumulative_target, 80, "cumulative target should be 80")
end

local function test_plan_schedule_ordered_legs()
  local env = make_planning_env()
  env.network("fulgora", 2, 50)
  env.network("vulcanus", 3, 50)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora", "vulcanus"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 80)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with schedule-ordered legs")
  local shipment = env.state.shipments[1]
  assert_equal(shipment.pickup_legs[1].source, "fulgora", "ship at fulgora should pick up fulgora first")
  assert_equal(shipment.pickup_legs[2].source, "vulcanus", "vulcanus should be second in schedule order")
end

local function test_plan_source_not_in_schedule_skipped()
  local env = make_planning_env()
  env.network("fulgora", 2, 50)
  env.network("vulcanus", 3, 50)
  env.network("aquilo", 4, 50)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 50)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed using only scheduled sources")
  local shipment = env.state.shipments[1]
  assert_equal(#shipment.pickup_legs, 1, "only one leg for the one scheduled source")
  assert_equal(shipment.pickup_legs[1].source, "fulgora", "only fulgora should be used")
  assert_equal(shipment.amount, 50, "shipment should cover the full demand from fulgora")
end

local function test_plan_no_eligible_ships()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  local demand = env.make_demand(1, 50)
  local ok = env.Router.try_dispatch(demand)
  assert_equal(ok, false, "planning should fail with no enrolled ships")
  assert_equal(demand.status, "approved", "demand should stay approved with no eligible ships")
  assert(demand.last_reason, "failed planning should set a reason")
end

local function test_plan_no_sources()
  local env = make_planning_env()
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 50)
  local ok = env.Router.try_dispatch(demand)
  assert_equal(ok, false, "planning should fail with no source stock")
  assert_equal(demand.status, "approved", "demand should stay approved with no sources")
  assert(demand.last_reason, "failed planning should set a reason")
end

local function test_plan_demand_amounts_updated()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  assert_equal(demand.active_shipment_amount, 50, "active_shipment_amount should be updated after planning")
  assert_equal(demand.unplanned_amount, 0, "unplanned_amount should be updated after planning")
end

local function test_plan_platform_already_assigned_skipped()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(4, "Alpha", "fulgora", {"nauvis", "fulgora"})
  env.platform(5, "Beta", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true, [5] = true}
  env.state.platform_shipments[4] = 999
  local demand = env.make_demand(1, 50)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with the idle platform")
  local shipment = env.state.shipments[1]
  assert_equal(shipment.platform_index, 5, "already-assigned platform should be skipped")
end

local function test_plan_pinned_route_priority()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(4, "Alpha", "nauvis", {"nauvis", "fulgora"})
  env.platform(5, "Beta", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true, [5] = true}
  env.State.set_route_preference(1, "fulgora", "nauvis", 4)
  local demand = env.make_demand(1, 50)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with pinned route priority")
  local shipment = env.state.shipments[1]
  assert_equal(shipment.platform_index, 4, "pinned platform should get priority despite higher ETA")
end

local function test_plan_deterministic_ordering()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(5, "Beta", "fulgora", {"nauvis", "fulgora"})
  env.platform(4, "Alpha", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true, [5] = true}
  local demand = env.make_demand(1, 50)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with deterministic ordering")
  local shipment = env.state.shipments[1]
  assert_equal(shipment.platform_index, 4, "equal-score platforms should be sorted by index")
end

local function test_plan_partial_coverage()
  local env = make_planning_env()
  env.network("fulgora", 2, 30)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 100)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with partial coverage")
  local shipment = env.state.shipments[1]
  assert_equal(shipment.amount, 30, "shipment should only plan available stock")
  assert_equal(demand.active_shipment_amount, 30, "active amount should reflect partial coverage")
  assert_equal(demand.unplanned_amount, 70, "unplanned amount should remain positive")
end

local function test_plan_non_approved_rejected()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 50)
  demand.status = "queued"
  local ok = env.Router.try_dispatch(demand)
  assert_equal(ok, false, "planning should reject non-approved demands")
end

local function test_plan_clears_legacy_source_fields()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 50)
  demand.source = "vulcanus"
  demand.source_surface_index = 3
  demand.source_available = 10
  demand.source_score = 5
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed after clearing legacy fields")
  assert_equal(demand.source, "fulgora", "source should be set to the first pickup leg source after dispatch")
  assert_equal(demand.source_surface_index, nil, "legacy source_surface_index should be cleared")
  assert_equal(demand.source_available, nil, "legacy source_available should be cleared")
  assert_equal(demand.source_score, nil, "legacy source_score should be cleared")
end

local function test_demand_source_tracking()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.platform(4, "Courier", "fulgora", {"nauvis", "fulgora"})
  env.state.enrolled[1] = {[4] = true}
  local demand = env.make_demand(1, 50)
  assert_equal(demand.source, nil, "source should be unknown before dispatch")
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed")
  assert_equal(demand.source, "fulgora", "source should be set to first pickup leg source after dispatch")
  env.State.cancel_shipment(1)
  assert_equal(demand.source, nil, "source should clear when all shipments are cancelled")
end

local function test_demand_source_updates_when_first_shipment_cancels()
  local env = make_planning_env()
  env.network("fulgora", 2, 150)
  env.platform(4, "Alpha", "fulgora", {"nauvis", "fulgora"}, 100)
  env.platform(5, "Beta", "vulcanus", {"nauvis", "vulcanus", "fulgora"}, 100)
  env.network("vulcanus", 3, 150)
  env.state.enrolled[1] = {[4] = true, [5] = true}
  local demand = env.make_demand(1, 150)
  local ok = env.Router.try_dispatch(demand)
  assert(ok, "planning should succeed with two ships")
  assert(demand.source, "source should be set after multi-ship dispatch")
  local first_source = demand.source
  local first_shipment_id
  for shipment_id in pairs(env.state.shipments_by_demand[1] or {}) do
    local s = env.state.shipments[shipment_id]
    if s and s.pickup_legs and s.pickup_legs[1] and s.pickup_legs[1].source == first_source then
      first_shipment_id = shipment_id
      break
    end
  end
  assert(first_shipment_id, "should find the shipment matching the primary source")
  env.State.cancel_shipment(first_shipment_id)
  assert(demand.source, "source should remain set while another active shipment exists")
  assert(demand.source ~= first_source, "source should update to the next active shipment source after cancel")
end

local function test_router_rank_sources_still_works()
  local env = make_planning_env()
  env.network("fulgora", 2, 200)
  env.network("vulcanus", 3, 150)
  local demand = env.make_demand(1, 100, "holmium-plate")
  local sources = env.Router.rank_sources(demand, env.force)
  assert_equal(#sources, 2, "both fulgora and vulcanus should qualify as full-coverage sources")
  assert_equal(sources[1].location, "fulgora", "fulgora should rank first with more stock")
  assert_equal(sources[1].available, 200, "fulgora available should be 200")
  assert_equal(sources[2].location, "vulcanus", "vulcanus should rank second")
end

local function test_construction_network_scan_matches_game_alerts()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
  }}
  defines = {alert_type = {no_material_for_construction = 1}}
  prototypes = {item = {
    concrete = {send_to_orbit_mode = "automated"},
    ["fusion-reactor-equipment"] = {send_to_orbit_mode = "automated"},
    spidertron = {send_to_orbit_mode = "automated"},
    biochamber = {send_to_orbit_mode = "automated"},
    ["active-provider-chest"] = {send_to_orbit_mode = "automated"},
    beacon = {send_to_orbit_mode = "automated"},
    ["steel-chest"] = {send_to_orbit_mode = "automated"},
    ["efficiency-module-3"] = {send_to_orbit_mode = "automated"},
    ["energy-shield-equipment"] = {send_to_orbit_mode = "automated"},
    ["rocket-silo"] = {send_to_orbit_mode = "not-sendable"},
    ["captive-biter-spawner"] = {send_to_orbit_mode = "not-sendable"},
    ["iron-plate"] = {send_to_orbit_mode = "automated"},
  }}

  local nauvis_entities = {}
  local vulcanus_entities = {}
  local all_entities = {}
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
    all_entities[next_unit] = entity
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
    all_entities[next_unit] = entity
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

  local supply = {}
  local function network(id, cells)
    return {
      valid = true,
      network_id = id,
      cells = cells,
      get_item_count = function(item) return supply[item.name .. "|" .. item.quality] or 0 end
    }
  end
  local nauvis_network = network(101, {})
  local vulcanus_network = network(202, {})
  local force = {
    valid = true,
    index = 1,
    logistic_networks = {nauvis = {nauvis_network}, vulcanus = {vulcanus_network}}
  }
  local function surface(index, name, entities, net)
    return {
      valid = true,
      index = index,
      name = name,
      planet = {name = name},
      find_entities_filtered = function() return entities end,
      find_logistic_network_by_position = function() return net end
    }
  end
  local nauvis = surface(1, "nauvis", nauvis_entities, nauvis_network)
  local vulcanus = surface(2, "vulcanus", vulcanus_entities, vulcanus_network)
  -- Attach force and surface to all entities for track_construction
  for _, entity in pairs(all_entities) do
    entity.force = force
    if entity.position.x <= 50 then
      entity.surface = nauvis
    else
      entity.surface = vulcanus
    end
  end
  -- Override surface assignment based on which entity list they're in
  for _, entity in ipairs(nauvis_entities) do entity.surface = nauvis end
  for _, entity in ipairs(vulcanus_entities) do entity.surface = vulcanus end

  local function cell(unit_number)
    return {
      valid = true,
      construction_radius = 1000,
      owner = {valid = true, unit_number = unit_number, position = {x = 0, y = 0}}
    }
  end
  nauvis_network.cells = {cell(1), cell(2)}
  vulcanus_network.cells = {cell(3)}

  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = nauvis, [2] = vulcanus},
    get_surface = function(index)
      return ({[1] = nauvis, [2] = vulcanus})[index]
    end,
    get_entity_by_unit_number = function(unit_number) return all_entities[unit_number] end
  }

  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  -- Bootstrap discovers existing ghosts/proxies and populates tracked_construction
  assert(Demands.start_bootstrap(), "bootstrap should start")
  assert_equal(Demands.step_bootstrap(1), false, "bootstrap should yield after its per-tick budget")
  while Demands.bootstrap_active() do Demands.step_bootstrap(16) end
  assert_equal(state.bootstrap_job, nil, "completed bootstrap should clear its job")
  -- Process construction dirty queue to create demands
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(16) end

  local function request(surface_index, network_id, item, quality)
    local key = table.concat({"alert", 1, surface_index, network_id, item, quality}, "|")
    local id = state.demand_by_key[key]
    return id and state.demands[id]
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
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local surface = {
    valid = true,
    index = 1,
    name = "nauvis",
    planet = {name = "nauvis"},
    find_entities_filtered = function()
      error("an invalidated logistic cell must not trigger an entity search")
    end,
    find_logistic_network_by_position = function() return nil end
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
  assert(Demands.start_bootstrap(), "bootstrap should start")
  while not (state.bootstrap_job and state.bootstrap_job.phase == "cell") do
    Demands.step_bootstrap(1)
  end

  cell.valid = false
  cell.owner = nil
  while Demands.bootstrap_active() do Demands.step_bootstrap(1) end
  assert_equal(state.bootstrap_job, nil, "invalidated cached logistic cells should be skipped safely")
end

local function test_bounded_scan_skips_invalidated_logistic_networks()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
  }}
  defines = {alert_type = {no_material_for_construction = 1}}

  local surface = {
    valid = true,
    index = 1,
    name = "nauvis",
    planet = {name = "nauvis"},
    find_entities_filtered = function() return {} end,
    find_logistic_network_by_position = function() return nil end
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
  assert(Demands.start_bootstrap(), "bootstrap should start")
  while not (state.bootstrap_job and state.bootstrap_job.phase == "network"
    and state.bootstrap_job.networks) do
    Demands.step_bootstrap(1)
  end

  network_valid = false
  while Demands.bootstrap_active() do Demands.step_bootstrap(1) end
  assert_equal(state.bootstrap_job, nil, "invalidated cached logistic networks should be skipped safely")
end

local function test_state_schema_v3_initialization_and_indexes()
  reset_modules()
  storage = {}

  local Constants = require("scripts.constants")
  local State = require("scripts.state")
  local state = State.ensure()

  assert_equal(Constants.schema_version, 5, "Demand/Shipment persistence must use schema version 5")
  assert_equal(state.schema_version, 5, "fresh state must use schema version 5")
  assert(state.demands and state.demand_by_key and state.shipments and state.shipments_by_demand)
  assert(state.platform_shipments and state.tracked_construction)
  assert(state.chest_dirty and state.construction_dirty and state.shipment_dirty)
  assert_equal(state.next_demand_id, 1, "fresh demand ids must start at 1")
  assert_equal(state.next_shipment_id, 1, "fresh shipment ids must start at 1")
  assert_equal(state.requests, nil, "legacy requests alias must be dropped")
  assert_equal(state.request_by_key, nil, "legacy request_by_key alias must be dropped")
  assert_equal(state.bootstrap_job, nil, "fresh bootstrap job must be idle")
  assert_equal(state.reconciliation_job, nil, "fresh reconciliation job must be idle")

  state.demands[4] = {id = 4}
  state.shipments[7] = {id = 7, demand_id = 4, allocated_amount = 30, status = "loading"}
  state.shipments[8] = {id = 8, demand_id = 4, allocated_amount = 20, status = "completed"}
  State.add_shipment_index(4, 8)
  State.add_shipment_index(4, 7)
  assert_equal(State.get_demand(4), state.demands[4], "get_demand must return the persisted demand")
  assert_equal(State.get_shipment(7), state.shipments[7], "get_shipment must return the persisted shipment")
  assert_equal(State.active_shipment_amount(4), 30, "only nonterminal child Shipments count as active")
  State.remove_shipment_index(4, 7)
  assert_equal(State.active_shipment_amount(4), 0, "removed Shipment indexes must stop contributing")
  assert_equal(state.shipments_by_demand[4][8], true, "removing one Shipment must retain sibling indexes")
  State.remove_shipment_index(4, 8)
  assert_equal(state.shipments_by_demand[4], nil, "empty demand Shipment indexes must be removed")
end

local function test_state_schema_v3_migrates_legacy_requests_and_transfers()
  reset_modules()
  local first = {
    id = 3,
    key = "chest|30|iron-plate|legendary",
    status = "delivering",
    amount = 25,
    item = "iron-plate",
    quality = "legendary",
    destination = "vulcanus",
    destination_surface_index = 2,
    logistic_network_id = 17,
    priority = 4,
    approved_by = "Engineer",
    approved_tick = 120,
    denied_by = nil,
    suppression = "retain-me",
    history_id = 88
  }
  local second = {
    id = 9,
    key = "alert|1|1|101|concrete|normal",
    status = "loading",
    amount = 40,
    item = "concrete",
    quality = "normal",
    destination = "nauvis",
    destination_surface_index = 1,
    logistic_network_id = 101,
    priority = 2,
    denied_tick = 70,
    suppression_key = "legacy-suppression",
    history = {5, 6}
  }
  local unallocated = {
    id = 11,
    key = "chest|31|copper-plate|normal",
    status = "queued",
    amount = 15,
    item = "copper-plate",
    quality = "normal",
    destination = "fulgora",
    destination_surface_index = 3,
    logistic_network_id = 22,
    priority = 1
  }
  local transfers = {
    [9] = {
      request_id = 9, force_index = 1, platform_index = 90, platform_name = "Beta",
      source = "fulgora", destination = "nauvis", item = "concrete", quality = "normal",
      amount = 40, baseline_count = 5, target_count = 45, original_current = 3,
      hub_section_index = 13, pad_unit_number = 900, pad_section_index = 14,
      pad_baseline_count = 7, started_tick = 250, loaded_full = false
    },
    [3] = {
      request_id = 3, force_index = 1, platform_index = 30, platform_name = "Alpha",
      source = "nauvis", destination = "vulcanus", item = "iron-plate", quality = "legendary",
      amount = 25, baseline_count = 10, target_count = 35, original_current = 2,
      hub_section_index = 11, pad_unit_number = 300, pad_section_index = 12,
      pad_baseline_count = 4, started_tick = 200, loaded_full = true
    }
  }
  storage = {interplanetary_logistics = {
    schema_version = 2,
    requests = {[9] = second, [3] = first, [11] = unallocated},
    request_by_key = {[second.key] = 9, [first.key] = 3, [unallocated.key] = 11},
    next_request_id = 12,
    active_transfers = transfers,
    platform_transfers = {[90] = 9, [30] = 3}
  }}

  local State = require("scripts.state")
  local state = State.ensure()

  assert_equal(state.schema_version, 5, "legacy state must migrate to schema version 5")
  assert_equal(state.requests, nil, "migrated state must drop legacy requests alias")
  assert_equal(state.request_by_key, nil, "migrated state must drop legacy request_by_key alias")
  assert_equal(state.demands[3], first, "migration must preserve Demand table identity and fields")
  assert_equal(state.demands[9], second, "migration must preserve every legacy request")
  assert_equal(state.next_demand_id, 12, "migration must preserve next request id continuity")
  assert_equal(state.next_request_id, nil, "legacy next request id must be dropped after migration")
  assert_equal(first.observed_shortage, 25, "observed shortage must default to the legacy amount")
  assert_equal(first.active_shipment_amount, 25, "active Shipment amount must be aggregated onto the Demand")
  assert_equal(first.unplanned_amount, 0, "fully allocated Demand must have no unplanned amount")
  assert_equal(second.observed_shortage, 40, "each Demand must receive an observed shortage")
  assert_equal(second.active_shipment_amount, 40, "each Demand must aggregate its active Shipment")
  assert_equal(second.unplanned_amount, 0, "allocated amount must be subtracted from observed shortage")
  assert_equal(unallocated.active_shipment_amount, 0, "Demand without a Shipment must have no active amount")
  assert_equal(unallocated.unplanned_amount, 15, "unallocated observed shortage must remain available for planning")

  local loaded = state.shipments[1]
  local loading = state.shipments[2]
  assert_equal(loaded.demand_id, 3, "legacy transfers must migrate in deterministic request-id order")
  assert_equal(loading.demand_id, 9, "each legacy transfer must create exactly one Shipment")
  assert_equal(loaded.legacy_transfer_id, 3, "migrated Shipment must retain a stable legacy transfer identity")
  assert_equal(loading.legacy_transfer_id, 9, "each migrated Shipment must retain its legacy transfer identity")
  assert_equal(state.next_shipment_id, 3, "Shipment id continuity must advance once per legacy transfer")
  assert_equal(loaded.platform_index, 30, "Shipment must preserve its platform")
  assert_equal(loaded.source, "nauvis", "Shipment must preserve its source")
  assert_equal(loaded.destination, "vulcanus", "Shipment must preserve its destination")
  assert_equal(loaded.item, "iron-plate", "Shipment must preserve its exact item")
  assert_equal(loaded.quality, "legendary", "Shipment must preserve its exact quality")
  assert_equal(loaded.allocated_amount, 25, "Shipment must preserve its allocated amount")
  assert_equal(loaded.baseline_count, 10, "Shipment must preserve baseline cargo")
  assert_equal(loaded.original_schedule_current, 2, "Shipment must preserve the original schedule current")
  assert_equal(loaded.pad_section_index, 12, "Shipment must preserve landing-pad section state")
  assert_equal(loaded.started_tick, 200, "Shipment must preserve its start tick")
  assert_equal(loaded.loaded_full, true, "Shipment must preserve loaded state")
  assert_equal(#loaded.pickup_legs, 1, "legacy transfers must become one-leg Shipments")
  assert_equal(loaded.pickup_legs[1].source, "nauvis", "pickup leg must preserve source")
  assert_equal(loaded.pickup_legs[1].planned_amount, 25, "pickup leg must preserve planned amount")
  assert_equal(loaded.pickup_legs[1].cumulative_target, 35, "pickup leg must preserve cumulative target")
  assert_equal(loaded.pickup_legs[1].hub_section_index, 11, "pickup leg must preserve its hub section")
  assert_equal(loaded.pickup_legs[1].status, "completed", "loaded transfer pickup leg must be completed")
  assert_equal(loading.pickup_legs[1].status, "loading", "unloaded transfer pickup leg must remain loading")
  assert_equal(state.shipments_by_demand[3][1], true, "Shipment must be indexed by Demand")
  assert_equal(state.shipments_by_demand[9][2], true, "every Shipment must be indexed by Demand")
  assert_equal(state.platform_shipments[30], 1, "Shipment must be indexed by platform")
  assert_equal(state.platform_shipments[90], 2, "each platform index must reference its Shipment")
  assert_equal(next(state.active_transfers), nil, "legacy active transfers must be consumed after migration")
  assert_equal(next(state.platform_transfers), nil, "legacy platform transfer indexes must be consumed after migration")

  local shipments = state.shipments
  state = State.ensure()
  assert_equal(state.shipments, shipments, "repeated ensure must not rebuild Shipment persistence")
  assert_equal(state.next_shipment_id, 3, "repeated ensure must not duplicate migrated Shipments")
  assert_equal(state.shipments_by_demand[3][1], true, "repeated ensure must retain Shipment indexes")

  reset_modules()
  State = require("scripts.state")
  state = State.ensure()
  assert_equal(state.shipments, shipments, "save/load module reload must retain migrated Shipment persistence")
  assert_equal(state.next_shipment_id, 3, "save/load module reload must not duplicate migrated Shipments")
end

local function test_state_schema_v3_resumes_interrupted_transfer_migration()
  reset_modules()
  local demand = {
    id = 5,
    key = "chest|50|steel-plate|normal",
    status = "loading",
    amount = 12,
    item = "steel-plate",
    quality = "normal",
    destination = "vulcanus"
  }
  local transfer = {
    request_id = 5,
    force_index = 1,
    platform_index = 50,
    platform_name = "Resilient",
    source = "nauvis",
    destination = "vulcanus",
    item = "steel-plate",
    quality = "normal",
    amount = 12,
    baseline_count = 2,
    target_count = 14,
    original_current = 1,
    hub_section_index = 20,
    pad_unit_number = 500,
    pad_section_index = 21,
    pad_baseline_count = 3,
    started_tick = 400,
    loaded_full = false
  }
  local unrelated = {
    id = 2,
    demand_id = 8,
    platform_index = 80,
    allocated_amount = 6,
    status = "loading"
  }
  local migrated = {
    id = 4,
    legacy_transfer_id = 5,
    demand_id = 5,
    request_id = 5,
    platform_index = 50,
    allocated_amount = 12,
    status = "loading"
  }
  storage = {interplanetary_logistics = {
    schema_version = 2,
    requests = {[5] = demand},
    request_by_key = {[demand.key] = 5},
    next_request_id = 6,
    active_transfers = {[5] = transfer},
    platform_transfers = {[50] = 5},
    shipments = {[2] = unrelated, [4] = migrated},
    shipments_by_demand = {[8] = {[2] = true}, [99] = {[4] = true}},
    platform_shipments = {[80] = 2, [50] = 88, [999] = 4},
    next_shipment_id = 1
  }}

  local State = require("scripts.state")
  local state = State.ensure()
  local shipment_count = 0
  for _ in pairs(state.shipments) do shipment_count = shipment_count + 1 end

  assert_equal(shipment_count, 2, "interrupted migration must reuse the existing legacy Shipment")
  assert_equal(state.shipments[4], migrated, "interrupted migration must preserve the matching Shipment")
  assert_equal(state.shipments[2], unrelated, "interrupted migration must preserve unrelated Shipments")
  assert_equal(state.shipments_by_demand[5][4], true, "resumed migration must repair the Demand index")
  assert_equal(state.shipments_by_demand[99], nil, "resumed migration must remove the reused Shipment's stale Demand index")
  assert_equal(state.platform_shipments[50], 4, "resumed migration must repair the platform index")
  assert_equal(state.platform_shipments[999], nil, "resumed migration must remove the reused Shipment's stale platform index")
  assert_equal(state.shipments_by_demand[8][2], true, "unrelated Demand indexes must remain intact")
  assert_equal(state.platform_shipments[80], 2, "unrelated platform indexes must remain intact")
  assert_equal(state.next_shipment_id, 5, "resumed migration must deterministically recompute the next Shipment id")
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
  state = State.ensure_destinations()
  assert(State.get_chests()[10], "requester chests should remain registered destinations")
  assert(State.get_landing_pads()[20] == nauvis_pad, "Nauvis cargo landing pads should store entity reference")
  assert(State.get_landing_pads()[30] == vulcanus_pad, "other-planet cargo landing pads should store entity reference")
end

local function test_destination_grouping_one_row_per_planet()
  reset_modules()
  storage = {}

  local force = {valid = true, index = 1}
  local function pad(unit_number, planet_name)
    return {
      valid = true, unit_number = unit_number, force = force,
      surface = {valid = true, name = planet_name, planet = {name = planet_name}},
      position = {x = unit_number, y = 0}
    }
  end

  local pads = {
    pad(20, "nauvis"),
    pad(21, "nauvis"),
    pad(30, "vulcanus"),
    pad(40, "fulgora"),
    pad(41, "fulgora"),
    pad(42, "fulgora")
  }

  local Util = require("scripts.util")
  local grouped = Util.group_destinations_by_planet(pads)

  assert_equal(#grouped, 3, "one row per planet should be produced")
  assert_equal(grouped[1].planet, "fulgora", "planets should be sorted alphabetically")
  assert_equal(#grouped[1].pads, 3, "fulgora should group its three pads")
  assert_equal(grouped[1].pads[1].unit_number, 40, "pads should be sorted by unit_number")
  assert_equal(grouped[2].planet, "nauvis", "nauvis should be second alphabetically")
  assert_equal(#grouped[2].pads, 2, "nauvis should group its two pads")
  assert_equal(grouped[3].planet, "vulcanus", "vulcanus should be third alphabetically")
  assert_equal(#grouped[3].pads, 1, "vulcanus should have one pad")
end

local function test_destination_list_works_without_get_by_unit_number()
  reset_modules()
  storage = {}

  local force = {valid = true, index = 1}
  local player = {valid = true, index = 1, force = force}

  local function pad(unit_number, planet_name)
    return {
      valid = true, unit_number = unit_number, force = force,
      surface = {valid = true, name = planet_name, planet = {name = planet_name}},
      position = {x = unit_number, y = 0}
    }
  end

  local nauvis_pad = pad(20, "nauvis")
  local vulcanus_pad = pad(30, "vulcanus")
  local function surface(pads)
    return {
      find_entities_filtered = function(filter)
        if filter.type == "cargo-landing-pad" then return pads end
        return {}
      end
    }
  end

  game = {
    surfaces = {surface({nauvis_pad}), surface({vulcanus_pad})},
    get_entity_by_unit_number = function() return nil end
  }

  local State = require("scripts.state")
  State.ensure_destinations()

  local Util = require("scripts.util")
  local pads = {}
  for _, entity in pairs(State.get_landing_pads()) do
    if entity and entity.valid and entity.force and entity.force.index == player.force.index then
      pads[#pads + 1] = entity
    end
  end
  local grouped = Util.group_destinations_by_planet(pads)

  assert_equal(#grouped, 2, "destination_list should find pads even when get_entity_by_unit_number returns nil")
  assert_equal(grouped[1].planet, "nauvis", "nauvis should be first alphabetically")
  assert_equal(#grouped[1].pads, 1, "nauvis should have one pad")
  assert_equal(grouped[2].planet, "vulcanus", "vulcanus should be second alphabetically")
  assert_equal(#grouped[2].pads, 1, "vulcanus should have one pad")
end

local function make_chest_dirty_env()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
  }}
  defines = {alert_type = {no_material_for_construction = 1}}
  prototypes = {item = {
    ["iron-plate"] = {send_to_orbit_mode = "automated"},
    ["copper-plate"] = {send_to_orbit_mode = "automated"},
  }}
  local network = {valid = true, network_id = 7, get_item_count = function() return 0 end}
  local surface = {valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"}}
  local force = {valid = true, index = 1, players = {}, platforms = {}}
  local entities = {}
  local function chest(unit_number, filters)
    local point = {
      logistic_network = network,
      filters = filters or {{type = "item", name = "iron-plate", quality = "normal", count = 100}},
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
  return State, Demands, state, chest, entities
end

local function test_chest_filter_event_creates_demand_without_scan()
  local State, Demands, state, chest = make_chest_dirty_env()
  local entity = chest(1)
  State.register_chest(1)
  Demands.mark_chest_dirty(1)
  assert(Demands.chest_dirty_active(), "chest dirty queue should be active after mark")
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end
  local demand_id = state.demand_by_key["chest|1|iron-plate|normal"]
  assert(demand_id, "chest filter event should create a demand via the dirty queue")
  local demand = state.demands[demand_id]
  assert_equal(demand.amount, 100, "dirty-queue demand should match the chest filter count")
  assert_equal(demand.origin, "chest", "dirty-queue demand should preserve chest origin")
  assert_equal(state.scan_job, nil, "dirty queue must not start a scan job")
  assert_equal(state.process_job, nil, "dirty queue must not start a process job")
end

local function test_chest_dirty_independent_of_scan_job()
  local State, Demands, state, chest = make_chest_dirty_env()
  local entity = chest(1)
  State.register_chest(1)
  assert(Demands.start_scan(), "scan should start for reconciliation")
  assert(Demands.scan_active(), "scan job should be active")
  Demands.mark_chest_dirty(1)
  assert(Demands.chest_dirty_active(), "chest dirty queue should be active even while scan is active")
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end
  local demand_id = state.demand_by_key["chest|1|iron-plate|normal"]
  assert(demand_id, "chest dirty processing should create a demand while scan is active")
  assert(Demands.scan_active(), "scan job should remain active independently of chest dirty processing")
end

local function test_retire_chest_removes_all_demands()
  local State, Demands, state, chest = make_chest_dirty_env()
  chest(1, {
    {type = "item", name = "iron-plate", quality = "normal", count = 100},
    {type = "item", name = "copper-plate", quality = "normal", count = 50}
  })
  State.register_chest(1)
  Demands.mark_chest_dirty(1)
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end
  assert(state.demand_by_key["chest|1|iron-plate|normal"], "iron demand should exist before retire")
  assert(state.demand_by_key["chest|1|copper-plate|normal"], "copper demand should exist before retire")
  Demands.retire_chest(1)
  assert_equal(state.demand_by_key["chest|1|iron-plate|normal"], nil, "retire should remove iron demand")
  assert_equal(state.demand_by_key["chest|1|copper-plate|normal"], nil, "retire should remove copper demand")
end

local function test_scheduler_processes_chest_dirty_before_scan()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {chest_dirty = true, scan = false, process = false, fleet = true}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8
  }
  local callbacks = {
    chest_dirty_active = function() return state.chest_dirty end,
    step_chest_dirty = function()
      calls.step_chest_dirty = (calls.step_chest_dirty or 0) + 1
      state.chest_dirty = false
      return true
    end,
    scan_active = function() return state.scan end,
    process_active = function() return state.process end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1; state.scan = true end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return false end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1; state.process = true end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1; state.process = false end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return state.fleet end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }
  assert_equal(Scheduler.step(120, 120, constants, callbacks), "chest-dirty", "chest dirty should take priority")
  assert_equal(calls.step_chest_dirty, 1, "chest dirty should advance first")
  assert_equal(calls.start_scan, nil, "scan must not start while chest dirty is active")
  assert_equal(calls.step_scan, nil, "scan must not advance while chest dirty is active")
  assert_equal(calls.step_fleet_refresh, nil, "fleet refresh must yield to chest dirty")
end

local function test_chest_filter_zero_count_retires_demand()
  local State, Demands, state, chest = make_chest_dirty_env()
  local entity, point = chest(1)
  State.register_chest(1)
  Demands.mark_chest_dirty(1)
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end
  assert(state.demand_by_key["chest|1|iron-plate|normal"], "demand should exist before zero-count update")
  point.filters = {{type = "item", name = "iron-plate", quality = "normal", count = 0}}
  Demands.mark_chest_dirty(1)
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end
  local demand_id = state.demand_by_key["chest|1|iron-plate|normal"]
  local demand = demand_id and state.demands[demand_id]
  assert_equal(demand_id, nil, "zero-count filter should retire the demand")
  assert_equal(demand, nil, "no demand object should remain after zero-count retire")
end

local function test_active_chest_demand_refreshes_exact_delivered_count_and_remainder()
  local State, Demands, state, chest = make_chest_dirty_env()
  local entity = chest(1)
  State.register_chest(1)
  Demands.mark_chest_dirty(1)
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end

  local key = "chest|1|iron-plate|normal"
  local demand = state.demands[state.demand_by_key[key]]
  local shipment = State.create_shipment(demand, {index = 99, name = "Test"}, {
    {source = "fulgora", planned_amount = 100, cumulative_target = 100, status = "pending"}
  })
  shipment.status = "loading"
  demand.status = "loading"
  demand.active_shipment_amount = 100
  demand.unplanned_amount = 0

  entity.get_item_count = function() return 30 end
  game.tick = 60
  Demands.mark_chest_dirty(1)
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end

  assert_equal(demand.amount, 70, "active chest Demand must refresh the exact outstanding count")
  assert_equal(demand.observed_shortage, 70, "active chest Demand must retain the fresh observed shortage")
  assert_equal(demand.current, 30, "active chest Demand must detect the already fulfilled count")
  assert_equal(demand.active_shipment_amount, 100, "refresh must retain the real active Shipment amount")
  assert_equal(demand.unplanned_amount, 0, "active cargo must continue covering the refreshed shortage")

  State.cancel_shipment(shipment.id)
  assert_equal(demand.unplanned_amount, 70, "cancelling cargo must expose only the exact remaining shortage")
end

local function test_fully_fulfilled_active_chest_completes_and_cleans_up()
  local State, Demands, state, chest = make_chest_dirty_env()
  local entity = chest(1)
  State.register_chest(1)
  Demands.mark_chest_dirty(1)
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end

  local key = "chest|1|iron-plate|normal"
  local demand = state.demands[state.demand_by_key[key]]
  local shipment = State.create_shipment(demand, {index = 99, name = "Test"}, {
    {source = "fulgora", planned_amount = 100, cumulative_target = 100, status = "pending"}
  })
  shipment.status = "loading"
  demand.status = "loading"

  entity.get_item_count = function() return 100 end
  game.tick = 60
  Demands.mark_chest_dirty(1)
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end

  assert_equal(demand.observed_shortage, 0, "fulfilled Demand must retain the zero-shortage observation")
  assert_equal(demand.current, 100, "fulfilled Demand must retain the already delivered count")
  assert_equal(demand.status, "completed", "destination fulfillment must complete rather than cancel the Demand")
  assert_equal(state.demand_by_key[key], nil, "completed Demand must release its active key")
  assert_equal(shipment.status, "cancelled", "cargo still in flight must be cancelled after local fulfillment")
  assert_equal(state.shipments[shipment.id], nil, "fulfilled Demand must remove the active Shipment")
  assert_equal(state.platform_shipments[99], nil, "fulfilled Demand must release the assigned platform")
end

local function test_chest_dirty_bounded_processing()
  local State, Demands, state, chest = make_chest_dirty_env()
  for unit = 1, 10 do
    chest(unit)
    State.register_chest(unit)
    Demands.mark_chest_dirty(unit)
  end
  assert(Demands.chest_dirty_active(), "queue should be active with 10 dirty chests")
  local finished = Demands.step_chest_dirty(3)
  assert_equal(finished, false, "budget of 3 should not clear 10 dirty chests")
  local created = 0
  for unit = 1, 10 do
    if state.demand_by_key["chest|" .. unit .. "|iron-plate|normal"] then
      created = created + 1
    end
  end
  assert(created <= 3, "bounded step should process at most the budget count of chests, got " .. tostring(created))
  while Demands.chest_dirty_active() do Demands.step_chest_dirty(8) end
  for unit = 1, 10 do
    assert(state.demand_by_key["chest|" .. unit .. "|iron-plate|normal"], "all chests should be processed after draining")
  end
end

test_state_schema_v3_resumes_interrupted_transfer_migration()
test_state_schema_v3_initialization_and_indexes()
test_state_schema_v3_migrates_legacy_requests_and_transfers()
test_construction_network_scan_matches_game_alerts()
test_bounded_scan_skips_invalidated_logistic_cells()
test_bounded_scan_skips_invalidated_logistic_networks()
test_destination_registry_includes_landing_pads()
test_destination_grouping_one_row_per_planet()
test_destination_list_works_without_get_by_unit_number()
test_chest_outstanding_demands()
test_scan_scheduler_is_bounded()
test_scheduler_prioritizes_routing_over_fleet_refresh()
test_platform_commandeering()
test_source_stock_exact_network_snapshots()
test_source_stock_same_tick_cache_and_fresh_bypass()
test_plan_single_source_single_ship()
test_plan_multi_source_single_ship()
test_plan_multi_ship()
test_plan_ephemeral_availability()
test_plan_schedule_ordered_legs()
test_plan_source_not_in_schedule_skipped()
test_plan_no_eligible_ships()
test_plan_no_sources()
test_plan_demand_amounts_updated()
test_plan_platform_already_assigned_skipped()
test_plan_pinned_route_priority()
test_plan_deterministic_ordering()
test_plan_partial_coverage()
test_plan_non_approved_rejected()
test_plan_clears_legacy_source_fields()
test_demand_source_tracking()
test_demand_source_updates_when_first_shipment_cancels()
test_router_rank_sources_still_works()
test_fleet_preferences_eta_and_reservations()
test_chest_filter_event_creates_demand_without_scan()
test_chest_dirty_independent_of_scan_job()
test_retire_chest_removes_all_demands()
test_scheduler_processes_chest_dirty_before_scan()
test_chest_filter_zero_count_retires_demand()
test_active_chest_demand_refreshes_exact_delivered_count_and_remainder()
test_fully_fulfilled_active_chest_completes_and_cleans_up()
test_chest_dirty_bounded_processing()

-- ---------------------------------------------------------------------------
-- Save-load regression: runtime destination registries must be rebuilt before
-- the periodic scan reads them, otherwise loaded saves detect zero chest
-- Demands. on_init/on_configuration_changed do not fire on a normal save load,
-- and game is not accessible in on_load, so control.lua's on_tick calls
-- State.ensure_destinations() once per session to repopulate the chest/landing-
-- pad locals from world entities.
-- ---------------------------------------------------------------------------

local function test_scan_finds_chests_after_destination_rebuild_on_load()
  reset_modules()
  storage = {}
  settings = {global = {["il-auto-approve-seconds"] = {value = 30}}}
  defines = {alert_type = {no_material_for_construction = 1}}
  prototypes = {item = {["iron-plate"] = {send_to_orbit_mode = "automated"}}}

  local network = {valid = true, network_id = 7, get_item_count = function() return 0 end}
  local chest_entity
  local surface = {
    valid = true, index = 1, name = "nauvis", planet = {name = "nauvis"},
    find_entities_filtered = function(filter)
      if filter.name == "interplanetary-requester-chest" then return {chest_entity} end
      return {}
    end
  }
  local force = {valid = true, index = 1, logistic_networks = {[surface.name] = {network}}}
  chest_entity = {
    valid = true, name = "interplanetary-requester-chest", unit_number = 42,
    force = force, surface = surface, position = {x = 0, y = 0},
    get_requester_point = function()
      return {logistic_network = network, filters = {{name = "iron-plate", count = 100, quality = "normal"}}, targeted_items_deliver = {}}
    end,
    get_item_count = function() return 0 end
  }
  game = {
    tick = 0, forces = {force}, surfaces = {surface},
    get_entity_by_unit_number = function() return chest_entity end,
    get_surface = function() return surface end
  }

  -- Simulate a save load: modules are reloaded so the runtime-only `chests`
  -- local starts empty and `destinations_initialized` is false. Do NOT call
  -- State.register_chest (no build event fires on a load).
  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  State.ensure()
  assert_equal(next(State.get_chests()), nil, "runtime chest registry must start empty after a load")

  -- control.lua's on_tick rebuilds destinations from world entities on the
  -- first tick after load. A scan before that rebuild would find nothing.
  assert_equal(next(State.get_chests()), nil, "registry must still be empty before the on_tick rebuild")
  State.ensure_destinations()
  assert(State.get_chests()[42], "ensure_destinations must rebuild the chest registry from world entities after a load")

  -- Now the periodic scan must detect the requester-chest shortage.
  Demands.scan()
  local state = State.ensure()
  local demand = state.demands[state.demand_by_key["chest|42|iron-plate|normal"]]
  assert(demand, "scan must detect the requester-chest shortage after the on-load destination rebuild")
  assert_equal(demand.amount, 100, "rebuilt scan must publish the full observed shortage")

  -- A subsequent scan must update shortage against current chest contents.
  chest_entity.get_item_count = function() return 40 end
  Demands.scan()
  assert_equal(state.demands[state.demand_by_key["chest|42|iron-plate|normal"]].amount, 60, "subsequent scans must update shortage against current chest contents")
end

test_scan_finds_chests_after_destination_rebuild_on_load()

-- ---------------------------------------------------------------------------
-- Event-driven construction tracking tests
-- ---------------------------------------------------------------------------

local function make_construction_env()
  reset_modules()
  storage = {}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
  }}
  defines = {alert_type = {no_material_for_construction = 1}}
  prototypes = {item = {
    spidertron = {send_to_orbit_mode = "automated"},
    biochamber = {send_to_orbit_mode = "automated"},
    ["fusion-reactor-equipment"] = {send_to_orbit_mode = "automated"},
    ["iron-plate"] = {send_to_orbit_mode = "automated"},
    ["rocket-silo"] = {send_to_orbit_mode = "not-sendable"},
    ["captive-biter-spawner"] = {send_to_orbit_mode = "not-sendable"},
    ["cliff-explosives"] = {send_to_orbit_mode = "not-sendable"},
    concrete = {send_to_orbit_mode = "automated"},
    ["steel-chest"] = {send_to_orbit_mode = "automated"},
    ["efficiency-module-3"] = {send_to_orbit_mode = "automated"},
  }}
  local supply = {}
  local network = {
    valid = true,
    network_id = 101,
    cells = {},
    get_item_count = function(item) return supply[item.name .. "|" .. item.quality] or 0 end
  }
  local surface = {
    valid = true,
    index = 1,
    name = "nauvis",
    planet = {name = "nauvis"},
    find_entities_filtered = function() return {} end,
    find_logistic_network_by_position = function() return network end
  }
  local force = {
    valid = true,
    index = 1,
    logistic_networks = {nauvis = {network}}
  }
  local entities = {}
  local next_unit = 1
  local function ghost(name, item, quality)
    local entity = {
      valid = true,
      unit_number = next_unit,
      name = "entity-ghost",
      position = {x = next_unit, y = next_unit},
      quality = quality or "normal",
      force = force,
      surface = surface,
      ghost_prototype = {
        valid = true,
        name = item,
        items_to_place_this = {{name = item, count = 1}}
      },
      is_registered_for_construction = function() return true end
    }
    entities[next_unit] = entity
    next_unit = next_unit + 1
    return entity
  end
  local function proxy(item, count, quality)
    local entity = {
      valid = true,
      unit_number = next_unit,
      name = "item-request-proxy",
      position = {x = next_unit, y = next_unit},
      force = force,
      surface = surface,
      item_requests = {{name = item, count = count, quality = quality or "normal"}},
      is_registered_for_construction = function() return true end
    }
    entities[next_unit] = entity
    next_unit = next_unit + 1
    return entity
  end
  local function tile_ghost(item, quality)
    local entity = {
      valid = true,
      unit_number = next_unit,
      name = "tile-ghost",
      position = {x = next_unit, y = next_unit},
      quality = quality or "normal",
      force = force,
      surface = surface,
      ghost_prototype = {
        valid = true,
        name = item,
        items_to_place_this = {{name = item, count = 1}}
      },
      is_registered_for_construction = function() return true end
    }
    entities[next_unit] = entity
    next_unit = next_unit + 1
    return entity
  end
  game = {
    tick = 0,
    forces = {force},
    surfaces = {[1] = surface},
    get_surface = function() return surface end,
    get_entity_by_unit_number = function(unit_number) return entities[unit_number] end
  }
  local State = require("scripts.state")
  local Demands = require("scripts.demands")
  local state = State.ensure()
  return State, Demands, state, ghost, proxy, tile_ghost, supply, entities
end

local function test_event_driven_tracking_creates_demand()
  local State, Demands, state, ghost = make_construction_env()
  local entity = ghost("spidertron", "spidertron", {name = "legendary"})
  Demands.track_construction(entity)
  assert(Demands.construction_dirty_active(), "construction dirty queue should be active after track")
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  local key = table.concat({"alert", 1, 1, 101, "spidertron", "legendary"}, "|")
  local demand_id = state.demand_by_key[key]
  assert(demand_id, "event-driven tracking should create a construction demand")
  local demand = state.demands[demand_id]
  assert_equal(demand.amount, 1, "event-driven demand should match ghost count")
  assert_equal(demand.item, "spidertron", "demand should preserve item name")
  assert_equal(demand.quality, "legendary", "demand should preserve quality name")
end

local function test_untrack_on_ghost_removal_retires_demand()
  local State, Demands, state, ghost = make_construction_env()
  local entity = ghost("spidertron", "spidertron", {name = "legendary"})
  Demands.track_construction(entity)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  local key = table.concat({"alert", 1, 1, 101, "spidertron", "legendary"}, "|")
  assert(state.demand_by_key[key], "demand should exist before untrack")
  Demands.untrack_construction(entity)
  assert_equal(state.demand_by_key[key], nil, "untrack should retire the construction demand")
end

local function test_ghost_revive_untracks_demand()
  local State, Demands, state, ghost = make_construction_env()
  local entity = ghost("spidertron", "spidertron", {name = "legendary"})
  Demands.track_construction(entity)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  local key = table.concat({"alert", 1, 1, 101, "spidertron", "legendary"}, "|")
  assert(state.demand_by_key[key], "demand should exist before revive")
  -- Revive: the ghost becomes a real entity; untrack it
  Demands.untrack_construction(entity)
  assert_equal(state.demand_by_key[key], nil, "revive should retire the construction demand")
end

local function test_bootstrap_populates_tracked_construction()
  local State, Demands, state, ghost, proxy, tile_ghost = make_construction_env()
  -- Create entities that bootstrap should discover via find_entities_filtered
  local surface = game.surfaces[1]
  local all_entities = {}
  local g1 = ghost("spidertron", "spidertron", {name = "legendary"})
  local g2 = ghost("biochamber", "biochamber", {name = "legendary"})
  local p1 = proxy("fusion-reactor-equipment", 22, "normal")
  local t1 = tile_ghost("concrete", "normal")
  all_entities = {g1, g2, p1, t1}
  surface.find_entities_filtered = function() return all_entities end
  -- Add a cell so the bootstrap can find entities
  local network = surface.find_logistic_network_by_position()
  network.cells = {{
    valid = true,
    construction_radius = 1000,
    owner = {valid = true, unit_number = 1, position = {x = 0, y = 0}}
  }}

  assert(Demands.start_bootstrap(), "bootstrap should start")
  while Demands.bootstrap_active() do Demands.step_bootstrap(16) end
  assert_equal(state.bootstrap_job, nil, "bootstrap should complete and clear its job")
  -- tracked_construction should be populated
  local tracked_count = 0
  for _ in pairs(state.tracked_construction) do tracked_count = tracked_count + 1 end
  assert_equal(tracked_count, 4, "bootstrap should track all 4 construction entities")
  -- Process dirty queue to create demands
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(16) end
  local spidertron_key = table.concat({"alert", 1, 1, 101, "spidertron", "legendary"}, "|")
  assert(state.demand_by_key[spidertron_key], "bootstrap should create spidertron demand after dirty processing")
  local fusion_key = table.concat({"alert", 1, 1, 101, "fusion-reactor-equipment", "normal"}, "|")
  assert(state.demand_by_key[fusion_key], "bootstrap should create fusion-reactor demand after dirty processing")
  local fusion_demand = state.demands[state.demand_by_key[fusion_key]]
  assert_equal(fusion_demand.amount, 22, "bootstrap demand should preserve proxy count")
end

local function test_bootstrap_is_one_time()
  local State, Demands, state, ghost = make_construction_env()
  local entity = ghost("spidertron", "spidertron", "normal")
  local surface = game.surfaces[1]
  surface.find_entities_filtered = function() return {entity} end
  local network = surface.find_logistic_network_by_position()
  network.cells = {{
    valid = true,
    construction_radius = 1000,
    owner = {valid = true, unit_number = 1, position = {x = 0, y = 0}}
  }}

  assert(Demands.start_bootstrap(), "bootstrap should start")
  while Demands.bootstrap_active() do Demands.step_bootstrap(16) end
  assert_equal(state.bootstrap_job, nil, "bootstrap should complete")
  -- Starting again should fail (already completed)
  assert_equal(Demands.start_bootstrap(), false, "bootstrap should not restart after completion")
  assert_equal(Demands.bootstrap_active(), false, "bootstrap should not be active after completion")
end

local function test_construction_dirty_independent_of_scan_job()
  local State, Demands, state, ghost = make_construction_env()
  local entity = ghost("spidertron", "spidertron", "normal")
  -- Start a scan job
  assert(Demands.start_scan(), "scan should start for reconciliation")
  assert(Demands.scan_active(), "scan job should be active")
  -- Track a construction entity while scan is active
  Demands.track_construction(entity)
  assert(Demands.construction_dirty_active(), "construction dirty should be active while scan is active")
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  local key = table.concat({"alert", 1, 1, 101, "spidertron", "normal"}, "|")
  assert(state.demand_by_key[key], "construction dirty should create demand while scan is active")
  assert(Demands.scan_active(), "scan job should remain active independently of construction dirty")
end

local function test_bounded_bootstrap_processing()
  local State, Demands, state, ghost, proxy = make_construction_env()
  -- Create many entities for bootstrap to discover
  local surface = game.surfaces[1]
  local all_entities = {}
  for i = 1, 20 do
    all_entities[#all_entities + 1] = proxy("iron-plate", 1, "normal")
  end
  surface.find_entities_filtered = function() return all_entities end
  local network = surface.find_logistic_network_by_position()
  network.cells = {{
    valid = true,
    construction_radius = 1000,
    owner = {valid = true, unit_number = 1, position = {x = 0, y = 0}}
  }}

  assert(Demands.start_bootstrap(), "bootstrap should start")
  -- Step with a small budget - should not complete
  local finished = Demands.step_bootstrap(2)
  assert_equal(finished, false, "bootstrap with budget 2 should not complete all 20 entities")
  assert(Demands.bootstrap_active(), "bootstrap should still be active after partial step")
  -- Drain the rest
  while Demands.bootstrap_active() do Demands.step_bootstrap(16) end
  assert_equal(state.bootstrap_job, nil, "bootstrap should complete after draining")
end

local function test_bounded_construction_dirty_processing()
  local State, Demands, state, ghost = make_construction_env()
  -- Track many entities
  for i = 1, 20 do
    local entity = ghost("iron-plate", "iron-plate", "normal")
    Demands.track_construction(entity)
  end
  assert(Demands.construction_dirty_active(), "construction dirty should be active with 20 entities")
  -- Step with small budget - should not complete
  local finished = Demands.step_construction_dirty(3)
  assert_equal(finished, false, "construction dirty with budget 3 should not clear 20 entries")
  -- Drain the rest
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(16) end
  local key = table.concat({"alert", 1, 1, 101, "iron-plate", "normal"}, "|")
  assert(state.demand_by_key[key], "construction dirty should create demand after draining")
  local demand = state.demands[state.demand_by_key[key]]
  assert_equal(demand.amount, 20, "all 20 ghosts should aggregate into one demand")
end

local function test_roboport_topology_reassociation()
  local State, Demands, state, ghost = make_construction_env()
  local entity = ghost("spidertron", "spidertron", "normal")
  Demands.track_construction(entity)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  local key = table.concat({"alert", 1, 1, 101, "spidertron", "normal"}, "|")
  assert(state.demand_by_key[key], "demand should exist before reassociation")
  -- Reassociate (simulates roboport topology change)
  Demands.reassociate_construction(1, 1)
  assert(Demands.construction_dirty_active(), "reassociation should mark tracked entities dirty")
  -- Process dirty - demand should be re-created
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  assert(state.demand_by_key[key], "demand should still exist after reassociation")
end

local function test_event_driven_exact_quality_and_count()
  local State, Demands, state, ghost, proxy, tile_ghost = make_construction_env()
  -- Test exact quality preservation through event-driven path
  local g1 = ghost("spidertron", "spidertron", {name = "legendary"})
  local g2 = ghost("spidertron", "spidertron", {name = "legendary"})
  local g3 = ghost("spidertron", "spidertron", "normal")
  local p1 = proxy("fusion-reactor-equipment", 22, "normal")
  local p2 = proxy("fusion-reactor-equipment", 1, "normal")
  local t1 = tile_ghost("concrete", "normal")
  local t2 = tile_ghost("concrete", "normal")

  Demands.track_construction(g1)
  Demands.track_construction(g2)
  Demands.track_construction(g3)
  Demands.track_construction(p1)
  Demands.track_construction(p2)
  Demands.track_construction(t1)
  Demands.track_construction(t2)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(16) end

  local legendary_key = table.concat({"alert", 1, 1, 101, "spidertron", "legendary"}, "|")
  local normal_spidertron_key = table.concat({"alert", 1, 1, 101, "spidertron", "normal"}, "|")
  local fusion_key = table.concat({"alert", 1, 1, 101, "fusion-reactor-equipment", "normal"}, "|")
  local concrete_key = table.concat({"alert", 1, 1, 101, "concrete", "normal"}, "|")

  assert_equal(state.demands[state.demand_by_key[legendary_key]].amount, 2, "legendary spidertrons should aggregate exactly")
  assert_equal(state.demands[state.demand_by_key[normal_spidertron_key]].amount, 1, "normal spidertron should not collapse to legendary")
  assert_equal(state.demands[state.demand_by_key[fusion_key]].amount, 23, "proxy counts should aggregate exactly")
  assert_equal(state.demands[state.demand_by_key[concrete_key]].amount, 2, "tile ghost counts should aggregate exactly")
end

local function test_event_driven_network_inventory_subtraction()
  local State, Demands, state, ghost, _, _, supply = make_construction_env()
  local entity = ghost("spidertron", "spidertron", "normal")
  Demands.track_construction(entity)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  local key = table.concat({"alert", 1, 1, 101, "spidertron", "normal"}, "|")
  assert_equal(state.demands[state.demand_by_key[key]].amount, 1, "demand should be 1 with no supply")

  -- Add supply and re-process
  supply["spidertron|normal"] = 1
  Demands.reassociate_construction(1, 1)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  -- With supply equal to demand, shortage should be 0 and demand should not exist
  assert_equal(state.demand_by_key[key], nil, "network inventory subtraction should retire demand when supply covers shortage")
end

local function test_active_construction_demand_refreshes_exact_network_remainder()
  local State, Demands, state, ghost, _, _, supply = make_construction_env()
  Demands.track_construction(ghost("spidertron", "spidertron", "normal"))
  Demands.track_construction(ghost("spidertron", "spidertron", "normal"))
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end

  local key = "alert|1|1|101|spidertron|normal"
  local demand = state.demands[state.demand_by_key[key]]
  local shipment = State.create_shipment(demand, {index = 99, name = "Test"}, {
    {source = "fulgora", planned_amount = 2, cumulative_target = 2, status = "pending"}
  })
  shipment.status = "delivering"
  demand.status = "delivering"
  demand.active_shipment_amount = 2
  demand.unplanned_amount = 0

  supply["spidertron|normal"] = 1
  game.tick = 60
  Demands.reassociate_construction(1, 1)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end

  assert_equal(demand.amount, 1, "active construction Demand must refresh the exact outstanding count")
  assert_equal(demand.observed_shortage, 1, "construction observation must retain the exact shortage")
  assert_equal(demand.requested, 2, "construction observation must retain the full registered count")
  assert_equal(demand.current, 1, "construction observation must detect already available inventory")
  assert_equal(demand.unplanned_amount, 0, "active cargo must continue covering the refreshed construction shortage")

  State.cancel_shipment(shipment.id)
  assert_equal(demand.unplanned_amount, 1, "cancelled cargo must expose only the exact construction remainder")
end

local function test_unregistered_ghosts_ignored()
  local State, Demands, state, ghost = make_construction_env()
  -- Create a ghost that is NOT registered for construction
  local entity = ghost("spidertron", "spidertron", "normal")
  entity.is_registered_for_construction = function() return false end
  Demands.track_construction(entity)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(8) end
  local key = table.concat({"alert", 1, 1, 101, "spidertron", "normal"}, "|")
  assert_equal(state.demand_by_key[key], nil, "unregistered ghosts should not create demands")
  -- The entity should be removed from tracked_construction during dirty processing
  local tracked_count = 0
  for _ in pairs(state.tracked_construction) do tracked_count = tracked_count + 1 end
  assert_equal(tracked_count, 0, "unregistered ghost should be removed from tracked_construction")
end

local function test_scheduler_priority_bootstrap_first()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {bootstrap = true, chest_dirty = true, construction_dirty = true, scan = true, process = true, fleet = true}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8,
    construction_dirty_work_per_tick = 8,
    bootstrap_work_per_tick = 16
  }
  local callbacks = {
    bootstrap_active = function() return state.bootstrap end,
    step_bootstrap = function() calls.step_bootstrap = (calls.step_bootstrap or 0) + 1; state.bootstrap = false; return true end,
    chest_dirty_active = function() return state.chest_dirty end,
    step_chest_dirty = function() calls.step_chest_dirty = (calls.step_chest_dirty or 0) + 1; state.chest_dirty = false; return true end,
    construction_dirty_active = function() return state.construction_dirty end,
    step_construction_dirty = function() calls.step_construction_dirty = (calls.step_construction_dirty or 0) + 1; state.construction_dirty = false; return true end,
    scan_active = function() return state.scan end,
    process_active = function() return state.process end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1; state.scan = true end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return false end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1; state.process = true end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1; state.process = false end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return state.fleet end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }
  assert_equal(Scheduler.step(120, 120, constants, callbacks), "bootstrap", "bootstrap should take priority over everything")
  assert_equal(calls.step_bootstrap, 1, "bootstrap should advance first")
  assert_equal(calls.step_chest_dirty, nil, "chest dirty must not advance while bootstrap is active")
  assert_equal(calls.step_construction_dirty, nil, "construction dirty must not advance while bootstrap is active")
  assert_equal(calls.step_scan, nil, "scan must not advance while bootstrap is active")
end

local function test_scheduler_priority_construction_dirty_before_scan()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {chest_dirty = false, construction_dirty = true, scan = true, process = true, fleet = true}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8,
    construction_dirty_work_per_tick = 8,
    bootstrap_work_per_tick = 16
  }
  local callbacks = {
    bootstrap_active = function() return false end,
    step_bootstrap = function() return true end,
    chest_dirty_active = function() return state.chest_dirty end,
    step_chest_dirty = function() calls.step_chest_dirty = (calls.step_chest_dirty or 0) + 1; state.chest_dirty = false; return true end,
    construction_dirty_active = function() return state.construction_dirty end,
    step_construction_dirty = function() calls.step_construction_dirty = (calls.step_construction_dirty or 0) + 1; state.construction_dirty = false; return true end,
    scan_active = function() return state.scan end,
    process_active = function() return state.process end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1; state.scan = true end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return false end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1; state.process = true end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1; state.process = false end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return state.fleet end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }
  assert_equal(Scheduler.step(120, 120, constants, callbacks), "construction-dirty", "construction dirty should take priority over scan")
  assert_equal(calls.step_construction_dirty, 1, "construction dirty should advance before scan")
  assert_equal(calls.step_scan, nil, "scan must not advance while construction dirty is active")
end

test_event_driven_tracking_creates_demand()
test_untrack_on_ghost_removal_retires_demand()
test_ghost_revive_untracks_demand()
test_bootstrap_populates_tracked_construction()
test_bootstrap_is_one_time()
test_construction_dirty_independent_of_scan_job()
test_bounded_bootstrap_processing()
test_bounded_construction_dirty_processing()
test_roboport_topology_reassociation()
test_event_driven_exact_quality_and_count()
test_event_driven_network_inventory_subtraction()
test_active_construction_demand_refreshes_exact_network_remainder()
test_unregistered_ghosts_ignored()
test_scheduler_priority_bootstrap_first()
test_scheduler_priority_construction_dirty_before_scan()

-- ---------------------------------------------------------------------------
-- Shipment execution tests (Task 6)
-- ---------------------------------------------------------------------------

local function make_shipment_env()
  reset_modules()
  storage = {}
  defines = {inventory = {hub_main = 1}}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
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
  local pad_count = 20
  local hub = {
    valid = true,
    get_inventory = function(inv_index)
      assert_equal(inv_index, defines.inventory.hub_main, "platform hub must use hub_main inventory")
      return inventory
    end,
    get_logistic_sections = function() return hub_sections end
  }
  local pad = {
    valid = true,
    unit_number = 50,
    position = {x = 10, y = 20},
    get_item_count = function() return pad_count end,
    get_logistic_sections = function() return pad_sections end
  }
  local destination_network = {valid = true, network_id = 7}
  local destination_surface = {
    valid = true,
    index = 1,
    name = "nauvis",
    planet = {name = "nauvis"},
    find_entities_filtered = function() return {pad} end,
    find_logistic_network_by_position = function() return destination_network end
  }
  local source_surface = {
    valid = true,
    index = 2,
    name = "fulgora",
    planet = {name = "fulgora"},
    find_entities_filtered = function() return {} end
  }
  local vulcanus_surface = {
    valid = true,
    index = 3,
    name = "vulcanus",
    planet = {name = "vulcanus"},
    find_entities_filtered = function() return {} end
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
        {station = "fulgora", wait_conditions = {{type = "time", ticks = 60}}},
        {station = "vulcanus", wait_conditions = {{type = "time", ticks = 60}}}
      }
    }
  }
  local platform2 = {
    valid = true,
    index = 5,
    name = "Runner",
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
    platforms = {platform, platform2},
    logistic_networks = {
      fulgora = {{valid = true, network_id = 8, get_item_count = function() return 50 end}},
      vulcanus = {{valid = true, network_id = 9, get_item_count = function() return 30 end}}
    }
  }
  game = {
    tick = 100,
    forces = {[1] = force},
    surfaces = {[1] = destination_surface, [2] = source_surface, [3] = vulcanus_surface},
    get_surface = function(idx)
      return ({[1] = destination_surface, [2] = source_surface, [3] = vulcanus_surface})[idx]
    end,
    get_entity_by_unit_number = function(unit_number) return unit_number == 50 and pad or nil end
  }

  local State = require("scripts.state")
  local Router = require("scripts.router")
  local Platforms = require("scripts.platforms")
  local state = State.ensure()
  state.enrolled[1] = {[4] = true, [5] = true}

  local function make_demand(id, amount, item)
    local d = {id = id, key = "test-" .. id, status = "approved", force_index = 1,
      destination_surface_index = 1, logistic_network_id = 7,
      destination = "nauvis", item = item or "iron-plate", quality = "normal",
      amount = amount, observed_shortage = amount, origin = "chest"}
    state.demands[id] = d
    state.demand_by_key[d.key] = id
    return d
  end

  return {
    State = State, Router = Router, Platforms = Platforms, state = state, force = force,
    platform = platform, platform2 = platform2, hub = hub, pad = pad, hub_sections = hub_sections,
    pad_sections = pad_sections, inventory = inventory, make_demand = make_demand,
    set_cargo = function(v) cargo_count = v end,
    set_pad_cargo = function(v) pad_count = v end,
    Constants = require("scripts.constants")
  }
end

local function test_execute_shipment_writes_hub_sections_for_each_leg()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  assert(shipment, "planning should create a shipment")
  assert_equal(shipment.status, "planned", "shipment should be planned before execution")
  assert_equal(#shipment.pickup_legs, 2, "two sources should produce two pickup legs")
  local ok = env.Platforms.execute_shipment(shipment, env.force)
  assert(ok, "execute_shipment should succeed")
  assert_equal(shipment.status, "loading", "shipment should be loading after execution")
  assert_equal(#env.hub_sections.sections, 2, "each pickup leg should write a hub request section")
  assert_equal(shipment.pickup_legs[1].hub_section_index, 1, "first leg should store its hub section index")
  assert_equal(shipment.pickup_legs[2].hub_section_index, 2, "second leg should store its hub section index")
  assert_equal(shipment.pickup_legs[1].status, "loading", "first leg should be loading")
  assert_equal(shipment.pickup_legs[2].status, "loading", "second leg should be loading")
end

local function test_execute_shipment_writes_one_pad_section_per_demand()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(#env.pad_sections.sections, 1, "one demand-owned pad section should be created")
  local pad_record = env.state.pad_sections[demand.id]
  assert(pad_record, "pad section record should be stored in state")
  assert_equal(pad_record.pad_unit_number, 50, "pad record should store the pad unit number")
  assert_equal(pad_record.pad_section_index, 1, "pad record should store the section index")
end

local function test_execute_shipment_appends_temporary_schedule_records()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  local original_count = #env.platform.schedule.records
  env.Platforms.execute_shipment(shipment, env.force)
  -- 2 source records + 1 destination record = 3 temporary records appended
  assert_equal(#env.platform.schedule.records, original_count + 3, "execute should append source + destination temporary records")
  local records = env.platform.schedule.records
  -- Source records should have allows_unloading=false
  assert_equal(records[original_count + 1].temporary, true, "source record should be temporary")
  assert_equal(records[original_count + 1].allows_unloading, false, "source record should not allow unloading")
  assert_equal(records[original_count + 2].temporary, true, "second source record should be temporary")
  assert_equal(records[original_count + 2].allows_unloading, false, "second source record should not allow unloading")
  -- Destination record should have allows_unloading=true
  assert_equal(records[original_count + 3].temporary, true, "destination record should be temporary")
  assert_equal(records[original_count + 3].allows_unloading, true, "destination record should allow unloading")
end

local function test_execute_shipment_never_mutates_permanent_records()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  local original_records = {}
  for i, r in ipairs(env.platform.schedule.records) do
    original_records[i] = {station = r.station, temporary = r.temporary, allows_unloading = r.allows_unloading}
  end
  local original_current = env.platform.schedule.current
  env.Platforms.execute_shipment(shipment, env.force)
  -- The first N records should be unchanged
  for i = 1, #original_records do
    assert_equal(env.platform.schedule.records[i].station, original_records[i].station, "permanent record station must not change at " .. i)
    assert_equal(env.platform.schedule.records[i].temporary, original_records[i].temporary, "permanent record temporary flag must not change at " .. i)
  end
  assert_equal(shipment.original_current, original_current, "shipment should store the original schedule current")
  assert_equal(shipment.original_schedule_current, original_current, "shipment should store original_schedule_current")
end

local function test_execute_shipment_sets_status_to_loading()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(shipment.status, "loading", "shipment status should be loading after execution")
  assert_equal(demand.status, "loading", "demand status should be loading after execution")
end

local function test_execute_shipment_stores_baseline_and_indices()
  local env = make_shipment_env()
  env.set_cargo(10)
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(shipment.baseline_count, 10, "shipment should store hub baseline count")
  assert_equal(shipment.pad_unit_number, 50, "shipment should store pad unit number")
  assert_equal(shipment.pad_section_index, 1, "shipment should store pad section index")
  assert_equal(shipment.started_tick, 100, "shipment should update started_tick to game.tick")
end

local function test_execute_shipment_fails_on_invalid_platform()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.platform.valid = false
  local ok, reason = env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(ok, false, "execute_shipment should fail on invalid platform")
  assert(reason, "failure should provide a reason")
  env.platform.valid = true
end

local function test_execute_pending_shipments_executes_all_planned()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  assert_equal(shipment.status, "planned", "shipment should be planned before execute_pending")
  env.Platforms.execute_pending_shipments(env.force)
  assert_equal(shipment.status, "loading", "execute_pending should execute all planned shipments")
end

local function test_cancel_shipment_removes_sections_and_restores_schedule()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  local temp_count = #shipment.pickup_legs + 1
  local original_record_count = #env.platform.schedule.records - temp_count
  env.Platforms.cancel_shipment(shipment.id, "test cancel")
  assert_equal(#env.platform.schedule.records, original_record_count, "cancel should remove temporary records")
  assert_equal(env.platform.schedule.current, shipment.original_current, "cancel should restore original schedule position")
  assert_equal(#env.hub_sections.sections, 0, "cancel should remove hub request sections")
end

local function test_cancel_cleans_factorio_normalized_temporary_schedule_records()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)

  local normalized = {}
  for _, record in ipairs(env.platform.schedule.records) do
    normalized[#normalized + 1] = {
      station = record.station,
      temporary = record.temporary,
      allows_unloading = record.allows_unloading,
      wait_conditions = record.wait_conditions
    }
  end
  env.platform.schedule = {current = env.platform.schedule.current, records = normalized}

  env.Platforms.cancel_shipment(shipment.id, "test cancel")
  assert_equal(#env.platform.schedule.records, 3,
    "cancel must remove Shipment records after Factorio strips unsupported fields")
  assert_equal(env.platform.schedule.current, 2, "cancel must restore the permanent schedule position")
  assert_equal(env.platform.schedule.records[1].station, "nauvis", "cleanup must preserve permanent records")
  assert_equal(env.platform.schedule.records[2].station, "fulgora", "cleanup must preserve permanent records")
  assert_equal(env.platform.schedule.records[3].station, "vulcanus", "cleanup must preserve permanent records")
end

local function test_missing_destination_schedule_record_fails_for_replanning()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)

  env.platform.schedule = {
    current = 2,
    records = {
      {station = "nauvis", wait_conditions = {{type = "time", ticks = 60}}},
      {station = "fulgora", wait_conditions = {{type = "time", ticks = 60}}},
      {station = "vulcanus", wait_conditions = {{type = "time", ticks = 60}}}
    }
  }
  env.Platforms.maintain_shipment(shipment.id)

  assert_equal(shipment.status, "failed", "lost destination schedule record must fail the Shipment")
  assert_equal(demand.status, "approved", "lost shipment route must return the Demand to routing")
  assert_equal(demand.unplanned_amount, 50, "lost shipment route must release its exact allocation")
  assert_equal(env.state.platform_shipments[shipment.platform_index], nil,
    "lost shipment route must release the platform")
end

local function test_cancel_shipment_preserves_onboard_cargo()
  local env = make_shipment_env()
  env.set_cargo(10)
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Simulate cargo loaded
  env.set_cargo(30)
  env.Platforms.cancel_shipment(shipment.id, "test cancel")
  -- Cargo should still be 30, not reset
  assert_equal(env.inventory.get_item_count(), 30, "cancel should preserve onboard cargo")
end

local function test_cancel_shipment_removes_pad_section_when_last_shipment()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(#env.pad_sections.sections, 1, "pad section should exist before cancel")
  env.Platforms.cancel_shipment(shipment.id, "test cancel")
  assert_equal(#env.pad_sections.sections, 0, "cancel should remove pad section when last shipment cancelled")
  assert_equal(env.state.pad_sections[demand.id], nil, "pad section record should be cleared")
end

local function test_finish_shipment_completed_removes_sections_and_updates_metrics()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  local temp_count = #shipment.pickup_legs + 1
  local original_record_count = #env.platform.schedule.records - temp_count
  env.Platforms.finish_shipment(shipment.id, "completed", "cargo delivered")
  assert_equal(shipment.status, "completed", "shipment should be completed")
  assert_equal(#env.hub_sections.sections, 0, "finish should remove hub request sections")
  assert_equal(#env.platform.schedule.records, original_record_count, "finish should remove temporary records")
  local metrics = env.state.source_metrics[shipment.pickup_legs[1].source]
  assert(metrics, "source metrics should be updated on completion")
  assert_equal(metrics.successes, 1, "completed shipment should increment source successes")
  assert_equal(env.state.platform_shipments[shipment.platform_index], nil,
    "finish should release the platform from platform_shipments")
end

local function test_finish_shipment_failed_returns_amount_to_demand()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  local active_before = demand.active_shipment_amount
  assert_equal(active_before, 50, "demand should have active shipment amount before failure")
  env.Platforms.finish_shipment(shipment.id, "failed", "platform lost")
  assert_equal(shipment.status, "failed", "shipment should be failed")
  assert_equal(demand.active_shipment_amount, 0, "failed shipment should release active amount")
  assert(demand.unplanned_amount > 0, "failed shipment should return amount to demand for replanning")
end

local function test_pad_section_reuse_across_multiple_shipments()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 150)
  -- Manually create two shipments for the same demand
  local s1 = env.State.create_shipment(demand, env.platform, {
    {source = "fulgora", planned_amount = 50, cumulative_target = 50, status = "pending"}
  })
  local s2 = env.State.create_shipment(demand, env.platform2, {
    {source = "fulgora", planned_amount = 100, cumulative_target = 100, status = "pending"}
  })
  assert(s1 and s2, "two shipments should be created")
  env.Platforms.execute_shipment(s1, env.force)
  local pad_section_count_after_s1 = #env.pad_sections.sections
  assert_equal(pad_section_count_after_s1, 1, "first shipment should create one pad section")
  env.Platforms.execute_shipment(s2, env.force)
  assert_equal(#env.pad_sections.sections, 1, "second shipment should reuse the existing pad section")
  assert_equal(s2.pad_section_index, s1.pad_section_index, "both shipments should reference the same pad section")
end

local function test_local_fulfillment_cancels_shipments_and_cleans_up()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Simulate local logistics fulfilling the demand
  demand.observed_shortage = 0
  env.Platforms.check_local_fulfillment(demand)
  assert_equal(#env.pad_sections.sections, 0, "local fulfillment should remove pad section")
  assert_equal(shipment.status, "cancelled", "local fulfillment should cancel child shipments")
  assert_equal(demand.status, "completed", "local fulfillment should complete the demand")
end

local function test_temporary_schedule_records_use_correct_wait_conditions()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  local records = env.platform.schedule.records
  local original_count = #records - 3
  -- First source record: item_count >= cumulative_target, time timeout
  local source1 = records[original_count + 1]
  assert_equal(source1.wait_conditions[1].type, "item_count", "source record should use item_count condition")
  assert_equal(source1.wait_conditions[1].condition.comparator, ">=", "source condition should use >=")
  assert_equal(source1.wait_conditions[1].condition.constant, 60, "first source cumulative target should be baseline + 50")
  local has_time = false
  for i = 2, #source1.wait_conditions do
    if source1.wait_conditions[i].type == "time" then has_time = true end
  end
  assert(has_time, "source record should include a time timeout condition")
  -- Destination record: item_count <= baseline
  local dest = records[original_count + 3]
  assert_equal(dest.wait_conditions[1].type, "item_count", "destination record should use item_count condition")
  assert_equal(dest.wait_conditions[1].condition.comparator, "<=", "destination condition should use <=")
  assert_equal(dest.wait_conditions[1].condition.constant, 10, "destination condition should use hub baseline")
end

test_execute_shipment_writes_hub_sections_for_each_leg()
test_execute_shipment_writes_one_pad_section_per_demand()
test_execute_shipment_appends_temporary_schedule_records()
test_execute_shipment_never_mutates_permanent_records()
test_execute_shipment_sets_status_to_loading()
test_execute_shipment_stores_baseline_and_indices()
test_execute_shipment_fails_on_invalid_platform()
test_execute_pending_shipments_executes_all_planned()
test_cancel_shipment_removes_sections_and_restores_schedule()
test_cancel_cleans_factorio_normalized_temporary_schedule_records()
test_missing_destination_schedule_record_fails_for_replanning()
test_cancel_shipment_preserves_onboard_cargo()
test_cancel_shipment_removes_pad_section_when_last_shipment()
test_finish_shipment_completed_removes_sections_and_updates_metrics()
test_finish_shipment_failed_returns_amount_to_demand()
test_pad_section_reuse_across_multiple_shipments()
test_local_fulfillment_cancels_shipments_and_cleans_up()
test_temporary_schedule_records_use_correct_wait_conditions()

-- ---------------------------------------------------------------------------
-- Bounded shipment execution and maintenance tests (Task 7)
-- ---------------------------------------------------------------------------

local function test_bounded_shipment_execution_budget()
  local env = make_shipment_env()
  -- Create multiple planned shipments
  local demand1 = env.make_demand(1, 50)
  local demand2 = env.make_demand(2, 50)
  local demand3 = env.make_demand(3, 50)
  -- Manually create shipments for each demand using different platforms
  local s1 = env.State.create_shipment(demand1, env.platform, {
    {source = "fulgora", planned_amount = 50, cumulative_target = 50, status = "pending"}
  })
  local s2 = env.State.create_shipment(demand2, env.platform2, {
    {source = "fulgora", planned_amount = 50, cumulative_target = 50, status = "pending"}
  })
  -- Reuse platform for s3 by clearing platform_shipments
  env.state.platform_shipments[4] = nil
  local s3 = env.State.create_shipment(demand3, env.platform, {
    {source = "fulgora", planned_amount = 50, cumulative_target = 50, status = "pending"
  }})
  assert_equal(s1.status, "planned", "s1 should be planned")
  assert_equal(s2.status, "planned", "s2 should be planned")
  assert_equal(s3.status, "planned", "s3 should be planned")
  -- Start execution job
  assert(env.Platforms.start_shipment_execution(), "should start execution job")
  assert(env.Platforms.shipment_execution_active(), "execution job should be active")
  -- Step with budget 2 â€” should not complete all 3
  local finished = env.Platforms.step_shipment_execution(2)
  assert_equal(finished, false, "budget 2 should not complete 3 planned shipments")
  local loading_count = 0
  for _, sid in ipairs({s1.id, s2.id, s3.id}) do
    if env.state.shipments[sid].status == "loading" then loading_count = loading_count + 1 end
  end
  assert_equal(loading_count, 2, "exactly 2 shipments should be executed with budget 2")
  -- Drain the rest
  while env.Platforms.shipment_execution_active() do
    env.Platforms.step_shipment_execution(env.Constants.shipment_execution_work_per_tick)
  end
  assert_equal(env.state.shipment_execution_job, nil, "execution job should clear after completion")
end

local function test_shipment_maintenance_detects_loaded_cargo()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(shipment.status, "loading", "shipment should be loading")
  -- Simulate cargo loaded (baseline 10 + 50 = 60)
  env.set_cargo(60)
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "delivering", "loaded cargo should transition to delivering")
  assert_equal(demand.status, "delivering", "demand should be delivering")
end

local function test_shipment_maintenance_detects_delivered_cargo()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Simulate cargo loaded
  env.set_cargo(60)
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "delivering", "should be delivering after load")
  -- Simulate platform at destination with cargo unloaded (back to baseline 10)
  env.set_cargo(10)
  env.set_pad_cargo(70)
  env.platform.space_location = {name = "nauvis"}
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "completed", "delivered cargo should complete shipment")
end

local function test_shipment_waits_for_destination_confirmed_cargo()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)

  env.set_cargo(60)
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "delivering", "loaded cargo should enter delivery")

  env.platform.space_location = {name = "nauvis"}
  env.set_cargo(10)
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "delivering",
    "hub inventory decrease alone must not prove destination receipt")

  env.set_pad_cargo(70)
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "completed", "exact landing-pad receipt should complete the Shipment")
  assert_equal(shipment.delivered_amount, 50, "Shipment must retain the exact destination-confirmed count")
end

local function test_shipment_without_destination_receipt_fails_for_replanning()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)

  env.platform.space_location = {name = "nauvis"}
  env.set_cargo(10)
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "delivering", "arrival must enter a bounded destination-confirmation state")

  game.tick = shipment.destination_arrival_tick + env.Constants.delivery_confirmation_timeout + 1
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "failed", "unconfirmed destination receipt must fail after the bounded timeout")
  assert_equal(demand.status, "approved", "failed unconfirmed delivery must return the Demand to routing")
  assert_equal(demand.unplanned_amount, 50, "all undelivered cargo must become replannable")
end

local function test_shipment_maintenance_detects_timeout()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Simulate timeout by advancing the tick far beyond transfer_timeout
  local timeout = 60 * 60 * 30
  game.tick = shipment.started_tick + timeout + 1
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "failed", "timed out shipment should fail")
end

local function test_shipment_maintenance_detects_invalid_platform()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Invalidate the platform
  env.platform.valid = false
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "failed", "invalid platform should fail shipment")
  env.platform.valid = true
end

local function test_shipment_maintenance_detects_invalid_destination_pad()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)

  env.pad.valid = false
  env.Platforms.maintain_shipment(shipment.id)

  assert_equal(shipment.status, "failed", "removed destination pad must fail only its Shipment")
  assert_equal(demand.status, "approved", "removed destination pad must return the Demand to routing")
  assert_equal(demand.unplanned_amount, 50, "removed pad must release the exact Shipment allocation")
  assert_equal(env.state.platform_shipments[shipment.platform_index], nil,
    "removed destination pad must release the assigned platform")
end

local function test_shipment_maintenance_backfills_missing_baseline_count()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  shipment.baseline_count = nil
  shipment.target_count = nil

  env.Platforms.maintain_shipment(shipment.id)

  assert_equal(shipment.baseline_count, 10,
    "maintenance must recover a missing baseline from current hub cargo")
  assert_equal(shipment.status, "loading",
    "a recovered baseline must leave an unloaded Shipment in loading")
end

local function test_shipment_dirty_queue_processes_marked_shipments()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Mark dirty
  env.Platforms.mark_shipment_dirty(shipment.id)
  assert(env.Platforms.shipment_dirty_active(), "dirty queue should be active after mark")
  -- Simulate cargo loaded
  env.set_cargo(60)
  -- Process dirty queue
  while env.Platforms.shipment_dirty_active() do
    env.Platforms.step_shipment_dirty(8)
  end
  assert_equal(shipment.status, "delivering", "dirty queue should process shipment to delivering")
end

local function test_shipment_dirty_queue_is_bounded()
  local env = make_shipment_env()
  -- Create multiple shipments and mark them all dirty
  local ids = {}
  for i = 1, 6 do
    local demand = env.make_demand(i, 50)
    local p = i <= 3 and env.platform or env.platform2
    env.state.platform_shipments[p.index] = nil
    local s = env.State.create_shipment(demand, p, {
      {source = "fulgora", planned_amount = 50, cumulative_target = 50, status = "pending"}
    })
    env.Platforms.execute_shipment(s, env.force)
    env.Platforms.mark_shipment_dirty(s.id)
    ids[#ids + 1] = s.id
  end
  assert(env.Platforms.shipment_dirty_active(), "dirty queue should be active")
  -- Step with budget 3 â€” should not complete all 6
  local finished = env.Platforms.step_shipment_dirty(3)
  assert_equal(finished, false, "budget 3 should not clear 6 dirty shipments")
  -- Drain the rest
  while env.Platforms.shipment_dirty_active() do
    env.Platforms.step_shipment_dirty(8)
  end
  assert_equal(next(env.state.shipment_dirty), nil, "dirty queue should be empty after draining")
end

local function test_scheduler_priority_shipment_dirty_before_scan()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {shipment_dirty = true, scan = true, process = true, fleet = true}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    shipment_maintenance_offset = 10,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8,
    shipment_dirty_work_per_tick = 8,
    shipment_execution_work_per_tick = 4,
    shipment_maintenance_work_per_tick = 4
  }
  local callbacks = {
    chest_dirty_active = function() return false end,
    step_chest_dirty = function() return true end,
    construction_dirty_active = function() return false end,
    step_construction_dirty = function() return true end,
    shipment_dirty_active = function() return state.shipment_dirty end,
    step_shipment_dirty = function()
      calls.step_shipment_dirty = (calls.step_shipment_dirty or 0) + 1
      state.shipment_dirty = false
      return true
    end,
    shipment_execution_active = function() return false end,
    step_shipment_execution = function() return true end,
    scan_active = function() return state.scan end,
    process_active = function() return state.process end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1; state.scan = true end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return false end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1; state.process = true end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1; state.process = false end,
    shipment_maintenance_active = function() return false end,
    start_shipment_maintenance = function() calls.start_shipment_maintenance = (calls.start_shipment_maintenance or 0) + 1 end,
    step_shipment_maintenance = function() calls.step_shipment_maintenance = (calls.step_shipment_maintenance or 0) + 1 end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return state.fleet end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }
  assert_equal(Scheduler.step(120, 120, constants, callbacks), "shipment-dirty",
    "shipment dirty should take priority over scan")
  assert_equal(calls.step_shipment_dirty, 1, "shipment dirty should advance before scan")
  assert_equal(calls.step_scan, nil, "scan must not advance while shipment dirty is active")
end

local function test_scheduler_priority_shipment_execution_before_scan()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {shipment_exec = true, scan = true, process = true, fleet = true}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    shipment_maintenance_offset = 10,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8,
    shipment_dirty_work_per_tick = 8,
    shipment_execution_work_per_tick = 4,
    shipment_maintenance_work_per_tick = 4
  }
  local callbacks = {
    chest_dirty_active = function() return false end,
    step_chest_dirty = function() return true end,
    construction_dirty_active = function() return false end,
    step_construction_dirty = function() return true end,
    shipment_dirty_active = function() return false end,
    step_shipment_dirty = function() return true end,
    shipment_execution_active = function() return state.shipment_exec end,
    step_shipment_execution = function()
      calls.step_shipment_execution = (calls.step_shipment_execution or 0) + 1
      state.shipment_exec = false
      return true
    end,
    scan_active = function() return state.scan end,
    process_active = function() return state.process end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1; state.scan = true end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return false end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1; state.process = true end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1; state.process = false end,
    shipment_maintenance_active = function() return false end,
    start_shipment_maintenance = function() calls.start_shipment_maintenance = (calls.start_shipment_maintenance or 0) + 1 end,
    step_shipment_maintenance = function() calls.step_shipment_maintenance = (calls.step_shipment_maintenance or 0) + 1 end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return state.fleet end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }
  assert_equal(Scheduler.step(120, 120, constants, callbacks), "shipment-execution",
    "shipment execution should take priority over scan")
  assert_equal(calls.step_shipment_execution, 1, "shipment execution should advance before scan")
  assert_equal(calls.step_scan, nil, "scan must not advance while shipment execution is active")
end

local function test_scheduler_starts_shipment_execution_when_not_active()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {shipment_exec_active = false, has_planned = true}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    shipment_maintenance_offset = 10,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8,
    shipment_dirty_work_per_tick = 8,
    shipment_execution_work_per_tick = 4,
    shipment_maintenance_work_per_tick = 4
  }
  local callbacks = {
    chest_dirty_active = function() return false end,
    step_chest_dirty = function() return true end,
    construction_dirty_active = function() return false end,
    step_construction_dirty = function() return true end,
    shipment_dirty_active = function() return false end,
    step_shipment_dirty = function() return true end,
    shipment_execution_active = function() return state.shipment_exec_active end,
    start_shipment_execution = function()
      calls.start_shipment_execution = (calls.start_shipment_execution or 0) + 1
      if state.has_planned then
        state.shipment_exec_active = true
        return true
      end
      return false
    end,
    step_shipment_execution = function()
      calls.step_shipment_execution = (calls.step_shipment_execution or 0) + 1
      state.shipment_exec_active = false
      return true
    end,
    scan_active = function() return false end,
    process_active = function() return false end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1 end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return true end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1 end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1 end,
    shipment_maintenance_active = function() return false end,
    start_shipment_maintenance = function() calls.start_shipment_maintenance = (calls.start_shipment_maintenance or 0) + 1 end,
    step_shipment_maintenance = function() calls.step_shipment_maintenance = (calls.step_shipment_maintenance or 0) + 1 end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return false end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }
  -- When there are planned shipments but no active execution job, the scheduler
  -- must call start_shipment_execution and then step it in the same tick.
  assert_equal(Scheduler.step(120, 120, constants, callbacks), "shipment-execution",
    "scheduler should start and step shipment execution when planned shipments exist")
  assert_equal(calls.start_shipment_execution, 1, "scheduler should call start_shipment_execution")
  assert_equal(calls.step_shipment_execution, 1, "scheduler should step shipment execution after starting it")
  assert_equal(calls.start_scan, nil, "scan must not start when shipment execution is running")

  -- When there are no planned shipments, start returns false and scheduler falls through.
  state.has_planned = false
  state.shipment_exec_active = false
  calls.start_scan = nil
  local result = Scheduler.step(240, 120, constants, callbacks)
  assert_equal(result ~= "shipment-execution", true,
    "scheduler should not return shipment-execution when no planned shipments exist")
end

local function test_scheduler_shipment_maintenance_on_own_offset()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local state = {maintenance_started = false}
  local calls = {}
  local constants = {
    monitor_interval = 60,
    monitor_offset = 5,
    shipment_maintenance_offset = 10,
    fleet_refresh_offset = 30,
    gui_refresh_interval = 120,
    gui_refresh_offset = 15,
    scan_work_per_tick = 1,
    process_work_per_tick = 1,
    monitor_work_per_tick = 1,
    fleet_work_per_tick = 1,
    gui_work_per_tick = 1,
    chest_dirty_work_per_tick = 8,
    shipment_dirty_work_per_tick = 8,
    shipment_execution_work_per_tick = 4,
    shipment_maintenance_work_per_tick = 4
  }
  local callbacks = {
    chest_dirty_active = function() return false end,
    step_chest_dirty = function() return true end,
    construction_dirty_active = function() return false end,
    step_construction_dirty = function() return true end,
    shipment_dirty_active = function() return false end,
    step_shipment_dirty = function() return true end,
    shipment_execution_active = function() return false end,
    step_shipment_execution = function() return true end,
    scan_active = function() return false end,
    process_active = function() return false end,
    start_scan = function() calls.start_scan = (calls.start_scan or 0) + 1 end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return true end,
    start_process = function() calls.start_process = (calls.start_process or 0) + 1 end,
    step_process = function() calls.step_process = (calls.step_process or 0) + 1 end,
    shipment_maintenance_active = function() return state.maintenance_started end,
    start_shipment_maintenance = function()
      calls.start_shipment_maintenance = (calls.start_shipment_maintenance or 0) + 1
      state.maintenance_started = true
    end,
    step_shipment_maintenance = function()
      calls.step_shipment_maintenance = (calls.step_shipment_maintenance or 0) + 1
      state.maintenance_started = false
    end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return false end,
    gui_refresh_active = function() return false end,
    start_monitor = function() calls.start_monitor = (calls.start_monitor or 0) + 1 end,
    start_fleet_refresh = function() calls.start_fleet_refresh = (calls.start_fleet_refresh or 0) + 1 end,
    start_gui_refresh = function() calls.start_gui_refresh = (calls.start_gui_refresh or 0) + 1 end,
    step_monitor = function() calls.step_monitor = (calls.step_monitor or 0) + 1 end,
    step_fleet_refresh = function() calls.step_fleet_refresh = (calls.step_fleet_refresh or 0) + 1 end,
    step_gui_refresh = function() calls.step_gui_refresh = (calls.step_gui_refresh or 0) + 1 end
  }
  -- Tick 70 = 70 % 60 == 10 = shipment_maintenance_offset
  assert_equal(Scheduler.step(70, 0, constants, callbacks), "maintenance",
    "tick at maintenance offset should start shipment maintenance")
  assert_equal(calls.start_shipment_maintenance, 1, "shipment maintenance should start at its offset")
  assert_equal(calls.step_shipment_maintenance, 1, "shipment maintenance should step at its offset")
end

local function test_scheduler_steps_active_shipment_maintenance_during_routing()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local calls = {}
  local state = {scan = true, shipment_maintenance = true}
  local constants = {
    monitor_interval = 60, monitor_offset = 5, shipment_maintenance_offset = 10,
    fleet_refresh_offset = 30, gui_refresh_interval = 120, gui_refresh_offset = 15,
    scan_work_per_tick = 1, process_work_per_tick = 1, monitor_work_per_tick = 1,
    fleet_work_per_tick = 1, gui_work_per_tick = 1, chest_dirty_work_per_tick = 8,
    construction_dirty_work_per_tick = 8, shipment_dirty_work_per_tick = 8,
    shipment_execution_work_per_tick = 4, shipment_maintenance_work_per_tick = 4
  }
  local callbacks = {
    bootstrap_active = function() return false end,
    step_bootstrap = function() return true end,
    chest_dirty_active = function() return false end,
    step_chest_dirty = function() return true end,
    construction_dirty_active = function() return false end,
    step_construction_dirty = function() return true end,
    shipment_dirty_active = function() return false end,
    step_shipment_dirty = function() return true end,
    shipment_execution_active = function() return false end,
    start_shipment_execution = function() return false end,
    step_shipment_execution = function() return true end,
    scan_active = function() return state.scan end,
    process_active = function() return false end,
    start_scan = function() state.scan = true end,
    step_scan = function() calls.step_scan = (calls.step_scan or 0) + 1; return false end,
    start_process = function() return true end,
    step_process = function() return true end,
    shipment_maintenance_active = function() return state.shipment_maintenance end,
    start_shipment_maintenance = function() state.shipment_maintenance = true end,
    step_shipment_maintenance = function()
      calls.step_shipment_maintenance = (calls.step_shipment_maintenance or 0) + 1
      return false
    end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return false end,
    gui_refresh_active = function() return false end,
    start_monitor = function() return true end,
    start_fleet_refresh = function() return true end,
    start_gui_refresh = function() return true end,
    step_monitor = function() return true end,
    step_fleet_refresh = function() return true end,
    step_gui_refresh = function() return true end
  }

  assert_equal(Scheduler.step(121, 0, constants, callbacks), "routing",
    "routing should remain the primary scheduler lane")
  assert_equal(calls.step_scan, 1, "routing must still advance")
  assert_equal(calls.step_shipment_maintenance, 1,
    "active Shipment maintenance must advance without waiting for routing to finish")
end

local function test_scheduler_does_not_starve_execution_behind_construction_dirty()
  reset_modules()
  local Scheduler = require("scripts.scheduler")
  local calls = {}
  local state = {shipment_execution = false}
  local constants = {
    monitor_interval = 60, monitor_offset = 5, shipment_maintenance_offset = 10,
    fleet_refresh_offset = 30, gui_refresh_interval = 120, gui_refresh_offset = 15,
    scan_work_per_tick = 1, process_work_per_tick = 1, monitor_work_per_tick = 1,
    fleet_work_per_tick = 1, gui_work_per_tick = 1, chest_dirty_work_per_tick = 8,
    construction_dirty_work_per_tick = 8, shipment_dirty_work_per_tick = 8,
    shipment_execution_work_per_tick = 4, shipment_maintenance_work_per_tick = 4
  }
  local callbacks = {
    bootstrap_active = function() return false end,
    step_bootstrap = function() return true end,
    chest_dirty_active = function() return false end,
    step_chest_dirty = function() return true end,
    construction_dirty_active = function() return true end,
    step_construction_dirty = function()
      calls.step_construction_dirty = (calls.step_construction_dirty or 0) + 1
      return false
    end,
    shipment_dirty_active = function() return false end,
    step_shipment_dirty = function() return true end,
    shipment_execution_active = function() return state.shipment_execution end,
    start_shipment_execution = function()
      calls.start_shipment_execution = (calls.start_shipment_execution or 0) + 1
      state.shipment_execution = true
      return true
    end,
    step_shipment_execution = function()
      calls.step_shipment_execution = (calls.step_shipment_execution or 0) + 1
      state.shipment_execution = false
      return true
    end,
    scan_active = function() return false end,
    process_active = function() return false end,
    start_scan = function() return false end,
    step_scan = function() return true end,
    start_process = function() return false end,
    step_process = function() return true end,
    shipment_maintenance_active = function() return false end,
    start_shipment_maintenance = function() return false end,
    step_shipment_maintenance = function() return true end,
    monitor_active = function() return false end,
    fleet_refresh_active = function() return false end,
    gui_refresh_active = function() return false end,
    start_monitor = function() return false end,
    start_fleet_refresh = function() return false end,
    start_gui_refresh = function() return false end,
    step_monitor = function() return true end,
    step_fleet_refresh = function() return true end,
    step_gui_refresh = function() return true end
  }

  assert_equal(Scheduler.step(1, 0, constants, callbacks), "construction-dirty",
    "construction reconciliation should remain the primary lane")
  assert_equal(calls.step_construction_dirty, 1, "construction reconciliation must advance")
  assert_equal(calls.start_shipment_execution, 1, "planned Shipment execution must be started")
  assert_equal(calls.step_shipment_execution, 1,
    "planned Shipment execution must advance despite continuous construction work")
end

local function test_short_pickup_leg_continues_to_next_source()
  local env = make_shipment_env()
  -- Create a demand with two sources (fulgora 50, vulcanus 30)
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  assert_equal(#shipment.pickup_legs, 2, "should have two pickup legs")
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(shipment.status, "loading", "should be loading")
  -- Simulate short pickup: only 30 loaded at fulgora (baseline 10 + 30 = 40, not 60)
  env.set_cargo(40)
  -- Platform leaves fulgora (moves to vulcanus)
  env.platform.space_location = {name = "vulcanus"}
  env.Platforms.maintain_shipment(shipment.id)
  -- First leg should be skipped (short pickup), second leg still loading
  assert_equal(shipment.pickup_legs[1].status, "skipped", "short first leg should be skipped")
  -- Shipment should still be loading (not all cargo loaded yet)
  assert_equal(shipment.status, "loading", "shipment should continue loading at next source")
  -- Now load full cargo at vulcanus (baseline 10 + 80 = 90)
  env.set_cargo(90)
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "delivering", "shipment should transition to delivering after full load")
end

local function test_partial_delivery_returns_remainder_to_demand()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Simulate short pickup: only 30 loaded (baseline 10 + 30 = 40)
  env.set_cargo(40)
  -- Platform goes to destination without full cargo. Arrival alone is not
  -- delivery; the cargo still has to leave the hub and be observed there.
  env.platform.space_location = {name = "nauvis"}
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "delivering", "short pickup at the destination must wait for unloading")

  env.set_cargo(10)
  env.set_pad_cargo(50)
  demand.amount = 50
  demand.observed_shortage = 50
  demand.current = 30
  game.tick = 160
  demand.last_seen_tick = game.tick
  env.Platforms.maintain_shipment(shipment.id)

  assert_equal(shipment.status, "completed", "destination-confirmed partial delivery should complete its Shipment")
  assert_equal(shipment.delivered_amount, 30, "Shipment must retain the exact partial delivered count")
  assert_equal(demand.status, "approved", "partial Shipment must return its Demand to routing")
  assert_equal(demand.unplanned_amount, 50, "only the exact undelivered remainder may be replanned")
  assert_equal(env.state.demand_by_key[demand.key], demand.id, "partial delivery must retain Demand ownership")
end

local function test_local_fulfillment_during_maintenance()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(shipment.status, "loading", "shipment should be loading")
  -- Simulate local logistics fulfilling the demand
  demand.observed_shortage = 0
  env.Platforms.maintain_shipment(shipment.id)
  assert_equal(shipment.status, "cancelled", "local fulfillment during maintenance should cancel shipment")
  assert_equal(demand.status, "completed", "local fulfillment should complete demand")
  assert_equal(#env.pad_sections.sections, 0, "local fulfillment should remove pad section")
end

local function test_pickup_leg_status_transitions()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 80)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  assert_equal(#shipment.pickup_legs, 2, "should have two legs")
  -- Before execution: legs should be pending
  assert_equal(shipment.pickup_legs[1].status, "pending", "leg 1 should be pending before execution")
  assert_equal(shipment.pickup_legs[2].status, "pending", "leg 2 should be pending before execution")
  env.Platforms.execute_shipment(shipment, env.force)
  -- After execution: legs should be loading
  assert_equal(shipment.pickup_legs[1].status, "loading", "leg 1 should be loading after execution")
  assert_equal(shipment.pickup_legs[2].status, "loading", "leg 2 should be loading after execution")
  -- Load full cargo (baseline 10 + 80 = 90)
  env.set_cargo(90)
  env.Platforms.maintain_shipment(shipment.id)
  -- First leg should be completed (cumulative target 60 reached)
  assert_equal(shipment.pickup_legs[1].status, "completed", "leg 1 should be completed after full load")
  -- Second leg should be completed (cumulative target 90 reached)
  assert_equal(shipment.pickup_legs[2].status, "completed", "leg 2 should be completed after full load")
end

local function test_event_handler_marks_shipment_dirty()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  env.Platforms.execute_shipment(shipment, env.force)
  -- Simulate a platform state change event by marking dirty
  env.Platforms.mark_shipment_dirty(shipment.id)
  assert(env.Platforms.shipment_dirty_active(), "dirty queue should be active after event mark")
  -- Process the dirty queue
  env.set_cargo(60)
  while env.Platforms.shipment_dirty_active() do
    env.Platforms.step_shipment_dirty(8)
  end
  assert_equal(shipment.status, "delivering", "dirty queue should process shipment to delivering")
end

test_bounded_shipment_execution_budget()
test_shipment_maintenance_detects_loaded_cargo()
test_shipment_maintenance_detects_delivered_cargo()
test_shipment_waits_for_destination_confirmed_cargo()
test_shipment_without_destination_receipt_fails_for_replanning()
test_shipment_maintenance_detects_timeout()
test_shipment_maintenance_detects_invalid_platform()
test_shipment_maintenance_detects_invalid_destination_pad()
test_shipment_maintenance_backfills_missing_baseline_count()
test_shipment_dirty_queue_processes_marked_shipments()
test_shipment_dirty_queue_is_bounded()
test_scheduler_priority_shipment_dirty_before_scan()
test_scheduler_priority_shipment_execution_before_scan()
test_scheduler_starts_shipment_execution_when_not_active()
test_scheduler_shipment_maintenance_on_own_offset()
test_scheduler_steps_active_shipment_maintenance_during_routing()
test_scheduler_does_not_starve_execution_behind_construction_dirty()
test_short_pickup_leg_continues_to_next_source()
test_partial_delivery_returns_remainder_to_demand()
test_local_fulfillment_during_maintenance()
test_pickup_leg_status_transitions()
test_event_handler_marks_shipment_dirty()

-- ---------------------------------------------------------------------------
-- Dashboard Shipments view and Trade Requests update tests (Task 8)
-- ---------------------------------------------------------------------------

local function make_gui_element(name, element_type)
  local element = {
    valid = true, name = name or "", type = element_type or "flow",
    visible = true, children = {}, style = {}, caption = "",
    toggled = false, sprite = "", tags = {}, drag_target = nil,
    auto_center = false, enabled = true, parent = nil, opened = nil,
  }
  setmetatable(element, {
    __index = function(t, key)
      if type(key) == "string" then return t.children[key] end
      return nil
    end
  })
  element.add = function(props)
    local child = make_gui_element(props.name, props.type)
    child.parent = element
    for key, value in pairs(props) do
      if key ~= "type" and key ~= "name" and key ~= "style" then child[key] = value end
    end
    if props.style then child.style_name = props.style end
    if props.name then element.children[props.name] = child end
    table.insert(element.children, child)
    return child
  end
  element.clear = function() element.children = {} end
  element.destroy = function()
    element.valid = false
    if element.parent then
      element.parent.children[element.name] = nil
      for i, c in ipairs(element.parent.children) do
        if c == element then table.remove(element.parent.children, i); break end
      end
    end
  end
  return element
end

local function find_element_by_name(root, name)
  if not root or not root.valid then return nil end
  if root.name == name then return root end
  for _, child in ipairs(root.children or {}) do
    local found = find_element_by_name(child, name)
    if found then return found end
  end
  return nil
end

local function find_elements_by_pattern(root, pattern)
  local results = {}
  local function walk(node)
    if not node or not node.valid then return end
    if node.name and string.match(node.name, pattern) then
      table.insert(results, node)
    end
    for _, child in ipairs(node.children or {}) do walk(child) end
  end
  walk(root)
  return results
end

local function make_gui_env()
  reset_modules()
  storage = {}
  defines = {inventory = {hub_main = 1}, alert_type = {no_material_for_construction = 1}}
  settings = {global = {
    ["il-auto-approve-seconds"] = {value = 30},
    ["il-enable-ready-signal"] = {value = false},
    ["il-ready-signal"] = {value = "signal-green"}
  }}
  prototypes = nil

  local force = {valid = true, index = 1, platforms = {}, logistic_networks = {}}
  local player = {
    valid = true, index = 1, force = force,
    display_resolution = {width = 1920, height = 1080},
    display_scale = 1,
    gui = {screen = make_gui_element("screen", "screen")},
    opened = nil,
    set_shortcut_toggled = function() end,
  }
  game = {
    tick = 100,
    forces = {[1] = force},
    surfaces = {},
    connected_players = {player},
    get_player = function(idx) return idx == 1 and player or nil end,
    get_entity_by_unit_number = function() return nil end,
    get_surface = function() return nil end,
  }

  local State = require("scripts.state")
  local Gui = require("scripts.gui")
  local state = State.ensure()

  local function make_demand(id, item, quality, destination, amount)
    local d = {
      id = id, key = "demand-" .. id, status = "queued", force_index = 1,
      destination_surface_index = 1, logistic_network_id = 7,
      destination = destination or "nauvis", item = item or "iron-plate",
      quality = quality or "normal", amount = amount or 100,
      observed_shortage = amount or 100, active_shipment_amount = 0,
      unplanned_amount = amount or 100, origin = "chest", created_tick = 50,
      priority = 0,
    }
    state.demands[id] = d
    state.demand_by_key[d.key] = id
    return d
  end

  local function make_shipment(id, demand_id, platform_name, status, amount, legs)
    local s = {
      id = id, demand_id = demand_id, force_index = 1,
      platform_index = id + 10, platform_name = platform_name or "Courier",
      destination = "nauvis", destination_surface_index = 1,
      logistic_network_id = 7, item = "iron-plate", quality = "normal",
      amount = amount or 50, allocated_amount = amount or 50,
      status = status or "loading", started_tick = 80, baseline_count = 10,
      pickup_legs = legs or {{source = "fulgora", cumulative_target = 50, status = "loading"}},
    }
    state.shipments[id] = s
    State.add_shipment_index(demand_id, id)
    state.platform_shipments[s.platform_index] = id
    return s
  end

  return {
    State = State, Gui = Gui, state = state, player = player, force = force,
    make_demand = make_demand, make_shipment = make_shipment,
    find_element = find_element_by_name, find_elements = find_elements_by_pattern,
  }
end

local function test_shipments_view_in_navigation()
  local env = make_gui_env()
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  assert(frame, "dashboard frame should be built")
  local nav = env.find_element(frame, "il-navigation")
  assert(nav, "navigation element should exist")
  local shipments_nav = nav.children["il-nav-shipments"]
  assert(shipments_nav, "shipments navigation button should exist")
  local found_shipments = false
  for _, child in ipairs(nav.children) do
    if child.name == "il-nav-shipments" then found_shipments = true end
  end
  assert(found_shipments, "shipments nav button should be in navigation children")
  local order = {}
  for _, child in ipairs(nav.children) do
    if string.match(child.name or "", "^il%-nav%-(%a+)$") then
      table.insert(order, string.match(child.name, "^il%-nav%-(%a+)$"))
    end
  end
  assert_equal(#order, 5, "navigation should have 5 views")
  assert_equal(order[1], "fleet", "fleet should be first")
  assert_equal(order[2], "requests", "requests should be second")
  assert_equal(order[3], "shipments", "shipments should be third")
  assert_equal(order[4], "destinations", "destinations should be fourth")
  assert_equal(order[5], "history", "history should be fifth")
end

local function test_shipments_view_sorted_by_status_then_id()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(3, 1, "Gamma", "completed", 30)
  env.make_shipment(1, 1, "Alpha", "loading", 50)
  env.make_shipment(2, 1, "Beta", "delivering", 40)
  env.make_shipment(4, 1, "Delta", "failed", 20)
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local rows = env.find_element(frame, "il-shipment-list-rows")
  assert(rows, "shipment list rows should exist")
  local shipment_rows = {}
  for _, child in ipairs(rows.children) do
    local sid = tonumber(string.match(child.name or "", "^il%-shipment%-row%-(%d+)$"))
    if sid then table.insert(shipment_rows, sid) end
  end
  assert_equal(#shipment_rows, 4, "should show 4 shipment rows")
  assert_equal(shipment_rows[1], 1, "loading should come first")
  assert_equal(shipment_rows[2], 2, "delivering should come second")
  assert_equal(shipment_rows[3], 3, "completed should come third")
  assert_equal(shipment_rows[4], 4, "failed should come fourth")
end

local function test_shipments_view_shows_fields()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Courier", "loading", 50, {
    {source = "nauvis", cumulative_target = 50, status = "loading"},
  })
  env.state.shipments[1].destination = "fulgora"
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local ship_label = env.find_element(frame, "il-shipment-ship-1")
  assert(ship_label, "shipment row should show platform name")
  assert(string.find(ship_label.caption, "Courier"), "platform name should be visible")
  local status_label = env.find_element(frame, "il-shipment-status-1")
  assert(status_label, "shipment row should show status")
  local amount_label = env.find_element(frame, "il-shipment-amount-1")
  assert(amount_label, "shipment row should show amount")
  local route_label = env.find_element(frame, "il-shipment-route-1")
  assert(route_label, "shipment row should show route")
  local item_button = env.find_element(frame, "il-shipment-item-1")
  assert(item_button, "shipment row should show item icon")
end

local function test_shipments_view_empty_state()
  local env = make_gui_env()
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local rows = env.find_element(frame, "il-shipment-list-rows")
  assert(rows, "shipment list rows should exist")
  local found_empty = false
  for _, child in ipairs(rows.children) do
    if child.caption and type(child.caption) == "table" and child.caption[1] == "il-gui.no-shipments" then
      found_empty = true
    end
  end
  assert(found_empty, "empty state should show no-shipments message")
end

local function test_trade_requests_shows_demand_fields()
  local env = make_gui_env()
  local demand = env.make_demand(1, "iron-plate", "normal", "nauvis", 100)
  demand.observed_shortage = 80
  demand.active_shipment_amount = 50
  demand.unplanned_amount = 30
  demand.status = "loading"
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local shortage_label = env.find_element(frame, "il-request-shortage-1")
  assert(shortage_label, "trade requests should show observed shortage")
  local active_label = env.find_element(frame, "il-request-active-1")
  assert(active_label, "trade requests should show active shipment amount")
end

local function test_trade_requests_detail_shows_child_shipments()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Alpha", "loading", 50)
  env.make_shipment(2, 1, "Beta", "delivering", 30)
  env.state.gui_tabs[1] = {view = "requests", selected_request_id = 1}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local detail = env.find_element(frame, "il-request-detail")
  assert(detail, "request detail panel should exist")
  local found_section = false
  for _, child in ipairs(detail.children) do
    if child.name and string.match(child.name, "^il%-demand%-shipments%-section$") then
      found_section = true
    end
  end
  assert(found_section, "detail should include a child shipments section")
  local shipment_entries = env.find_elements(frame, "^il%-demand%-shipment%-entry%-%d+$")
  assert(#shipment_entries >= 2, "detail should list at least 2 child shipments")
end

local function test_demand_link_switches_to_requests()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Courier", "loading", 50)
  env.state.gui_tabs[1] = {view = "shipments"}
  env.Gui.build(env.player)
  env.Gui.select_request(env.player, 1)
  local gui_state = env.state.gui_tabs[1]
  assert_equal(gui_state.view, "requests", "demand link should switch to requests view")
  assert_equal(gui_state.selected_request_id, 1, "demand link should select the demand")
end

local function test_shipment_cancel_action()
  local env = make_gui_env()
  env.make_demand(1)
  local shipment = env.make_shipment(1, 1, "Courier", "loading", 50)
  env.state.gui_tabs[1] = {view = "shipments"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local cancel_btn = env.find_element(frame, "il-cancel-shipment-1")
  assert(cancel_btn, "active shipment should have a cancel button")
  local Platforms = require("scripts.platforms")
  Platforms.cancel_shipment(1, "user cancel")
  assert_equal(shipment.status, "cancelled", "cancel should set shipment status to cancelled")
  assert_equal(env.state.shipments[1], nil, "cancelled shipment should be removed from active state")
end

local function test_shipment_metrics()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Alpha", "loading", 50)
  env.make_shipment(2, 1, "Beta", "delivering", 30)
  env.make_shipment(3, 1, "Gamma", "completed", 20)
  env.make_shipment(4, 1, "Delta", "failed", 10)
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local total_metric = env.find_element(frame, "il-metric-shipments-total")
  assert(total_metric, "total shipments metric should exist")
  assert_equal(total_metric.caption, "4", "total metric should show 4")
  local loading_metric = env.find_element(frame, "il-metric-shipments-loading")
  assert(loading_metric, "loading shipments metric should exist")
  assert_equal(loading_metric.caption, "1", "loading metric should show 1")
  local delivering_metric = env.find_element(frame, "il-metric-shipments-delivering")
  assert(delivering_metric, "delivering shipments metric should exist")
  assert_equal(delivering_metric.caption, "1", "delivering metric should show 1")
  local finished_metric = env.find_element(frame, "il-metric-shipments-finished")
  assert(finished_metric, "finished shipments metric should exist")
  assert_equal(finished_metric.caption, "2", "finished metric should show 2")
end

local function test_layout_includes_shipment_widths()
  local env = make_gui_env()
  env.Gui.build(env.player)
  -- layout is internal but we can verify through the built columns
  local frame = env.player.gui.screen["il-dashboard"]
  local shipments_view = env.find_element(frame, "il-content-shipments")
  assert(shipments_view, "shipments view container should exist")
  -- Verify column headers exist
  local header = env.find_element(frame, "il-shipment-header")
  assert(header, "shipment column header should exist")
end

local function test_refresh_shipments_structure_updates_rows()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Alpha", "loading", 50)
  env.state.gui_tabs[1] = {view = "shipments"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local rows_before = env.find_element(frame, "il-shipment-list-rows")
  local count_before = 0
  for _, child in ipairs(rows_before.children) do
    if string.match(child.name or "", "^il%-shipment%-row%-%d+$") then count_before = count_before + 1 end
  end
  assert_equal(count_before, 1, "should start with 1 shipment row")
  env.make_shipment(2, 1, "Beta", "delivering", 30)
  env.Gui.refresh_shipments_structure(env.player)
  local rows_after = env.find_element(frame, "il-shipment-list-rows")
  local count_after = 0
  for _, child in ipairs(rows_after.children) do
    if string.match(child.name or "", "^il%-shipment%-row%-%d+$") then count_after = count_after + 1 end
  end
  assert_equal(count_after, 2, "refresh should update to 2 shipment rows")
end

local function test_refresh_summaries_includes_shipment_metrics()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Alpha", "loading", 50)
  env.state.gui_tabs[1] = {view = "shipments"}
  env.Gui.build(env.player)
  env.make_shipment(2, 1, "Beta", "delivering", 30)
  env.Gui.refresh_structure(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local total_metric = env.find_element(frame, "il-metric-shipments-total")
  assert_equal(total_metric.caption, "2", "refresh_structure should update shipment total metric")
end

test_shipments_view_in_navigation()
test_shipments_view_sorted_by_status_then_id()
test_shipments_view_shows_fields()
test_shipments_view_empty_state()
test_trade_requests_shows_demand_fields()
test_trade_requests_detail_shows_child_shipments()
test_demand_link_switches_to_requests()
test_shipment_cancel_action()
test_shipment_metrics()
test_layout_includes_shipment_widths()
test_refresh_shipments_structure_updates_rows()
test_refresh_summaries_includes_shipment_metrics()

-- ---------------------------------------------------------------------------
-- Clear (remove stale entry) button tests
-- ---------------------------------------------------------------------------

local function test_history_clear_all_button_present()
  local env = make_gui_env()
  local demand = env.make_demand(1)
  env.State.add_history(demand, "completed", "done")
  env.state.gui_tabs[1] = {view = "history"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local btn = env.find_element(frame, "il-history-clear-all")
  assert(btn, "history view should have a clear-all button")
  env.State.clear_history()
  assert_equal(#env.state.history, 0, "clear_history should empty the history log")
end

local function test_history_per_row_clear_button_removes_entry()
  local env = make_gui_env()
  local demand = env.make_demand(1)
  env.State.add_history(demand, "completed", "done")
  env.State.add_history(demand, "failed", "boom")
  env.state.gui_tabs[1] = {view = "history"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local first_seq = env.state.history[1].seq
  local btn = env.find_element(frame, "il-history-clear-" .. tostring(first_seq))
  assert(btn, "each history row should have a per-row clear button")
  env.State.remove_history_entry(first_seq)
  assert_equal(#env.state.history, 1, "remove_history_entry should remove one entry")
  assert(env.state.history[1].seq ~= first_seq, "removed entry should no longer be present")
end

local function test_request_clear_button_removes_demand()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Courier", "completed", 50)
  env.state.gui_tabs[1] = {view = "requests"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local btn = env.find_element(frame, "il-request-clear-1")
  assert(btn, "each trade request row should have a clear button")
  local Demands = require("scripts.demands")
  Demands.remove(1, "cleared by player")
  assert_equal(env.state.demands[1], nil, "Demands.remove should delete the demand")
  assert_equal(env.state.demand_by_key["demand-1"], nil, "Demands.remove should clear the key index")
  assert_equal(env.state.shipments[1], nil, "Demands.remove should remove child shipments")
end

local function test_shipment_clear_button_removes_terminal_shipment()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Courier", "completed", 50)
  env.state.gui_tabs[1] = {view = "shipments"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local btn = env.find_element(frame, "il-shipment-clear-1")
  assert(btn, "each shipment row should have a clear button")
  local Platforms = require("scripts.platforms")
  Platforms.remove_shipment(1, "cleared by player")
  assert_equal(env.state.shipments[1], nil, "remove_shipment should delete a terminal shipment")
end

local function test_shipments_clear_all_button_present()
  local env = make_gui_env()
  env.make_demand(1)
  env.make_shipment(1, 1, "Alpha", "loading", 50)
  env.state.gui_tabs[1] = {view = "shipments"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local btn = env.find_element(frame, "il-shipments-clear-all")
  assert(btn, "shipments view should have a clear-all button")
end

local function test_requests_clear_all_button_present()
  local env = make_gui_env()
  env.make_demand(1)
  env.state.gui_tabs[1] = {view = "requests"}
  env.Gui.build(env.player)
  local frame = env.player.gui.screen["il-dashboard"]
  local btn = env.find_element(frame, "il-requests-clear-all")
  assert(btn, "trade requests view should have a clear-all button")
end

test_history_clear_all_button_present()
test_history_per_row_clear_button_removes_entry()
test_request_clear_button_removes_demand()
test_shipment_clear_button_removes_terminal_shipment()
test_shipments_clear_all_button_present()
test_requests_clear_all_button_present()

-- ---------------------------------------------------------------------------
-- Blocklist item filter tests
-- ---------------------------------------------------------------------------

local function test_blocklist_items_filtered_from_construction()
  local State, Demands, state, ghost, proxy = make_construction_env()
  -- Ghost for a blocklisted item (rocket-silo)
  local rs = ghost("rocket-silo", "rocket-silo", "normal")
  Demands.track_construction(rs)
  -- Proxy for a blocklisted item (captive-biter-spawner)
  local bs = proxy("captive-biter-spawner", 7, "normal")
  Demands.track_construction(bs)
  -- Ghost for a shippable item (iron-plate)
  local ip = ghost("iron-plate", "iron-plate", "normal")
  Demands.track_construction(ip)
  -- Ghost for a not-sendable but NOT blocklisted item (cliff-explosives)
  local ce = ghost("cliff-explosives", "cliff-explosives", "normal")
  Demands.track_construction(ce)
  while Demands.construction_dirty_active() do Demands.step_construction_dirty(16) end
  -- Blocklisted items should NOT create demands
  local rs_key = table.concat({"alert", 1, 1, 101, "rocket-silo", "normal"}, "|")
  assert(state.demand_by_key[rs_key] == nil, "rocket-silo should be filtered out (blocklisted)")
  local bs_key = table.concat({"alert", 1, 1, 101, "captive-biter-spawner", "normal"}, "|")
  assert(state.demand_by_key[bs_key] == nil, "captive-biter-spawner should be filtered out (blocklisted)")
  -- Shippable item should create a demand
  local ip_key = table.concat({"alert", 1, 1, 101, "iron-plate", "normal"}, "|")
  assert(state.demand_by_key[ip_key], "iron-plate should create a demand")
  -- Not-sendable but not blocklisted item should also create a demand
  local ce_key = table.concat({"alert", 1, 1, 101, "cliff-explosives", "normal"}, "|")
  assert(state.demand_by_key[ce_key], "cliff-explosives should create a demand (not-sendable but not blocklisted)")
end

test_blocklist_items_filtered_from_construction()

-- ---------------------------------------------------------------------------
-- Platforms.cancel cleanup tests
-- ---------------------------------------------------------------------------

local function test_platforms_cancel_cancels_shipments()
  local env = make_shipment_env()
  local demand = env.make_demand(1, 50)
  env.Router.try_dispatch(demand)
  local shipment = env.state.shipments[1]
  assert(shipment, "shipment should be created")
  env.Platforms.execute_shipment(shipment, env.force)
  assert_equal(shipment.status, "loading", "shipment should be loading after execution")
  assert_equal(env.state.platform_shipments[4], shipment.id, "platform should be assigned")
  -- Simulate retire_request cancelling the demand (e.g. construction ghost built)
  env.Platforms.cancel(demand, "Need was fulfilled or removed")
  -- The shipment must be cancelled so the platform is released
  assert_equal(shipment.status, "cancelled", "Platforms.cancel must cancel child shipments")
  assert_equal(env.state.platform_shipments[4], nil, "Platforms.cancel must release the platform")
  assert_equal(env.state.pad_sections[demand.id], nil, "Platforms.cancel must remove pad section")
end

test_platforms_cancel_cancels_shipments()

-- ---------------------------------------------------------------------------
-- Factorio 2.1 control-stage event registration and payloads
-- ---------------------------------------------------------------------------

local function load_control_event_handlers(live_test_mode)
  reset_modules()
  storage = {}
  settings = {global = {}}
  if live_test_mode then
    settings.global["il-live-test-mode"] = {value = true}
  end
  local event_names = {
    "on_built_entity", "on_robot_built_entity", "script_raised_built", "script_raised_revive",
    "on_entity_cloned", "on_entity_upgraded", "on_player_mined_entity", "on_robot_mined_entity",
    "on_entity_died", "script_raised_destroy", "on_entity_logistic_slot_changed",
    "on_space_platform_changed_state", "on_cargo_pod_delivered_cargo", "on_lua_shortcut",
    "on_gui_click", "on_player_display_resolution_changed", "on_player_display_scale_changed",
    "on_gui_closed", "on_tick"
  }
  defines = {events = {}, inventory = {hub_main = 1}}
  for _, name in ipairs(event_names) do defines.events[name] = name end
  table_size = function(values)
    local count = 0
    for _ in pairs(values or {}) do count = count + 1 end
    return count
  end

  local handlers = {}
  script = {
    on_init = function() end,
    on_configuration_changed = function() end,
    on_event = function(event_id, handler)
      handlers[event_id] = handler
    end
  }
  local interfaces = {}
  remote = {add_interface = function(name, interface) interfaces[name] = interface end}
  game = {
    tick = 0,
    tick_paused = true,
    forces = {},
    surfaces = {},
    connected_players = {},
    get_entity_by_unit_number = function() return nil end,
    get_surface = function() return nil end,
    get_player = function() return nil end
  }

  package.loaded["control"] = nil
  require("control")
  return handlers, require("scripts.state"), interfaces
end

local function test_control_registers_factorio_2_1_shipment_progress_events()
  local handlers = load_control_event_handlers()
  assert(handlers[defines.events.on_space_platform_changed_state],
    "control must register Factorio 2.1 platform-state progress events")
  assert(handlers[defines.events.on_cargo_pod_delivered_cargo],
    "control must register Factorio 2.1 delivered-cargo events")
end

local function test_control_marks_pad_shipment_dirty_from_delivered_cargo_payload()
  local handlers, State = load_control_event_handlers()
  local state = State.ensure()
  state.demands[3] = {id = 3, origin = "chest", chest_unit_number = 1}
  state.pad_sections[3] = {pad_unit_number = 99}
  state.shipments[42] = {id = 42, demand_id = 3, status = "delivering"}
  state.shipments_by_demand[3] = {[42] = true}

  local pad = {valid = true, type = "cargo-landing-pad", unit_number = 99}
  handlers[defines.events.on_cargo_pod_delivered_cargo]({
    cargo_pod = {
      valid = true,
      cargo_pod_destination = {type = "station", station = pad}
    }
  })

  assert_equal(state.shipment_dirty[42], true,
    "delivered-cargo payload must enqueue the Shipment attached to its landing pad")
  assert_equal(state.chest_dirty[1], true,
    "delivered-cargo payload must enqueue authoritative destination reconciliation")
end

local function test_control_dump_state_includes_shipment_baseline()
  local _, State, interfaces = load_control_event_handlers()
  local state = State.ensure()
  state.shipments[7] = {
    id = 7,
    status = "loading",
    platform_name = "Probe",
    item = "iron-plate",
    amount = 10,
    baseline_count = nil,
    pickup_legs = {}
  }
  local dump = interfaces.interplanetary_logistics.dump_state()
  assert(dump:find("Shipment 7: status=loading"),
    "diagnostic state dump should include the live shipment")
  assert(dump:find("baseline=nil"),
    "diagnostic state dump should expose a missing shipment baseline")
end

local function test_control_prepare_live_smoke_clears_only_active_baselines()
  local _, State, interfaces = load_control_event_handlers(true)
  local state = State.ensure()
  state.shipments[7] = {
    id = 7,
    status = "loading",
    baseline_count = 25,
    pickup_legs = {}
  }
  state.shipments[9] = {
    id = 9,
    status = "failed",
    baseline_count = 12,
    pickup_legs = {}
  }

  local result = interfaces.interplanetary_logistics.prepare_live_smoke()
  assert(result:find("7"), "live smoke preparation should report active shipment ids")
  assert_equal(state.shipments[7].baseline_count, nil,
    "live smoke preparation should clear the active Shipment baseline")
  assert_equal(state.shipments[7].status, "loading",
    "live smoke preparation must not reanimate or change Shipment status")
  assert_equal(state.shipment_dirty[7], true,
    "live smoke preparation should enqueue active Shipment maintenance")
  assert_equal(state.shipments[9].baseline_count, 12,
    "live smoke preparation must leave terminal Shipment state unchanged")
end

local function test_control_live_smoke_mode_is_explicitly_enabled()
  local _, _, interfaces = load_control_event_handlers(false)
  assert_equal(settings.global["il-live-test-mode"], nil,
    "live-test setting should be absent from the minimal test fixture by default")
  -- The real Factorio settings table always contains the hidden prototype;
  -- model that entry before invoking the mod-owned setter.
  settings.global["il-live-test-mode"] = {value = false}
  local result = interfaces.interplanetary_logistics.enable_live_test_mode()
  assert(result:find("enabled"), "live smoke mode should report explicit enablement")
  assert_equal(settings.global["il-live-test-mode"].value, true,
    "live smoke mode should be enabled by the mod-owned interface")
end

test_control_dump_state_includes_shipment_baseline()
test_control_prepare_live_smoke_clears_only_active_baselines()
test_control_live_smoke_mode_is_explicitly_enabled()

test_control_registers_factorio_2_1_shipment_progress_events()
test_control_marks_pad_shipment_dirty_from_delivered_cargo_payload()

local function test_control_accepts_direct_entity_cargo_pod_destination()
  local handlers, State = load_control_event_handlers()
  local state = State.ensure()
  state.demands[3] = {id = 3, origin = "chest", chest_unit_number = 1}
  state.pad_sections[3] = {pad_unit_number = 99}
  state.shipments[42] = {id = 42, demand_id = 3, status = "delivering"}
  state.shipments_by_demand[3] = {[42] = true}

  local pad = {valid = true, type = "cargo-landing-pad", unit_number = 99}
  handlers[defines.events.on_cargo_pod_delivered_cargo]({
    cargo_pod = {
      valid = true,
      cargo_pod_destination = pad
    }
  })

  assert_equal(state.shipment_dirty[42], true,
    "delivered-cargo handler must accept a direct LuaEntity destination")
end

test_control_accepts_direct_entity_cargo_pod_destination()

print("runtime_spec: OK")
