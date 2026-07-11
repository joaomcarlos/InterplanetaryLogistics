local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")
local Platforms = require("scripts.platforms")

local Gui = {}
local tabs_name = "il-tabs"
local platform_tabs_name = "il-platform-tabs"
local platform_enrollment_button_prefix = "il-platform-enrollment-"

local status_colors = {
  queued = {r = 1, g = 0.72, b = 0.2},
  approved = {r = 0.35, g = 0.75, b = 1},
  loading = {r = 0.5, g = 0.85, b = 1},
  delivering = {r = 0.4, g = 1, b = 0.5},
  denied = {r = 1, g = 0.35, b = 0.3},
  completed = {r = 0.45, g = 0.9, b = 0.45},
  failed = {r = 1, g = 0.25, b = 0.25},
  enrolled = {r = 0.35, g = 0.75, b = 1}
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

local function set_cell_width(element, width)
  element.style.width = width
  element.style.vertical_align = "center"
end

local function planet_cell(parent, planet_name, empty_caption)
  local cell = parent.add({type = "flow", direction = "horizontal"})
  cell.style.vertical_align = "center"
  cell.style.left_margin = 2
  cell.style.right_margin = 2
  cell.add({type = "sprite", sprite = "utility/planet", tooltip = planet_name or empty_caption})
  cell.add({type = "label", caption = planet_name or empty_caption})
  return cell
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

local function request_row(parent, request)
  local row = parent.add({type = "frame", direction = "horizontal", style = "inside_shallow_frame"})
  row.style.horizontally_stretchable = true
  row.style.height = 42
  row.style.padding = 3

  local item = row.add({type = "flow", direction = "horizontal"})
  set_cell_width(item, 220)
  item.style.vertical_align = "center"
  item.add({type = "sprite", sprite = Util.request_sprite(request), tooltip = request.item or "unknown"})
  local title = item.add({
    type = "label",
    caption = {"", "[font=default-bold]", request.amount, " x ", request.item or "unknown", "[/font]  "}
  })
  title.style.single_line = true

  local source = request.source
  planet_cell(row, source, {"il-gui.routing"}).style.width = 135
  planet_cell(row, request.destination, "unknown").style.width = 135

  local status = row.add({type = "flow", direction = "horizontal"})
  set_cell_width(status, 105)
  status_label(status, request.status)
  if request.status == "queued" then
    local remaining = math.max(0, request.auto_approve_tick - game.tick)
    status.add({type = "label", caption = " " .. Util.format_ticks(remaining)})
  elseif request.status == "denied" then
    status.add({type = "label", caption = " manual"})
  end

  local actions = row.add({type = "flow", direction = "horizontal"})
  set_cell_width(actions, 155)
  if request.status == "queued" then
    local approve = actions.add({type = "button", name = "il-approve-" .. request.id, caption = {"il-gui.approve"}, style = "confirm_button"})
    approve.style.width = 70
    local deny = actions.add({type = "button", name = "il-deny-" .. request.id, caption = {"il-gui.deny"}, style = "red_button"})
    deny.style.width = 62
  elseif request.status == "denied" then
    actions.add({type = "button", name = "il-reopen-" .. request.id, caption = {"il-gui.reopen"}})
  end
end

local function request_table_header(parent)
  local header = parent.add({type = "flow", direction = "horizontal"})
  header.style.height = 24
  header.style.padding = 3
  header.style.bottom_margin = 2
  local columns = {
    {caption = {"il-gui.item"}, width = 220},
    {caption = {"il-gui.from"}, width = 135},
    {caption = {"il-gui.to"}, width = 135},
    {caption = {"il-gui.status"}, width = 105},
    {caption = {"il-gui.actions"}, width = 155}
  }
  for _, column in ipairs(columns) do
    local label = header.add({type = "label", caption = column.caption})
    set_cell_width(label, column.width)
    label.style.font = "default-bold"
  end
end

local function build_requests(parent, player)
  heading(parent, {"il-gui.requests"})
  request_table_header(parent)
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
    if chest and chest.valid and chest.force and chest.force.index == player.force.index then
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
  parent.add({type = "label", caption = "Registered chests: " .. table_size(State.ensure().chests)})
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

local function platform_table_header(parent)
  local header = parent.add({type = "flow", direction = "horizontal"})
  header.style.height = 24
  header.style.padding = 2
  header.style.bottom_margin = 2
  local columns = {
    {caption = "Platform", width = 180},
    {caption = "Route", width = 365},
    {caption = "Status", width = 85},
    {caption = "", width = 105}
  }
  for _, column in ipairs(columns) do
    local label = header.add({type = "label", caption = column.caption})
    set_cell_width(label, column.width)
    label.style.font = "default-bold"
  end
end

local function build_platform_rows(parent, player, predicate, empty_caption)
  local platforms = {}
  for _, platform in pairs(player.force.platforms) do
    if platform.valid and (not predicate or predicate(platform)) then
      platforms[#platforms + 1] = platform
    end
  end
  table.sort(platforms, function(a, b)
    local a_name = string.lower(a.name or "")
    local b_name = string.lower(b.name or "")
    if a_name == b_name then
      return a.index < b.index
    end
    return a_name < b_name
  end)
  platform_table_header(parent)
  for _, platform in ipairs(platforms) do
    local row = parent.add({
      type = "frame",
      name = "il-platform-row-" .. platform.index,
      direction = "horizontal",
      style = "inside_shallow_frame"
    })
    row.style.horizontally_stretchable = true
    row.style.height = 32
    row.style.padding = 2

    local name = row.add({type = "label", caption = "[font=default-bold]" .. platform.name .. "[/font]"})
    set_cell_width(name, 180)
    name.style.single_line = true

    local route = row.add({type = "label", caption = route_text(platform)})
    set_cell_width(route, 365)
    route.style.single_line = true

    local enrolled = Platforms.is_enrolled(player.force.index, platform.index)
    local status = row.add({type = "label", name = "il-platform-status", caption = enrolled and "enrolled" or ""})
    set_cell_width(status, 85)
    status.style.font_color = status_colors.enrolled

    local button = row.add({
      type = "button",
      name = platform_enrollment_button_prefix .. platform.index,
      caption = enrolled and {"il-gui.unenroll"} or {"il-gui.enroll"}
    })
    button.style.width = 105
    button.style.height = 26
    button.style.font_color = enrolled and status_colors.enrolled or {r = 0.9, g = 0.9, b = 0.9}
    local active = State.ensure().platform_transfers[platform.index]
    if active then
      route.caption = {"", route.caption, "  Handling request #", active}
    end
  end
  if #platforms == 0 then
    parent.add({type = "label", caption = empty_caption})
  end
end

function Gui.update_platform_enrollment(player, button, enrolled)
  if not button or not button.valid then
    return
  end
  button.caption = enrolled and {"il-gui.unenroll"} or {"il-gui.enroll"}
  button.style.font_color = enrolled and status_colors.enrolled or {r = 0.9, g = 0.9, b = 0.9}

  local row = button.parent
  if row and row.valid then
    local status = row["il-platform-status"]
    if status and status.valid then
      status.caption = enrolled and "enrolled" or ""
      status.style.font_color = status_colors.enrolled
    end

    local state = State.ensure()
    local gui_tabs = state.gui_tabs[player.index] or {}
    if not enrolled and gui_tabs.main_tab_index == 3 and gui_tabs.platform_tab_index == 1 then
      row.destroy()
    end
  end
end

local function build_platforms(parent, player)
  heading(parent, {"il-gui.platforms"})
  local tabs = parent.add({type = "tabbed-pane", name = platform_tabs_name})
  add_tab(tabs, {"il-gui.enrolled-platforms"}, function(scroll, current_player)
    build_platform_rows(
      scroll,
      current_player,
      function(platform)
        return Platforms.is_enrolled(current_player.force.index, platform.index)
      end,
      {"il-gui.no-enrolled-platforms"}
    )
  end, player)
  add_tab(tabs, {"il-gui.all-platforms"}, function(scroll, current_player)
    build_platform_rows(scroll, current_player, nil, {"il-gui.no-platforms"})
  end, player)
  local state = State.ensure()
  local gui_tabs = state.gui_tabs[player.index]
  local selected_index = gui_tabs and gui_tabs.platform_tab_index or 1
  if tabs.valid and tabs.selected_tab_index then
    tabs.selected_tab_index = math.max(1, math.min(selected_index, 2))
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
      row.add({type = "sprite", sprite = Util.request_sprite(entry)})
      local text = row.add({type = "label", caption = entry.amount .. " x " .. (entry.item or "unknown") .. "  " .. (entry.source or "-") .. " -> " .. entry.destination})
      text.style.horizontally_stretchable = true
      if entry.origin then
        row.add({type = "label", caption = "Origin: " .. entry.origin})
      end
      status_label(row, entry.status)
      any = true
    end
  end
  if not any then
    parent.add({type = "label", caption = {"il-gui.no-history"}})
  end
end

function Gui.build(player)
  local state = State.ensure()
  local gui_tabs = state.gui_tabs[player.index] or {}
  local selected_tab_index = gui_tabs.main_tab_index or 1
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
  local tabs = frame.add({type = "tabbed-pane", name = tabs_name})
  add_tab(tabs, {"il-gui.requests"}, build_requests, player)
  add_tab(tabs, {"il-gui.requester-chests"}, build_chests, player)
  add_tab(tabs, {"il-gui.platforms"}, build_platforms, player)
  add_tab(tabs, {"il-gui.history"}, build_history, player)
  if tabs.valid and tabs.selected_tab_index then
    tabs.selected_tab_index = selected_tab_index
  end
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

return Gui
