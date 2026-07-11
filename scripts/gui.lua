local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")
local Platforms = require("scripts.platforms")

local Gui = {}
local dashboard_name = Constants.dashboard_name
local main_tabs_name = "il-tabs"
local fleet_tabs_name = "il-platform-tabs"
local request_tabs_name = "il-request-tabs"

local status_colors = {
  queued = {r = 1, g = 0.72, b = 0.2}, approved = {r = 0.35, g = 0.75, b = 1},
  loading = {r = 0.5, g = 0.85, b = 1}, delivering = {r = 0.4, g = 1, b = 0.5},
  denied = {r = 1, g = 0.35, b = 0.3}, completed = {r = 0.45, g = 0.9, b = 0.45},
  failed = {r = 1, g = 0.25, b = 0.25}, idle = {r = 0.65, g = 0.65, b = 0.65},
  working = {r = 0.4, g = 0.85, b = 1}, returning = {r = 0.7, g = 0.8, b = 1},
  stuck = {r = 1, g = 0.25, b = 0.25}, paused = {r = 1, g = 0.72, b = 0.2}
}

local priority_names = {[-1] = {"il-gui.priority-low"}, [0] = {"il-gui.priority-normal"}, [1] = {"il-gui.priority-high"}}
local request_order = {queued = 1, approved = 2, loading = 3, delivering = 4, denied = 5}

local function layout(player)
  local resolution = player.display_resolution or {width = 1920, height = 1080}
  local scale = player.display_scale or 1
  local available_width = math.floor(resolution.width / scale) - 80
  local available_height = math.floor(resolution.height / scale) - 100
  local compact = available_width < 1120
  return {
    frame_width = math.max(960, math.min(1120, available_width)),
    frame_height = math.max(620, math.min(700, available_height)),
    list_height = math.max(390, math.min(520, available_height - 250)),
    fleet = compact and {140, 90, 95, 95, 60, 180, 245} or {170, 100, 120, 120, 75, 250, 245},
    requests = compact and {200, 170, 95, 120, 75, 235} or {245, 215, 105, 155, 85, 235},
    destinations = compact and {180, 350, 250} or {210, 420, 300},
    history = compact and {220, 210, 100, 320} or {250, 250, 110, 390}
  }
end

local function find_descendant(root, name)
  if not root or not root.valid then return nil end
  if root.name == name then return root end
  for _, child in pairs(root.children or {}) do
    local found = find_descendant(child, name)
    if found then return found end
  end
  return nil
end

local function visit_descendants(root, visitor)
  if not root or not root.valid then return end
  visitor(root)
  for _, child in pairs(root.children or {}) do visit_descendants(child, visitor) end
end

local function set_width(element, width)
  element.style.width = width
  element.style.vertical_align = "center"
end

local function add_heading(parent, caption, detail)
  local flow = parent.add({type = "flow", direction = "horizontal"})
  flow.style.vertical_align = "center"
  flow.style.bottom_margin = 6
  flow.add({type = "label", caption = caption, style = "il_section_title"})
  if detail then
    local spacer = flow.add({type = "empty-widget"})
    spacer.style.horizontally_stretchable = true
    flow.add({type = "label", caption = detail, style = "il_muted_label"})
  end
end

local function add_tab(tabs, caption, name, builder, player)
  local tab = tabs.add({type = "tab", caption = caption})
  local content = tabs.add({type = "flow", name = name, direction = "vertical", style = "il_content_flow"})
  content.style.padding = 8
  content.style.horizontally_stretchable = true
  content.style.vertically_stretchable = true
  builder(content, player)
  tabs.add_tab(tab, content)
end

local function add_scroll(parent, name, player)
  local scroll = parent.add({type = "scroll-pane", name = name, direction = "vertical", style = "il_scroll_pane"})
  scroll.style.horizontally_stretchable = true
  scroll.style.vertically_stretchable = true
  local sizes = layout(player)
  scroll.style.minimal_height = sizes.list_height
  scroll.style.maximal_height = sizes.list_height
  scroll.vertical_scroll_policy = "auto"
  scroll.horizontal_scroll_policy = "never"
  local rows = scroll.add({type = "flow", name = name .. "-rows", direction = "vertical"})
  rows.style.horizontally_stretchable = true
  return rows
end

local function add_columns(parent, columns)
  local header = parent.add({type = "flow", direction = "horizontal", style = "il_table_header_flow"})
  for _, column in ipairs(columns) do
    local label = header.add({type = "label", caption = column[1], style = "il_column_header"})
    set_width(label, column[2])
  end
