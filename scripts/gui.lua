local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")
local Platforms = require("scripts.platforms")

local Gui = {}

local status_colors = {
  queued = {r = 1, g = 0.72, b = 0.2},
  approved = {r = 0.35, g = 0.75, b = 1},
  loading = {r = 0.5, g = 0.85, b = 1},
  delivering = {r = 0.4, g = 1, b = 0.5},
  denied = {r = 1, g = 0.35, b = 0.3},
  completed = {r = 0.45, g = 0.9, b = 0.45},
  failed = {r = 1, g = 0.25, b = 0.25}
}

local function heading(parent, caption)
  local label = parent.add({type = "label", caption = caption})
  label.style.font = "heading-2"
  label.style.top_margin = 8
  label.style.bottom_margin = 4
end

local function status_label(parent, status)
  local label = parent.add({type = "label", caption = status})
  label.style.font_color = status_colors[status] or {r = 0.8, g = 0.8, b = 0.8}
end

local function request_row(parent, request)
  local row = parent.add({type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding"})
  row.style.horizontally_stretchable = true
  local top = row.add({type = "flow", direction = "horizontal"})
  top.style.vertical_align = "center"
  top.add({type = "sprite", sprite = "item/" .. request.item})
  local title = top.add({
    type = "label",
    caption = {"", "[font=default-bold]", request.amount, " x [item=", request.item, "][/font]  "}
  })
  title.style.horizontally_stretchable = true
  status_label(top, request.status)
  if request.status == "queued" then
    local remaining = math.max(0, request.auto_approve_tick - game.tick)
    top.add({type = "label", caption = "Auto " .. Util.format_ticks(remaining)})
    top.add({type = "button", name = "il-approve-" .. request.id, caption = {"il-gui.approve"}, style = "confirm_button"})
    top.add({type = "button", name = "il-deny-" .. request.id, caption = {"il-gui.deny"}, style = "red_button"})
  elseif request.status == "denied" then
    top.add({type = "button", name = "il-reopen-" .. request.id, caption = {"il-gui.reopen"}})
  end
  local route = request.source and (request.source .. "  ->  " .. request.destination) or ("Destination: " .. request.destination)
  row.add({type = "label", caption = route})
  if request.platform_name then
    row.add({type = "label", caption = "Platform: " .. request.platform_name})
  end
  if request.last_reason then
    local reason = row.add({type = "label", caption = request.last_reason})
    reason.style.font_color = {r = 0.9, g = 0.65, b = 0.35}
  end
end

local function build_requests(parent, player)
  heading(parent, {"il-gui.requests"})
  local any = false
  for _, request in pairs(Util.sorted_values(State.ensure().requests, function(candidate)
    return candidate.force_index == player.force.index
      and (Constants.active_statuses[candidate.status] or candidate.status == "denied")
  end)) do
    request_row(parent, request)
    any = true
  end
  if not any then
    parent.add({type = "label", caption = {"il-gui.no-requests"}})
  end
end

local function build_chests(parent, player)
  heading(parent, {"il-gui.requester-chests"})
  local any = false
  for unit_number in pairs(State.ensure().chests) do
    local chest = game.get_entity_by_unit_number(unit_number)
    if chest and chest.valid and chest.force == player.force then
      local row = parent.add({type = "flow", direction = "horizontal"})
      row.add({type = "sprite", sprite = "entity/" .. Constants.chest_name})
      row.add({type = "label", caption = {"", Util.surface_location(chest.surface), "  ", Util.gps(chest)}})
      local point = chest.get_requester_point()
      row.add({type = "label", caption = point and point.logistic_network and {"il-gui.network-connected"} or {"il-gui.network-disconnected"}})
      any = true
    end
  end
  if not any then
    parent.add({type = "label", caption = {"il-gui.no-chests"}})
  end
end

local function route_text(platform)
  local names = {}
  local schedule = platform.schedule
  for _, record in pairs(schedule and schedule.records or {}) do
    if not record.temporary then
      names[#names + 1] = record.station
    end
  end
  return #names > 0 and table.concat(names, " -> ") or "No scheduled route"
end

local function build_platforms(parent, player)
  heading(parent, {"il-gui.platforms"})
  local any = false
  for _, platform in pairs(player.force.platforms) do
    if platform.valid then
      local row = parent.add({type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding"})
      row.style.horizontally_stretchable = true
      local top = row.add({type = "flow", direction = "horizontal"})
      local name = top.add({type = "label", caption = "[font=default-bold]" .. platform.name .. "[/font]"})
      name.style.horizontally_stretchable = true
      if Platforms.is_enrolled(player.force.index, platform.index) then
        status_label(top, "enrolled")
        top.add({type = "button", name = "il-unenroll-" .. platform.index, caption = {"il-gui.unenroll"}})
      else
        top.add({type = "button", name = "il-enroll-" .. platform.index, caption = {"il-gui.enroll"}, style = "confirm_button"})
      end
      row.add({type = "label", caption = route_text(platform)})
      local active = State.ensure().platform_transfers[platform.index]
      if active then
        row.add({type = "label", caption = "Handling request #" .. active})
      end
      any = true
    end
  end
  if not any then
    parent.add({type = "label", caption = {"il-gui.no-platforms"}})
  end
end

local function build_history(parent, player)
  heading(parent, {"il-gui.history"})
  local state = State.ensure()
  local any = false
  for index = #state.history, 1, -1 do
    local entry = state.history[index]
    local request = state.requests[entry.id]
    if request and request.force_index == player.force.index then
      local row = parent.add({type = "flow", direction = "horizontal"})
      row.add({type = "sprite", sprite = "item/" .. entry.item})
      local text = row.add({type = "label", caption = entry.amount .. " x [item=" .. entry.item .. "]  " .. (entry.source or "-") .. " -> " .. entry.destination})
      text.style.horizontally_stretchable = true
      status_label(row, entry.status)
      any = true
    end
  end
  if not any then
    parent.add({type = "label", caption = {"il-gui.no-history"}})
  end
end

local function add_tab(tabs, caption, builder, player)
  local tab = tabs.add({type = "tab", caption = caption})
  local scroll = tabs.add({type = "scroll-pane", direction = "vertical"})
  scroll.style.width = 760
  scroll.style.height = 520
  scroll.style.padding = 8
  builder(scroll, player)
  tabs.add_tab(tab, scroll)
end

function Gui.build(player)
  local previous = player.gui.screen[Constants.dashboard_name]
  if previous then
    previous.destroy()
  end
  local frame = player.gui.screen.add({type = "frame", name = Constants.dashboard_name, direction = "vertical"})
  frame.auto_center = true
  local titlebar = frame.add({type = "flow", direction = "horizontal"})
  titlebar.drag_target = frame
  local title = titlebar.add({type = "label", caption = {"il-gui.title"}, style = "frame_title"})
  title.drag_target = frame
  local filler = titlebar.add({type = "empty-widget", style = "draggable_space_header"})
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.drag_target = frame
  titlebar.add({type = "sprite-button", name = "il-refresh", sprite = "utility/refresh", style = "frame_action_button"})
  titlebar.add({type = "sprite-button", name = "il-close", sprite = "utility/close", style = "frame_action_button"})
  local tabs = frame.add({type = "tabbed-pane"})
  add_tab(tabs, {"il-gui.requests"}, build_requests, player)
  add_tab(tabs, {"il-gui.requester-chests"}, build_chests, player)
  add_tab(tabs, {"il-gui.platforms"}, build_platforms, player)
  add_tab(tabs, {"il-gui.history"}, build_history, player)
  player.opened = frame
  player.set_shortcut_toggled(Constants.shortcut_name, true)
end

function Gui.close(player)
  local frame = player.gui.screen[Constants.dashboard_name]
  if frame then
    frame.destroy()
  end
  player.set_shortcut_toggled(Constants.shortcut_name, false)
end

function Gui.toggle(player)
  if player.gui.screen[Constants.dashboard_name] then
    Gui.close(player)
  else
    Gui.build(player)
  end
end

function Gui.refresh_open()
  for _, player in pairs(game.connected_players) do
    if player.gui.screen[Constants.dashboard_name] then
      Gui.build(player)
    end
  end
end

return Gui
