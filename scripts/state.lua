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
  state.next_request_id = state.next_request_id or 1
  return state
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