end

local function add_metrics(parent, metrics)
  local flow = parent.add({type = "flow", direction = "horizontal"})
  flow.style.horizontally_stretchable = true
  flow.style.horizontal_spacing = 8
  flow.style.bottom_margin = 6
  for _, metric in ipairs(metrics) do
    local card = flow.add({type = "frame", direction = "vertical", style = "il_metric_frame"})
    card.add({type = "label", caption = tostring(metric[1]), style = "il_metric_value"})
    card.add({type = "label", caption = metric[2], style = "il_metric_caption"})
  end
end

local function platform_list(player, enrolled)
  local list = {}
  for _, platform in pairs(player.force.platforms or {}) do
    if platform.valid and Platforms.is_enrolled(player.force.index, platform.index) == enrolled then
      list[#list + 1] = platform
    end
  end
  table.sort(list, function(a, b)
    local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
    if an == bn then return a.index < b.index end
    return an < bn
  end)
  return list
end

local function permanent_route(platform)
  local route = Util.route_locations(platform)
  return #route > 0 and table.concat(route, " → ") or {"il-gui.no-route"}
end

local function platform_task(snapshot, state)
  local request = snapshot.request_id and state.requests[snapshot.request_id]
  if not request then return {"il-gui.no-task"} end
  return {"", request.amount, " × [item=", request.item, "] ", request.source or "?", " → ", request.destination or "?"}
end

local function build_platform_rows(parent, player, enrolled)
  local state = State.ensure()
  local widths = layout(player).fleet
  local platforms = platform_list(player, enrolled)
  for _, platform in ipairs(platforms) do
    local snapshot = state.platform_status[platform.index] or {status = "idle"}
    local row = parent.add({type = "frame", direction = "horizontal", style = "il_list_row"})
    row.style.horizontally_stretchable = true

    local ship = row.add({type = "label", caption = "[font=default-semibold]" .. (platform.name or "") .. "[/font]", tooltip = permanent_route(platform)})
    set_width(ship, widths[1])
    ship.style.single_line = true

    local status = row.add({type = "label", name = "il-fleet-state-" .. platform.index, caption = {"il-gui.ship-status-" .. snapshot.status}})
    set_width(status, widths[2])
    status.style.font_color = status_colors[snapshot.status] or status_colors.idle

    local location = row.add({type = "label", name = "il-fleet-location-" .. platform.index, caption = snapshot.location or {"il-gui.in-transit"}})
    set_width(location, widths[3])
    local destination = row.add({type = "label", name = "il-fleet-destination-" .. platform.index, caption = snapshot.destination or "—"})
    set_width(destination, widths[4])
    local eta = row.add({type = "label", name = "il-fleet-eta-" .. platform.index, caption = snapshot.eta and Util.format_ticks(snapshot.eta) or "—"})
    set_width(eta, widths[5])
    local task = row.add({type = "label", name = "il-fleet-task-" .. platform.index, caption = platform_task(snapshot, state), tooltip = snapshot.reason})
    set_width(task, widths[6])
    task.style.single_line = true

    local controls = row.add({type = "flow", direction = "horizontal"})
    set_width(controls, widths[7])
    local enroll = controls.add({
      type = "button", name = "il-platform-enrollment-" .. platform.index,
      caption = enrolled and {"il-gui.remove-from-fleet"} or {"il-gui.add-to-fleet"},
      tags = {il_action = "platform-enrollment", platform_index = platform.index}, style = "il_compact_button"
    })
    enroll.style.width = 105
    if enrolled then
      local pinned = Platforms.is_pinned(player.force.index, platform)
      controls.add({
        type = "button", name = "il-platform-pin-" .. platform.index,
        caption = pinned and {"il-gui.unpin"} or {"il-gui.pin"}, tooltip = {"il-gui.pin-tooltip"},
        tags = {il_action = "platform-pin", platform_index = platform.index}, style = "il_compact_button"
      }).style.width = 60
      local ready = State.get_platform_options(player.force.index, platform.index).ready_signal
      controls.add({
        type = "button", name = "il-platform-ready-" .. platform.index,
        caption = ready and {"il-gui.ready-on"} or {"il-gui.ready-off"}, tooltip = {"il-gui.ready-tooltip"},
        tags = {il_action = "platform-ready", platform_index = platform.index}, style = "il_compact_button"
      }).style.width = 75
    end
  end
  if #platforms == 0 then
    parent.add({type = "label", caption = enrolled and {"il-gui.no-delivery-platforms"} or {"il-gui.no-other-platforms"}, style = "il_empty_state"})
  end
end

local function fleet_counts(player)
  local state = State.ensure()
  local total, active, idle, attention = 0, 0, 0, 0
  for _, platform in ipairs(platform_list(player, true)) do
    total = total + 1
    local status = (state.platform_status[platform.index] or {}).status or "idle"
    if status == "idle" then idle = idle + 1
    elseif status == "stuck" or status == "paused" then attention = attention + 1
    else active = active + 1 end
  end
  return total, active, idle, attention
end

local function build_fleet_leaf(parent, player, enrolled)
  local widths = layout(player).fleet
  add_columns(parent, {
    {{"il-gui.ship"}, widths[1]}, {{"il-gui.status"}, widths[2]}, {{"il-gui.location"}, widths[3]},
    {{"il-gui.destination"}, widths[4]}, {{"il-gui.eta"}, widths[5]}, {{"il-gui.current-task"}, widths[6]}, {{"il-gui.controls"}, widths[7]}
  })
  local key = enrolled and "il-fleet-delivery" or "il-fleet-other"
  local rows = add_scroll(parent, key, player)
  build_platform_rows(rows, player, enrolled)
end

local function build_fleet(parent, player)
  add_heading(parent, {"il-gui.fleet-monitor"}, {"il-gui.fleet-subtitle"})
  local total, active, idle, attention = fleet_counts(player)
  add_metrics(parent, {
    {total, {"il-gui.metric-enrolled"}}, {active, {"il-gui.metric-active"}},
    {idle, {"il-gui.metric-idle"}}, {attention, {"il-gui.metric-attention"}}
  })
  local tabs = parent.add({type = "tabbed-pane", name = fleet_tabs_name})
  tabs.style.horizontally_stretchable = true
  local sizes = layout(player)
  tabs.style.height = sizes.list_height + 84
  add_tab(tabs, {"il-gui.delivery-fleet"}, "il-delivery-fleet-view", function(content, current_player)
    build_fleet_leaf(content, current_player, true)
  end, player)
  add_tab(tabs, {"il-gui.other-platforms"}, "il-other-platforms-view", function(content, current_player)
    build_fleet_leaf(content, current_player, false)
  end, player)
  local gui_state = State.ensure().gui_tabs[player.index] or {}
  tabs.selected_tab_index = math.max(1, math.min(gui_state.platform_tab_index or 1, 2))
end

local function request_list(player, attention)
  local requests = Util.sorted_values(State.ensure().requests, function(request)
    if request.force_index ~= player.force.index then return false end
    local needs_attention = request.status == "denied" or (request.status == "approved" and request.last_reason ~= nil)
    if attention then return needs_attention end
    return Constants.active_statuses[request.status] and request.status ~= "denied" and not needs_attention
  end)
  table.sort(requests, function(a, b)
    if (a.priority or 0) ~= (b.priority or 0) then return (a.priority or 0) > (b.priority or 0) end
    if (request_order[a.status] or 99) ~= (request_order[b.status] or 99) then
      return (request_order[a.status] or 99) < (request_order[b.status] or 99)
    end
    return a.id < b.id
  end)
  return requests
end

local function build_request_rows(parent, player, attention)
  local requests = request_list(player, attention)
  local widths = layout(player).requests
  for _, request in ipairs(requests) do
    local row = parent.add({type = "frame", direction = "horizontal", style = attention and "il_list_row_attention" or "il_list_row"})
    row.style.horizontally_stretchable = true
    local item = row.add({type = "label", caption = {"", "[item=", request.item, "] ", request.amount, " × ", request.item}})
    set_width(item, widths[1])
    item.style.single_line = true
    local route = row.add({type = "label", name = "il-request-route-" .. request.id, caption = {"", request.source or {"il-gui.routing"}, " → ", request.destination or "?"}})
    set_width(route, widths[2])
    local status = row.add({type = "label", name = "il-request-status-" .. request.id, caption = {"il-gui.request-status-" .. request.status}, tooltip = request.last_reason})
    set_width(status, widths[3])
    status.style.font_color = status_colors[request.status] or status_colors.idle
    local ship = row.add({type = "label", name = "il-request-ship-" .. request.id, caption = request.platform_name or "—"})
    set_width(ship, widths[4])
    local priority = row.add({type = "label", name = "il-request-priority-" .. request.id, caption = priority_names[request.priority or 0]})
    set_width(priority, widths[5])
    local actions = row.add({type = "flow", direction = "horizontal"})
    set_width(actions, widths[6])
    if request.status == "queued" then
      actions.add({type = "button", name = "il-approve-" .. request.id, caption = {"il-gui.approve"}, style = "confirm_button"}).style.width = 80
      actions.add({type = "button", name = "il-deny-" .. request.id, caption = {"il-gui.deny"}, style = "red_button"}).style.width = 70
    elseif request.status == "denied" then
      actions.add({type = "button", name = "il-reopen-" .. request.id, caption = {"il-gui.retry"}, style = "il_compact_button"}).style.width = 90
    else
      actions.add({type = "button", name = "il-priority-down-" .. request.id, caption = "−", tooltip = {"il-gui.priority-down"}, style = "il_compact_button"})
      actions.add({type = "button", name = "il-priority-up-" .. request.id, caption = "+", tooltip = {"il-gui.priority-up"}, style = "il_compact_button"})
    end
  end
  if #requests == 0 then
    parent.add({type = "label", caption = attention and {"il-gui.no-attention-requests"} or {"il-gui.no-active-requests"}, style = "il_empty_state"})
  end
end

local function build_request_leaf(parent, player, attention)
  local widths = layout(player).requests
  add_columns(parent, {
    {{"il-gui.item"}, widths[1]}, {{"il-gui.route"}, widths[2]}, {{"il-gui.status"}, widths[3]},
    {{"il-gui.assigned-ship"}, widths[4]}, {{"il-gui.priority"}, widths[5]}, {{"il-gui.actions"}, widths[6]}
  })
  local key = attention and "il-request-attention" or "il-request-active"
  local rows = add_scroll(parent, key, player)
  build_request_rows(rows, player, attention)
end

local function build_requests(parent, player)
  local active, attention = #request_list(player, false), #request_list(player, true)
  add_heading(parent, {"il-gui.requests"}, {"il-gui.requests-subtitle"})
  add_metrics(parent, {{active, {"il-gui.metric-active"}}, {attention, {"il-gui.metric-attention"}}})
  local tabs = parent.add({type = "tabbed-pane", name = request_tabs_name})
  tabs.style.horizontally_stretchable = true
  local sizes = layout(player)
  tabs.style.height = sizes.list_height + 84
  add_tab(tabs, {"il-gui.active-requests"}, "il-active-request-view", function(content, current_player)
    build_request_leaf(content, current_player, false)
  end, player)
  add_tab(tabs, {"il-gui.needs-attention"}, "il-attention-request-view", function(content, current_player)
    build_request_leaf(content, current_player, true)
  end, player)
  local gui_state = State.ensure().gui_tabs[player.index] or {}
  tabs.selected_tab_index = math.max(1, math.min(gui_state.request_tab_index or 1, 2))
end

local function chest_list(player)
  local list = {}
  for unit_number in pairs(State.ensure().chests) do
    local chest = game.get_entity_by_unit_number(unit_number)
    if chest and chest.valid and chest.force and chest.force.index == player.force.index then list[#list + 1] = chest end
  end
  table.sort(list, function(a, b)
    local ap, bp = Util.surface_location(a.surface), Util.surface_location(b.surface)
    if ap == bp then return a.unit_number < b.unit_number end
    return ap < bp
  end)
  return list
end

local function build_destination_rows(rows, player)
  local chests = chest_list(player)
  local widths = layout(player).destinations
  for _, chest in ipairs(chests) do
    local row = rows.add({type = "frame", direction = "horizontal", style = "il_list_row"})
    row.style.horizontally_stretchable = true
    local planet = row.add({type = "label", caption = {"", "[space-location=", Util.surface_location(chest.surface), "] ", Util.surface_location(chest.surface)}})
    set_width(planet, widths[1])
    local position = row.add({type = "label", caption = Util.gps(chest)})
    set_width(position, widths[2])
    local point = chest.get_requester_point()
    local network = row.add({type = "label", caption = point and point.logistic_network and {"il-gui.network-connected"} or {"il-gui.network-disconnected"}})
    set_width(network, widths[3])
  end
  if #chests == 0 then rows.add({type = "label", caption = {"il-gui.no-chests"}, style = "il_empty_state"}) end
end

local function build_destinations(parent, player)
  local chests = chest_list(player)
  local widths = layout(player).destinations
  add_heading(parent, {"il-gui.destinations"}, {"il-gui.destinations-subtitle"})
  add_metrics(parent, {{#chests, {"il-gui.metric-requester-chests"}}})
  add_columns(parent, {{{"il-gui.planet"}, widths[1]}, {{"il-gui.position"}, widths[2]}, {{"il-gui.logistics-network"}, widths[3]}})
  build_destination_rows(add_scroll(parent, "il-destination-list", player), player)
end

local function build_history_rows(rows, player)
  local any = false
  local state = State.ensure()
  local widths = layout(player).history
  for index = #state.history, 1, -1 do
    local entry = state.history[index]
    local request = state.requests[entry.id]
    if request and request.force_index == player.force.index then
      local row = rows.add({type = "frame", direction = "horizontal", style = "il_list_row"})
      row.style.horizontally_stretchable = true
      local item = row.add({type = "label", caption = {"", "[item=", entry.item, "] ", entry.amount, " × ", entry.item}})
      set_width(item, widths[1])
      local route = row.add({type = "label", caption = {"", entry.source or "?", " → ", entry.destination or "?"}})
      set_width(route, widths[2])
      local status = row.add({type = "label", caption = {"il-gui.request-status-" .. entry.status}})
      set_width(status, widths[3])
      status.style.font_color = status_colors[entry.status] or status_colors.idle
      local reason = row.add({type = "label", caption = entry.reason or "—"})
      set_width(reason, widths[4])
      reason.style.single_line = true
      any = true
    end
  end
  if not any then rows.add({type = "label", caption = {"il-gui.no-history"}, style = "il_empty_state"}) end
end

local function build_history(parent, player)
  local widths = layout(player).history
  add_heading(parent, {"il-gui.history"}, {"il-gui.history-subtitle"})
  add_metrics(parent, {{#State.ensure().history, {"il-gui.metric-recorded-events"}}})
  add_columns(parent, {{{"il-gui.item"}, widths[1]}, {{"il-gui.route"}, widths[2]}, {{"il-gui.status"}, widths[3]}, {{"il-gui.result"}, widths[4]}})
  build_history_rows(add_scroll(parent, "il-history-list", player), player)
end

local function capture_tabs(frame, gui_state)
  if not frame or not frame.valid then return end
  local main = find_descendant(frame, main_tabs_name)
  local fleet = find_descendant(frame, fleet_tabs_name)
  local requests = find_descendant(frame, request_tabs_name)
  if main and main.selected_tab_index then gui_state.main_tab_index = main.selected_tab_index end
  if fleet and fleet.selected_tab_index then gui_state.platform_tab_index = fleet.selected_tab_index end
  if requests and requests.selected_tab_index then gui_state.request_tab_index = requests.selected_tab_index end
end

function Gui.build(player)
  local state = State.ensure()
  local gui_state = state.gui_tabs[player.index] or {}
  state.gui_tabs[player.index] = gui_state
  local previous = player.gui.screen[dashboard_name]
  capture_tabs(previous, gui_state)
  gui_state.rebuilding = true
  if previous then previous.destroy() end

  local frame = player.gui.screen.add({type = "frame", name = dashboard_name, direction = "vertical", style = "il_dashboard_frame"})
  local sizes = layout(player)
  frame.style.width = sizes.frame_width
  frame.style.height = sizes.frame_height
  frame.auto_center = true
  local titlebar = frame.add({type = "flow", direction = "horizontal"})
  titlebar.drag_target = frame
  local title = titlebar.add({type = "label", caption = {"il-gui.title"}, style = "frame_title"})
  title.drag_target = frame
  local drag = titlebar.add({type = "empty-widget", style = "draggable_space_header"})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  titlebar.add({type = "sprite-button", name = "il-refresh", sprite = "utility/refresh", tooltip = {"il-gui.refresh"}, style = "frame_action_button"})
  titlebar.add({type = "sprite-button", name = "il-close", sprite = "utility/close", tooltip = {"il-gui.close"}, style = "frame_action_button"})

  local tabs = frame.add({type = "tabbed-pane", name = main_tabs_name})
  tabs.style.horizontally_stretchable = true
  tabs.style.height = sizes.frame_height - 56
  add_tab(tabs, {"il-gui.fleet-monitor"}, "il-fleet-view", build_fleet, player)
  add_tab(tabs, {"il-gui.requests"}, "il-request-view", build_requests, player)
  add_tab(tabs, {"il-gui.destinations"}, "il-destination-view", build_destinations, player)
  add_tab(tabs, {"il-gui.history"}, "il-history-view", build_history, player)
  tabs.selected_tab_index = math.max(1, math.min(gui_state.main_tab_index or 1, 4))
  gui_state.rebuilding = nil
  player.opened = frame
  player.set_shortcut_toggled(Constants.shortcut_name, true)
end

local function refill(frame, name, builder, player, argument)
  local rows = find_descendant(frame, name)
  if not rows then return end
  rows.clear()
  builder(rows, player, argument)
end

function Gui.refresh_structure(player)
  local frame = player.gui.screen[dashboard_name]
  if not frame or not frame.valid then return end
  refill(frame, "il-fleet-delivery-rows", build_platform_rows, player, true)
  refill(frame, "il-fleet-other-rows", build_platform_rows, player, false)
  refill(frame, "il-request-active-rows", build_request_rows, player, false)
  refill(frame, "il-request-attention-rows", build_request_rows, player, true)
  refill(frame, "il-destination-list-rows", build_destination_rows, player)
  refill(frame, "il-history-list-rows", build_history_rows, player)
  Gui.refresh_player(player)
end

function Gui.refresh_player(player)
  local frame = player.gui.screen[dashboard_name]
  if not frame or not frame.valid then return end
  local state = State.ensure()
  visit_descendants(frame, function(element)
    local id = tonumber(string.match(element.name or "", "^il%-fleet%-state%-(%d+)$"))
    if id then
      local snapshot = state.platform_status[id] or {status = "idle"}
      element.caption = {"il-gui.ship-status-" .. snapshot.status}
      element.style.font_color = status_colors[snapshot.status] or status_colors.idle
      return
    end
    id = tonumber(string.match(element.name or "", "^il%-fleet%-location%-(%d+)$"))
    if id then element.caption = (state.platform_status[id] or {}).location or {"il-gui.in-transit"}; return end
    id = tonumber(string.match(element.name or "", "^il%-fleet%-destination%-(%d+)$"))
    if id then element.caption = (state.platform_status[id] or {}).destination or "—"; return end
    id = tonumber(string.match(element.name or "", "^il%-fleet%-eta%-(%d+)$"))
    if id then local eta = (state.platform_status[id] or {}).eta; element.caption = eta and Util.format_ticks(eta) or "—"; return end
    id = tonumber(string.match(element.name or "", "^il%-fleet%-task%-(%d+)$"))
    if id then element.caption = platform_task(state.platform_status[id] or {}, state); return end
    id = tonumber(string.match(element.name or "", "^il%-request%-status%-(%d+)$"))
    if id and state.requests[id] then element.caption = {"il-gui.request-status-" .. state.requests[id].status}; return end
    id = tonumber(string.match(element.name or "", "^il%-request%-route%-(%d+)$"))
    if id and state.requests[id] then local r = state.requests[id]; element.caption = {"", r.source or {"il-gui.routing"}, " → ", r.destination or "?"}; return end
    id = tonumber(string.match(element.name or "", "^il%-request%-ship%-(%d+)$"))
    if id and state.requests[id] then element.caption = state.requests[id].platform_name or "—"; return end
    id = tonumber(string.match(element.name or "", "^il%-request%-priority%-(%d+)$"))
    if id and state.requests[id] then element.caption = priority_names[state.requests[id].priority or 0] end
  end)
end

function Gui.refresh_open()
  for _, player in pairs(game.connected_players or {}) do Gui.refresh_player(player) end
end

function Gui.start_refresh()
  local state = State.ensure()
  local players = {}
  for _, player in pairs(game.connected_players or {}) do
    if player.valid then players[#players + 1] = player.index end
  end
  table.sort(players)
  state.gui_refresh_job = {players = players, index = 1}
  return true
end

function Gui.refresh_active()
  return State.ensure().gui_refresh_job ~= nil
end

function Gui.step_refresh(budget)
  local state = State.ensure()
  local job = state.gui_refresh_job
  if not job then return true end
  budget = math.max(1, budget or Constants.gui_work_per_tick)
  local processed = 0
  while processed < budget do
    local player_index = job.players[job.index]
    if not player_index then
      state.gui_refresh_job = nil
      break
    end
    local player = game.get_player(player_index)
    if player and player.valid then Gui.refresh_player(player) end
    job.index = job.index + 1
    processed = processed + 1
  end
  return state.gui_refresh_job == nil
end

function Gui.close(player)
  local frame = player.gui.screen[dashboard_name]
  if frame then frame.destroy() end
  player.set_shortcut_toggled(Constants.shortcut_name, false)
end

function Gui.toggle(player)
  if player.gui.screen[dashboard_name] then Gui.close(player) else Gui.build(player) end
end

return Gui
