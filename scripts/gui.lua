local Constants = require("scripts.constants")
local State = require("scripts.state")
local Util = require("scripts.util")
local Platforms = require("scripts.platforms")

local Gui = {}
local dashboard_name = Constants.dashboard_name
local view_names = {fleet = "il-content-fleet", requests = "il-content-requests", destinations = "il-content-destinations", history = "il-content-history"}
local view_order = {"fleet", "requests", "destinations", "history"}

local status_colors = {
  queued = {r = 1, g = 0.72, b = 0.20}, approved = {r = 0.30, g = 0.72, b = 1},
  loading = {r = 0.30, g = 0.72, b = 1}, delivering = {r = 0.45, g = 0.90, b = 0.22},
  denied = {r = 1, g = 0.42, b = 0.24}, completed = {r = 0.45, g = 0.90, b = 0.22},
  failed = {r = 1, g = 0.28, b = 0.24}, cancelled = {r = 0.62, g = 0.62, b = 0.62},
  idle = {r = 0.66, g = 0.66, b = 0.66}, working = {r = 0.30, g = 0.72, b = 1},
  returning = {r = 1, g = 0.66, b = 0.12}, stuck = {r = 1, g = 0.28, b = 0.24},
  paused = {r = 1, g = 0.72, b = 0.20}
}

local accent_colors = {
  blue = {r = 0.30, g = 0.72, b = 1}, green = {r = 0.45, g = 0.90, b = 0.22},
  orange = {r = 1, g = 0.66, b = 0.12}, red = {r = 1, g = 0.28, b = 0.24},
  muted = {r = 0.66, g = 0.66, b = 0.66}
}

local priority_names = {[-1] = {"il-gui.priority-low"}, [0] = {"il-gui.priority-normal"}, [1] = {"il-gui.priority-high"}}
local request_order = {queued = 1, approved = 2, loading = 3, delivering = 4, denied = 5}

