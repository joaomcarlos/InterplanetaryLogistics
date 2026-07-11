local Constants = require("scripts.constants")

local State = {}

function State.ensure()
  local fresh = not storage.interplanetary_logistics
  storage.interplanetary_logistics = storage.interplanetary_logistics or {}
  local state = storage.interplanetary_logistics
  if fresh then
    state.schema_version = Constants.schema_version
  end
  state.chests = state.chests or {}
  state.requests = state.requests or {}
  state.request_by_key = state.request_by_key or {}
  state.suppressions = state.suppressions or {}
  state.enrolled = state.enrolled or {}
  state.active_transfers = state.active_transfers or {}
  state.platform_transfers = state.platform_transfers or {}
  state.history = state.history or {}
  state.source_metrics = state.source_metrics or {}
  state.gui_tabs = state.gui_tabs or {}
  state.stock_reservations = state.stock_reservations or {}
  state.route_preferences = state.route_preferences or {}
  state.platform_options = state.platform_options or {}
  state.platform_status = state.platform_status or {}
  state.recent_returns = state.recent_returns or {}
  state.next_request_id = state.next_request_id or 1
  if (state.schema_version or 1) < 2 then
    for _, tabs in pairs(state.gui_tabs) do
      local old = tabs.main_tab_index
      if old == 1 then tabs.main_tab_index = 2
      elseif old == 2 then tabs.main_tab_index = 3
      elseif old == 3 then tabs.main_tab_index = 1
      end
    end
  end
  state.schema_version = Constants.schema_version
  return state
end

function State.route_key(source, destination)
  return (source or "?") .. "->" .. (destination or "?")
end

function State.get_route_preference(force_index, source, destination)
  local by_force = State.ensure().route_preferences[force_index] or {}
  return by_force[State.route_key(source, destination)]
end

function State.set_route_preference(force_index, source, destination, platform_index)
  local state = State.ensure()
  state.route_preferences[force_index] = state.route_preferences[force_index] or {}
  local key = State.route_key(source, destination)
  state.route_preferences[force_index][key] = platform_index or nil
end

function State.get_platform_options(force_index, platform_index)
  local state = State.ensure()
  state.platform_options[force_index] = state.platform_options[force_index] or {}
  state.platform_options[force_index][platform_index] = state.platform_options[force_index][platform_index] or {
    ready_signal = false
  }
  return state.platform_options[force_index][platform_index]
end

function State.reserve(request)
  State.ensure().stock_reservations[request.id] = {
    request_id = request.id,
    source = request.source,
    item = request.item,
    quality = request.quality or "normal",
    amount = request.amount
  }
end

function State.release_reservation(request_id)
  State.ensure().stock_reservations[request_id] = nil
end

function State.reserved_count(source, item, quality, except_request_id)
  local total = 0
  for request_id, reservation in pairs(State.ensure().stock_reservations) do
    if request_id ~= except_request_id and reservation.source == source and reservation.item == item
      and reservation.quality == (quality or "normal") then
      total = total + reservation.amount
    end
  end
  return total
end

function State.get()
  return storage.interplanetary_logistics
end

function State.rebuild_chests()
  local state = State.ensure()
  state.chests = {}
  for _, surface in pairs(game.surfaces) do
    for _, chest in pairs(surface.find_entities_filtered({name = Constants.chest_name})) do
      if chest.valid and chest.unit_number then
        state.chests[chest.unit_number] = true
      end
    end
  end
end

function State.add_history(request, status, reason)
  local state = State.ensure()
  state.history[#state.history + 1] = {
    id = request.id,
    item = request.item,
    quality = request.quality,
    amount = request.amount,
    source = request.source,
    destination = request.destination,
    origin = request.origin,
    status = status,
    reason = reason,
    tick = game.tick
  }
  while #state.history > Constants.history_limit do
    table.remove(state.history, 1)
  end
end

return State