local function layout(player)
  local resolution = player.display_resolution or {width = 1920, height = 1080}
  local scale = player.display_scale or 1
  local available_width = math.floor(resolution.width / scale) - 32
  local available_height = math.floor(resolution.height / scale) - 32
  local frame_width = math.max(960, math.min(1500, available_width))
  local frame_height = math.max(560, math.min(840, available_height))
  local navigation_width = 188
  local content_width = frame_width - navigation_width - 24
  local compact = content_width < 1000
  local detail_width = compact and 280 or 340
  local request_list_width = content_width - detail_width - 10
  return {
    frame_width = frame_width,
    frame_height = frame_height,
    navigation_width = navigation_width,
    content_width = content_width,
    request_list_width = request_list_width,
    detail_width = detail_width,
    compact = compact,
    list_height = math.max(330, frame_height - 235),
    fleet = compact and {125, 80, 85, 85, 55, 165, 108} or {180, 105, 125, 125, 75, 300, 116},
    requests = compact and {135, 105, 75, 0, 0, 108} or {190, 160, 90, 115, 70, 160},
    destinations = compact and {200, 280, 220} or {270, 420, 360},
    history = compact and {180, 170, 90, 250} or {250, 250, 110, 430}
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

local function item_localised_name(name)
  local prototype = prototypes and prototypes.item and prototypes.item[name]
  return prototype and prototype.localised_name or name
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

local function add_scroll(parent, name, player)
  local scroll = parent.add({type = "scroll-pane", name = name, direction = "vertical", style = "il_scroll_pane"})
  scroll.style.horizontally_stretchable = true
  local sizes = layout(player)
  scroll.style.minimal_height = sizes.list_height
  scroll.style.maximal_height = sizes.list_height
  scroll.vertical_scroll_policy = "auto"
  scroll.horizontal_scroll_policy = "never"
  local rows = scroll.add({type = "flow", name = name .. "-rows", direction = "vertical"})
  rows.style.horizontally_stretchable = true
  return rows
end

local function add_section_label(parent, caption)
  local flow = parent.add({type = "frame", direction = "horizontal", style = "il_section_header_frame"})
  flow.add({type = "label", caption = caption, style = "il_section_title"})
end

local function add_columns(parent, columns)
  local header = parent.add({type = "frame", direction = "horizontal", style = "il_table_header_frame"})
  for _, column in ipairs(columns) do
    local label = header.add({type = "label", caption = column[1], style = "il_column_header"})
    set_width(label, column[2])
  end
end

local function add_icon_button(parent, properties)
  local button = parent.add({
    type = "sprite-button", name = properties.name, sprite = properties.sprite,
    tooltip = properties.tooltip, tags = properties.tags, style = properties.style or "il_square_tool_button"
  })
  button.style.size = properties.size or 32
  if properties.toggled ~= nil then button.toggled = properties.toggled end
  if properties.enabled ~= nil then button.enabled = properties.enabled end
  return button
end

local function add_metrics(parent, metrics)
  local flow = parent.add({type = "flow", direction = "horizontal"})
  flow.style.horizontally_stretchable = true
  flow.style.horizontal_spacing = 6
  flow.style.bottom_margin = 8
  for _, metric in ipairs(metrics) do
    local card = flow.add({type = "frame", direction = "horizontal", style = "il_metric_frame"})
    if metric.sprite then
      local icon = card.add({type = "sprite", sprite = metric.sprite})
      icon.resize_to_sprite = false
      icon.style.size = 32
      icon.style.stretch_image_to_widget_size = true
    end
    local labels = card.add({type = "flow", direction = "vertical"})
    local value = labels.add({type = "label", name = metric.name, caption = tostring(metric[1]), style = "il_metric_value"})
    value.style.font_color = metric.color or accent_colors.muted
    labels.add({type = "label", caption = metric[2], style = "il_metric_caption"})
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
    if enrolled then ship.style.font_color = accent_colors.blue end

    local status = row.add({type = "label", name = "il-fleet-state-" .. platform.index, caption = {"il-gui.ship-status-" .. snapshot.status}})
    set_width(status, widths[2])
    status.style.font_color = status_colors[snapshot.status] or status_colors.idle

    local location = row.add({type = "label", name = "il-fleet-location-" .. platform.index, caption = snapshot.location or {"il-gui.in-transit"}})
    set_width(location, widths[3])
    local destination = row.add({type = "label", name = "il-fleet-destination-" .. platform.index, caption = snapshot.destination or "—"})
    set_width(destination, widths[4])
    local eta = row.add({type = "label", name = "il-fleet-eta-" .. platform.index, caption = snapshot.eta and Util.format_ticks(snapshot.eta) or "—"})
    set_width(eta, widths[5])
    if snapshot.eta then eta.style.font_color = accent_colors.green end
    local task = row.add({type = "label", name = "il-fleet-task-" .. platform.index, caption = platform_task(snapshot, state), tooltip = snapshot.reason})
    set_width(task, widths[6])
    task.style.single_line = true

    local controls = row.add({type = "flow", direction = "horizontal"})
    set_width(controls, widths[7])
    controls.style.horizontal_spacing = 4
    add_icon_button(controls, {
      name = "il-platform-enrollment-" .. platform.index,
      sprite = enrolled and "utility/trash" or "utility/add",
      tooltip = enrolled and {"il-gui.remove-from-fleet"} or {"il-gui.add-to-fleet"},
      style = enrolled and "il_square_tool_button_red" or "il_square_tool_button_green",
      tags = {il_action = "platform-enrollment", platform_index = platform.index}
    })
    if enrolled then
      local pinned = Platforms.is_pinned(player.force.index, platform)
      add_icon_button(controls, {
        name = "il-platform-pin-" .. platform.index, sprite = "utility/pin_center",
        tooltip = pinned and {"il-gui.unpin"} or {"il-gui.pin-tooltip"}, toggled = pinned,
        tags = {il_action = "platform-pin", platform_index = platform.index}
      })
      local ready = State.get_platform_options(player.force.index, platform.index).ready_signal
      add_icon_button(controls, {
        name = "il-platform-ready-" .. platform.index,
        sprite = ready and "utility/check_mark_green" or "utility/check_mark",
        tooltip = {"il-gui.ready-tooltip"}, toggled = ready,
        tags = {il_action = "platform-ready", platform_index = platform.index}
      })
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

local function build_fleet(parent, player)
  add_heading(parent, {"il-gui.fleet-monitor"}, {"il-gui.fleet-subtitle"})
  local total, active, idle, attention = fleet_counts(player)
  add_metrics(parent, {
    {total, {"il-gui.metric-enrolled"}, name = "il-metric-fleet-total", sprite = "utility/starmap_platform_stopped", color = accent_colors.blue},
    {active, {"il-gui.metric-active"}, name = "il-metric-fleet-active", sprite = "utility/play", color = accent_colors.green},
    {idle, {"il-gui.metric-idle"}, name = "il-metric-fleet-idle", sprite = "utility/check_mark", color = accent_colors.muted},
    {attention, {"il-gui.metric-attention"}, name = "il-metric-fleet-attention", sprite = "utility/warning", color = accent_colors.orange}
  })
  local widths = layout(player).fleet
  add_columns(parent, {
    {{"il-gui.ship"}, widths[1]}, {{"il-gui.status"}, widths[2]}, {{"il-gui.location"}, widths[3]},
    {{"il-gui.destination"}, widths[4]}, {{"il-gui.eta"}, widths[5]}, {{"il-gui.current-task"}, widths[6]}, {{"il-gui.controls"}, widths[7]}
  })
  local scroll = parent.add({type = "scroll-pane", name = "il-fleet-list", direction = "vertical", style = "il_scroll_pane"})
  scroll.style.horizontally_stretchable = true
  local sizes = layout(player)
  scroll.style.minimal_height = sizes.list_height
  scroll.style.maximal_height = sizes.list_height
  scroll.vertical_scroll_policy = "auto"
  scroll.horizontal_scroll_policy = "never"
  local rows = scroll.add({type = "flow", name = "il-fleet-list-rows", direction = "vertical"})
  rows.style.horizontally_stretchable = true
  add_section_label(rows, {"il-gui.delivery-fleet"})
  local delivery = rows.add({type = "flow", name = "il-fleet-delivery-rows", direction = "vertical"})
  delivery.style.horizontally_stretchable = true
  build_platform_rows(delivery, player, true)
  add_section_label(rows, {"il-gui.other-platforms"})
  local other = rows.add({type = "flow", name = "il-fleet-other-rows", direction = "vertical"})
  other.style.horizontally_stretchable = true
  build_platform_rows(other, player, false)
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
  local selected_id = (State.ensure().gui_tabs[player.index] or {}).selected_request_id
  for _, request in ipairs(requests) do
    local row = parent.add({type = "frame", direction = "horizontal", style = attention and "il_list_row_attention" or "il_list_row"})
    row.style.horizontally_stretchable = true
    local item = row.add({type = "label", name = "il-request-item-" .. request.id, caption = {"", "[item=", request.item, "] ", request.amount, " × ", item_localised_name(request.item)}})
    set_width(item, widths[1])
    item.style.single_line = true
    if request.id == selected_id then item.style.font_color = accent_colors.orange end
    local route = row.add({type = "label", name = "il-request-route-" .. request.id, caption = {"", request.source or {"il-gui.routing"}, " → ", request.destination or "?"}})
    set_width(route, widths[2])
    local status = row.add({type = "label", name = "il-request-status-" .. request.id, caption = {"il-gui.request-status-" .. request.status}, tooltip = request.last_reason})
    set_width(status, widths[3])
    status.style.font_color = status_colors[request.status] or status_colors.idle
    if widths[4] > 0 then
      local ship = row.add({type = "label", name = "il-request-ship-" .. request.id, caption = request.platform_name or "—"})
      set_width(ship, widths[4])
      if request.platform_name then ship.style.font_color = accent_colors.blue end
    end
    if widths[5] > 0 then
      local priority = row.add({type = "label", name = "il-request-priority-" .. request.id, caption = priority_names[request.priority or 0]})
      set_width(priority, widths[5])
      if (request.priority or 0) > 0 then priority.style.font_color = accent_colors.orange
      elseif (request.priority or 0) < 0 then priority.style.font_color = accent_colors.muted end
    end
    local actions = row.add({type = "flow", direction = "horizontal"})
    set_width(actions, widths[6])
    actions.style.horizontal_spacing = 3
    if request.status == "queued" then
      add_icon_button(actions, {name = "il-approve-" .. request.id, sprite = "utility/check_mark", tooltip = {"il-gui.approve"}, style = "il_square_tool_button_green"})
      add_icon_button(actions, {name = "il-deny-" .. request.id, sprite = "utility/close", tooltip = {"il-gui.deny"}, style = "il_square_tool_button_red"})
    elseif request.status == "denied" then
      add_icon_button(actions, {name = "il-reopen-" .. request.id, sprite = "utility/reset", tooltip = {"il-gui.retry"}})
    else
      add_icon_button(actions, {name = "il-priority-down-" .. request.id, sprite = "utility/speed_down", tooltip = {"il-gui.priority-down"}})
      add_icon_button(actions, {name = "il-priority-up-" .. request.id, sprite = "utility/speed_up", tooltip = {"il-gui.priority-up"}})
    end
    add_icon_button(actions, {
      name = "il-request-select-" .. request.id, sprite = "utility/search",
      tooltip = {"il-gui.view"}, toggled = request.id == selected_id
    })
  end
  if #requests == 0 then
    parent.add({type = "label", caption = attention and {"il-gui.no-attention-requests"} or {"il-gui.no-active-requests"}, style = "il_empty_state"})
  end
end

local function request_detail_request(player)
  local state = State.ensure()
  local gui_state = state.gui_tabs[player.index] or {}
  state.gui_tabs[player.index] = gui_state
  local request = gui_state.selected_request_id and state.requests[gui_state.selected_request_id]
  if request and request.force_index == player.force.index then return request end
  local requests = request_list(player, true)
  if #requests == 0 then requests = request_list(player, false) end
  request = requests[1]
  gui_state.selected_request_id = request and request.id or nil
  return request
end

local function add_detail_line(parent, label, value, color)
  local row = parent.add({type = "flow", direction = "horizontal"})
  row.style.horizontally_stretchable = true
  row.style.bottom_margin = 3
  local key = row.add({type = "label", caption = label, style = "il_detail_label"})
  key.style.width = 92
  local value_label = row.add({type = "label", caption = value or "-", style = "il_detail_value"})
  value_label.style.single_line = true
  if color then value_label.style.font_color = color end
end

local function add_timeline(parent, request)
  local events = {
    {"il-gui.timeline-created", request.created_tick, "utility/status_blue"},
    {"il-gui.timeline-approved", request.approved_tick, "utility/status_working"},
    {"il-gui.timeline-dispatched", request.dispatched_tick, "utility/status_blue"},
    {"il-gui.timeline-finished", request.completed_tick, "utility/status_working"}
  }
  local count = 0
  for _, event in ipairs(events) do
    if event[2] then
      local row = parent.add({type = "flow", direction = "horizontal"})
      row.style.horizontally_stretchable = true
      row.style.vertical_align = "center"
      row.style.bottom_margin = 2
      local dot = row.add({type = "sprite", sprite = event[3]})
      dot.resize_to_sprite = false
      dot.style.size = 14
      dot.style.stretch_image_to_widget_size = true
      row.add({type = "label", caption = {event[1]}, style = "il_detail_value"})
      local spacer = row.add({type = "empty-widget"})
      spacer.style.horizontally_stretchable = true
      local age = math.max(0, game.tick - event[2])
      row.add({type = "label", caption = Util.format_ticks(age), style = "il_muted_label"})
      count = count + 1
    end
  end
  if count == 0 then
    parent.add({type = "label", caption = {"il-gui.no-timeline"}, style = "il_empty_state"})
  end
end

local function build_request_detail(parent, player)
  local request = request_detail_request(player)
  add_heading(parent, {"il-gui.request-details"})
  if not request then
    parent.add({type = "label", caption = {"il-gui.no-request-selected"}, style = "il_empty_state"})
    return
  end
  local item_row = parent.add({type = "flow", direction = "horizontal"})
  item_row.style.vertical_align = "center"
  item_row.style.bottom_margin = 8
  local item_icon = item_row.add({type = "sprite", sprite = "item/" .. request.item})
  item_icon.resize_to_sprite = false
  item_icon.style.size = 42
  item_icon.style.stretch_image_to_widget_size = true
  local item_labels = item_row.add({type = "flow", direction = "vertical"})
  item_labels.add({type = "label", caption = item_localised_name(request.item), style = "il_detail_title"})
  item_labels.add({type = "label", caption = tostring(request.amount), style = "il_muted_label"})
  parent.add({type = "line", direction = "horizontal"})
  local color = status_colors[request.status] or status_colors.idle
  add_detail_line(parent, {"il-gui.detail-status"}, {"il-gui.request-status-" .. request.status}, color)
  add_detail_line(parent, {"il-gui.detail-destination"}, request.destination)
  add_detail_line(parent, {"il-gui.detail-platform"}, request.platform_name)

  add_section_label(parent, {"il-gui.why-delayed"})
  local reason = parent.add({type = "label", caption = request.last_reason or {"il-gui.no-delay"}, style = "il_detail_body"})
  reason.style.maximal_width = layout(player).detail_width - 24

  add_section_label(parent, {"il-gui.route-overview"})
  local route = parent.add({type = "frame", direction = "vertical", style = "il_detail_section_frame"})
  route.style.horizontally_stretchable = true
  add_detail_line(route, {"il-gui.detail-source"}, request.source or {"il-gui.routing"})
  add_detail_line(route, {"il-gui.detail-route"}, {"", request.source or "?", " -> ", request.destination or "?"})
  add_detail_line(route, {"il-gui.detail-eta"}, request.eta_tick and Util.format_ticks(math.max(0, request.eta_tick - game.tick)) or "-")

  add_section_label(parent, {"il-gui.timeline"})
  add_timeline(parent, request)
  local actions = parent.add({type = "flow", direction = "horizontal"})
  actions.style.horizontally_stretchable = true
  actions.style.horizontal_spacing = 6
  actions.style.top_margin = 8
  if request.status == "queued" then
    local approve = actions.add({type = "button", name = "il-approve-" .. request.id, caption = {"il-gui.approve"}, style = "confirm_button"})
    approve.style.horizontally_stretchable = true
    local deny = actions.add({type = "button", name = "il-deny-" .. request.id, caption = {"il-gui.deny"}, style = "red_button"})
    deny.style.horizontally_stretchable = true
  elseif request.status == "denied" then
    local retry = actions.add({type = "button", name = "il-reopen-" .. request.id, caption = {"il-gui.retry"}, style = "confirm_button"})
    retry.style.horizontally_stretchable = true
  end
end

local function build_requests(parent, player)
  request_detail_request(player)
  local active, attention = #request_list(player, false), #request_list(player, true)
  add_heading(parent, {"il-gui.requests"}, {"il-gui.requests-subtitle"})
  add_metrics(parent, {
    {active, {"il-gui.metric-active"}, name = "il-metric-request-active", sprite = "utility/check_mark_green", color = accent_colors.green},
    {attention, {"il-gui.metric-attention"}, name = "il-metric-request-attention", sprite = "utility/warning", color = accent_colors.orange}
  })
  local body = parent.add({type = "flow", direction = "horizontal"})
  body.style.horizontally_stretchable = true
  body.style.horizontal_spacing = 8
  local list = body.add({type = "flow", name = "il-request-list-panel", direction = "vertical"})
  local sizes = layout(player)
  list.style.width = sizes.request_list_width
  list.style.horizontally_stretchable = true
  local widths = sizes.requests
  local columns = {
    {{"il-gui.item"}, widths[1]}, {{"il-gui.route"}, widths[2]}, {{"il-gui.status"}, widths[3]}
  }
  if widths[4] > 0 then columns[#columns + 1] = {{"il-gui.assigned-ship"}, widths[4]} end
  if widths[5] > 0 then columns[#columns + 1] = {{"il-gui.priority"}, widths[5]} end
  columns[#columns + 1] = {{"il-gui.actions"}, widths[6]}
  add_columns(list, columns)
  local scroll = list.add({type = "scroll-pane", name = "il-request-list", direction = "vertical", style = "il_scroll_pane"})
  scroll.style.horizontally_stretchable = true
  scroll.style.minimal_height = sizes.list_height
  scroll.style.maximal_height = sizes.list_height
  scroll.vertical_scroll_policy = "auto"
  scroll.horizontal_scroll_policy = "never"
  local rows = scroll.add({type = "flow", name = "il-request-list-rows", direction = "vertical"})
  rows.style.horizontally_stretchable = true
  add_section_label(rows, {"il-gui.active-requests"})
  local active_rows = rows.add({type = "flow", name = "il-request-active-rows", direction = "vertical"})
  active_rows.style.horizontally_stretchable = true
  build_request_rows(active_rows, player, false)
  add_section_label(rows, {"il-gui.needs-attention"})
  local attention_rows = rows.add({type = "flow", name = "il-request-attention-rows", direction = "vertical"})
  attention_rows.style.horizontally_stretchable = true
  build_request_rows(attention_rows, player, true)

  local detail = body.add({type = "frame", name = "il-request-detail", direction = "vertical", style = "il_detail_frame"})
  detail.style.width = sizes.detail_width
  detail.style.minimal_height = sizes.list_height + 34
  detail.style.maximal_height = sizes.list_height + 34
  build_request_detail(detail, player)
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
    planet.style.font_color = accent_colors.blue
    local position = row.add({type = "label", caption = Util.gps(chest)})
    set_width(position, widths[2])
    local point = chest.get_requester_point()
    local connected = point and point.logistic_network
    local network = row.add({type = "label", caption = connected and {"il-gui.network-connected"} or {"il-gui.network-disconnected"}})
    set_width(network, widths[3])
    network.style.font_color = connected and accent_colors.green or accent_colors.red
  end
  if #chests == 0 then rows.add({type = "label", caption = {"il-gui.no-chests"}, style = "il_empty_state"}) end
end

local function build_destinations(parent, player)
  local chests = chest_list(player)
  local widths = layout(player).destinations
  add_heading(parent, {"il-gui.destinations"}, {"il-gui.destinations-subtitle"})
  add_metrics(parent, {{#chests, {"il-gui.metric-requester-chests"}, name = "il-metric-destinations", sprite = "utility/reference_point", color = accent_colors.orange}})
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
      local item = row.add({type = "label", caption = {"", "[item=", entry.item, "] ", entry.amount, " × ", item_localised_name(entry.item)}})
      set_width(item, widths[1])
      item.style.single_line = true
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

local function history_count(player)
  local state = State.ensure()
  local count = 0
  for _, entry in ipairs(state.history) do
    local request = state.requests[entry.id]
    if request and request.force_index == player.force.index then count = count + 1 end
  end
  return count
end

local function build_history(parent, player)
  local widths = layout(player).history
  add_heading(parent, {"il-gui.history"}, {"il-gui.history-subtitle"})
  add_metrics(parent, {{history_count(player), {"il-gui.metric-recorded-events"}, name = "il-metric-history", sprite = "utility/clock", color = accent_colors.blue}})
  add_columns(parent, {{{"il-gui.item"}, widths[1]}, {{"il-gui.route"}, widths[2]}, {{"il-gui.status"}, widths[3]}, {{"il-gui.result"}, widths[4]}})
  build_history_rows(add_scroll(parent, "il-history-list", player), player)
end

local function current_view(gui_state)
  local view = gui_state.view
  if view_names[view] then return view end
  local legacy = gui_state.main_tab_index
  return ({[1] = "fleet", [2] = "requests", [3] = "destinations", [4] = "history"})[legacy or 1] or "fleet"
end

local function capture_view(frame, gui_state)
  if not frame or not frame.valid then return end
  for view, name in pairs(view_names) do
    local element = find_descendant(frame, name)
    if element and element.visible then gui_state.view = view; break end
  end
end

local function add_navigation(parent, player, selected)
  local nav = parent.add({type = "frame", name = "il-navigation", direction = "vertical", style = "il_navigation_frame"})
  nav.style.width = layout(player).navigation_width
  local entries = {
    {"fleet", {"il-gui.fleet-monitor"}, "utility/starmap_platform_stopped"},
    {"requests", {"il-gui.requests"}, "utility/list_view"},
    {"destinations", {"il-gui.destinations"}, "utility/reference_point"},
    {"history", {"il-gui.history"}, "utility/clock"}
  }
  for _, entry in ipairs(entries) do
    local button = nav.add({
      type = "button", name = "il-nav-" .. entry[1],
      caption = {"", "[img=" .. entry[3] .. "]  ", entry[2]},
      tooltip = entry[2], style = "il_nav_button", auto_toggle = false, toggled = entry[1] == selected
    })
    button.style.width = layout(player).navigation_width - 12
    button.style.height = 48
  end
  local spacer = nav.add({type = "empty-widget"})
  spacer.style.vertically_stretchable = true
  local status = nav.add({type = "frame", direction = "vertical", style = "il_status_frame"})
  local status_title = status.add({type = "flow", direction = "horizontal"})
  status_title.style.vertical_align = "center"
  local indicator = status_title.add({type = "sprite", sprite = "utility/status_working"})
  indicator.resize_to_sprite = false
  indicator.style.size = 16
  indicator.style.stretch_image_to_widget_size = true
  status_title.add({type = "label", caption = {"il-gui.system-status"}, style = "il_section_title"})
  local detail = status.add({type = "label", caption = {"il-gui.system-status-detail"}, style = "il_muted_label"})
  detail.style.left_margin = 22
end

local function add_view(parent, name, player, builder, selected)
  local view = parent.add({type = "flow", name = view_names[name], direction = "vertical", style = "il_content_flow"})
  view.style.padding = 8
  view.style.horizontally_stretchable = true
  view.visible = name == selected
  builder(view, player)
end

function Gui.build(player)
  local state = State.ensure()
  local gui_state = state.gui_tabs[player.index] or {}
  state.gui_tabs[player.index] = gui_state
  local previous = player.gui.screen[dashboard_name]
  capture_view(previous, gui_state)
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
  drag.style.height = 32
  drag.drag_target = frame
  local refresh = titlebar.add({type = "sprite-button", name = "il-refresh", sprite = "utility/refresh", tooltip = {"il-gui.refresh"}, style = "frame_action_button"})
  refresh.style.size = 32
  local close = titlebar.add({type = "sprite-button", name = "il-close", sprite = "utility/close", tooltip = {"il-gui.close"}, style = "frame_action_button"})
  close.style.size = 32

  local selected = current_view(gui_state)
  local body = frame.add({type = "flow", name = "il-dashboard-body", direction = "horizontal"})
  body.style.horizontally_stretchable = true
  body.style.vertically_stretchable = true
  add_navigation(body, player, selected)
  local views = body.add({type = "frame", name = "il-view-container", direction = "vertical", style = "il_main_content_frame"})
  views.style.horizontally_stretchable = true
  views.style.vertically_stretchable = true
  add_view(views, "fleet", player, build_fleet, selected)
  add_view(views, "requests", player, build_requests, selected)
  add_view(views, "destinations", player, build_destinations, selected)
  add_view(views, "history", player, build_history, selected)
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

local function set_metric(frame, name, value)
  local element = find_descendant(frame, name)
  if element then element.caption = tostring(value) end
end

local function refresh_summaries(frame, player)
  local total, active, idle, attention = fleet_counts(player)
  set_metric(frame, "il-metric-fleet-total", total)
  set_metric(frame, "il-metric-fleet-active", active)
  set_metric(frame, "il-metric-fleet-idle", idle)
  set_metric(frame, "il-metric-fleet-attention", attention)
  set_metric(frame, "il-metric-request-active", #request_list(player, false))
  set_metric(frame, "il-metric-request-attention", #request_list(player, true))
  set_metric(frame, "il-metric-destinations", #chest_list(player))
  set_metric(frame, "il-metric-history", history_count(player))
end

local function refresh_request_detail(frame, player)
  local detail = find_descendant(frame, "il-request-detail")
  if detail then
    detail.clear()
    build_request_detail(detail, player)
  end
end

function Gui.refresh_fleet_structure(player)
  local frame = player.gui.screen[dashboard_name]
  if not frame or not frame.valid then return end
  refill(frame, "il-fleet-delivery-rows", build_platform_rows, player, true)
  refill(frame, "il-fleet-other-rows", build_platform_rows, player, false)
  refresh_summaries(frame, player)
  Gui.refresh_player(player)
end

function Gui.refresh_request_structure(player)
  local frame = player.gui.screen[dashboard_name]
  if not frame or not frame.valid then return end
  refill(frame, "il-request-active-rows", build_request_rows, player, false)
  refill(frame, "il-request-attention-rows", build_request_rows, player, true)
  refresh_summaries(frame, player)
  refresh_request_detail(frame, player)
  Gui.refresh_player(player)
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
  refresh_summaries(frame, player)
  refresh_request_detail(frame, player)
  Gui.refresh_player(player)
end

function Gui.set_view(player, view)
  if not view_names[view] then return end
  local frame = player.gui.screen[dashboard_name]
  if not frame or not frame.valid then return end
  local state = State.ensure()
  local gui_state = state.gui_tabs[player.index] or {}
  state.gui_tabs[player.index] = gui_state
  gui_state.view = view
  for name, element_name in pairs(view_names) do
    local element = find_descendant(frame, element_name)
    if element then element.visible = name == view end
  end
  local nav = find_descendant(frame, "il-navigation")
  if nav then
    for _, name in ipairs(view_order) do
      local button = nav["il-nav-" .. name]
      if button then
        button.toggled = name == view
      end
    end
  end
end

function Gui.select_request(player, request_id)
  local request = State.ensure().requests[request_id]
  if not request or request.force_index ~= player.force.index then return end
  local state = State.ensure()
  local gui_state = state.gui_tabs[player.index] or {}
  state.gui_tabs[player.index] = gui_state
  gui_state.selected_request_id = request_id
  Gui.set_view(player, "requests")
  local frame = player.gui.screen[dashboard_name]
  if not frame or not frame.valid then return end
  visit_descendants(frame, function(element)
    local item_id = tonumber(string.match(element.name or "", "^il%-request%-item%-(%d+)$"))
    if item_id then
      element.style.font_color = item_id == request_id and accent_colors.orange or {r = 1, g = 1, b = 1}
      return
    end
    local button_id = tonumber(string.match(element.name or "", "^il%-request%-select%-(%d+)$"))
    if button_id then element.toggled = button_id == request_id end
  end)
  local detail = find_descendant(frame, "il-request-detail")
  if detail then
    detail.clear()
    build_request_detail(detail, player)
  end
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
    if id then
      local eta = (state.platform_status[id] or {}).eta
      element.caption = eta and Util.format_ticks(eta) or "—"
      element.style.font_color = eta and accent_colors.green or accent_colors.muted
      return
    end
    id = tonumber(string.match(element.name or "", "^il%-fleet%-task%-(%d+)$"))
    if id then element.caption = platform_task(state.platform_status[id] or {}, state); return end
    id = tonumber(string.match(element.name or "", "^il%-platform%-pin%-(%d+)$"))
    if id then
      local platform = Util.get_platform(player.force, id)
      local pinned = platform and Platforms.is_pinned(player.force.index, platform) or false
      element.toggled = pinned
      element.tooltip = pinned and {"il-gui.unpin"} or {"il-gui.pin-tooltip"}
      return
    end
    id = tonumber(string.match(element.name or "", "^il%-platform%-ready%-(%d+)$"))
    if id then
      local ready = State.get_platform_options(player.force.index, id).ready_signal
      element.toggled = ready
      element.sprite = ready and "utility/check_mark_green" or "utility/check_mark"
      return
    end
    id = tonumber(string.match(element.name or "", "^il%-request%-status%-(%d+)$"))
    if id and state.requests[id] then
      element.caption = {"il-gui.request-status-" .. state.requests[id].status}
      element.style.font_color = status_colors[state.requests[id].status] or status_colors.idle
      return
    end
    id = tonumber(string.match(element.name or "", "^il%-request%-route%-(%d+)$"))
    if id and state.requests[id] then local r = state.requests[id]; element.caption = {"", r.source or {"il-gui.routing"}, " → ", r.destination or "?"}; return end
    id = tonumber(string.match(element.name or "", "^il%-request%-ship%-(%d+)$"))
    if id and state.requests[id] then
      element.caption = state.requests[id].platform_name or "—"
      element.style.font_color = state.requests[id].platform_name and accent_colors.blue or accent_colors.muted
      return
    end
    id = tonumber(string.match(element.name or "", "^il%-request%-priority%-(%d+)$"))
    if id and state.requests[id] then
      local priority = state.requests[id].priority or 0
      element.caption = priority_names[priority]
      element.style.font_color = priority > 0 and accent_colors.orange or (priority < 0 and accent_colors.muted or {r = 1, g = 1, b = 1})
    end
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
