local UIComponents = {}

local Models = BetterConsole and BetterConsole.Models
local Constants = Models and Models.Constants
local TimeConstants = Constants and Constants.Time
local CategoryConstants = Constants and Constants.Categories
local FiltersConstants = Constants and Constants.Filters
local FilterStates = FiltersConstants and FiltersConstants.States
local GeneralConstants = Constants and Constants.General

local L = function(key, ...)
    if BetterConsole.Localization then
        return BetterConsole.Localization.get(key, ...)
    end
    return key
end

-- MenuBar module providing top-level menu interface for BetterConsole window
-- Handles File, Settings, and View menu sections with user preferences
do
local M = {}

local TooltipManager = nil

local MENU_ITEM_CHECKED = "* "
local MENU_ITEM_UNCHECKED = "  "

-- Lazy-loads module dependencies to avoid circular reference issues
local function ensure_dependencies()
    if not TooltipManager then
        TooltipManager = BetterConsole.TooltipManager
    end
end

-- Creates menu item label with checkbox prefix based on checked state
-- @param is_checked boolean: Whether menu item is checked
-- @param label string: Display label for menu item
-- @return string: Formatted menu item label with checkbox prefix
local function create_menu_label(is_checked, label)
    local prefix = is_checked and MENU_ITEM_CHECKED or MENU_ITEM_UNCHECKED
    return prefix .. label
end

-- Renders main menu bar with File, Settings, and View menus
-- @param window table: BetterConsole window instance with display settings
M.render = function(window)
    ensure_dependencies()
    if not GUI:BeginMenuBar() then
        return
    end

    if GUI:BeginMenu(L("menu_file")) then
        if GUI:MenuItem(L("menu_export_text")) then
            window:export_to_clipboard()
        end
        GUI:Separator()
        if GUI:MenuItem(L("menu_save_logs")) then
            window:save_logs_to_file()
        end
        GUI:EndMenu()
    end

    if GUI:BeginMenu(L("menu_settings")) then
        local auto_save_logs_label = create_menu_label(window.display.auto_save_logs, L("menu_auto_save"))
            if GUI:MenuItem(auto_save_logs_label) then
                window.display.auto_save_logs = not window.display.auto_save_logs
                window.export_manager:initialize_auto_save(window.display.auto_save_logs)
                BetterConsole.Prefs.save_user_prefs(window)
            end
            TooltipManager.show_warning(L("tooltip_auto_save"))

            GUI:Separator()
            local anti_spam_label = create_menu_label(window.anti_spam.enabled, L("menu_anti_spam"))
            if GUI:MenuItem(anti_spam_label) then
                window.anti_spam:set_enabled(not window.anti_spam.enabled)
                BetterConsole.Prefs.save_user_prefs(window)
            end
            TooltipManager.show_on_hover(L("tooltip_anti_spam"))

            GUI:EndMenu()
        end

        if GUI:BeginMenu(L("menu_view")) then
            local timestamp_label = create_menu_label(window.display.timestamp, L("menu_timestamp"))
            if GUI:MenuItem(timestamp_label) then
                window.display.timestamp = not window.display.timestamp
                window.state_manager:mark_full_refresh()
                BetterConsole.Prefs.save_user_prefs(window)
            end

            local level_label = create_menu_label(window.display.level, L("menu_level"))
            if GUI:MenuItem(level_label) then
                window.display.level = not window.display.level
                window.state_manager:mark_full_refresh()
                BetterConsole.Prefs.save_user_prefs(window)
            end

            local category_label = create_menu_label(window.display.category, L("menu_category"))
            if GUI:MenuItem(category_label) then
                window.display.category = not window.display.category
                window.state_manager:mark_full_refresh()
                BetterConsole.Prefs.save_user_prefs(window)
            end

            local metadata_label = create_menu_label(window.display.metadata, L("menu_metadata"))
            if GUI:MenuItem(metadata_label) then
                window.display.metadata = not window.display.metadata
                BetterConsole.Prefs.save_user_prefs(window)
            end

            GUI:Separator()
            local metadata_panel_label = create_menu_label(window.show_metadata_panel, L("menu_metadata_panel"))
            if GUI:MenuItem(metadata_panel_label) then
                window.show_metadata_panel = not window.show_metadata_panel
                BetterConsole.Prefs.save_user_prefs(window)
            end
            TooltipManager.show_on_hover(L("tooltip_metadata_panel"))

            GUI:Separator()
            local original_console_label = create_menu_label(BetterConsole.show_original_console, L("menu_show_minion_console"))
            if GUI:MenuItem(original_console_label) then
                BetterConsole.show_original_console = not BetterConsole.show_original_console
                if BetterConsole.Init and BetterConsole.Init.set_show_original_console then
                    BetterConsole.Init.set_show_original_console(BetterConsole.show_original_console)
                end
            end
            GUI:EndMenu()
        end

        GUI:EndMenuBar()
end

BetterConsole.MenuBar = M
    UIComponents.MenuBar = M
end

-- Header module providing filter controls, search, and quick actions
-- Manages active filter chips, search input with debouncing, and filter presets
do
local M = {}

local Theme = nil
local TooltipManager = nil

local FILTER_STATE_CLEARED = (FilterStates and FilterStates.CLEARED) or 0
local FILTER_STATE_INCLUDED = (FilterStates and FilterStates.INCLUDED) or 1
local FILTER_STATE_EXCLUDED = (FilterStates and FilterStates.EXCLUDED) or 2
local FILTER_COUNT_INCREMENT = 1
local SINGLE_ITEM_COUNT = 1
local EMPTY_COUNT = 0
local MOUSE_BUTTON_RIGHT = 1
local STYLE_SPACING_X = 8
local STYLE_SPACING_Y = 4
local CATEGORY_ALL = (CategoryConstants and CategoryConstants.ALL) or "All"
local SINGLE_LEVEL_COUNT = 1
local MAX_LOG_LEVELS = 5
local SCROLLBAR_WIDTH = 20
local MIN_SEARCH_WIDTH = 250
local SEARCH_WIDTH_RATIO = 0.4
local SEARCH_LABEL_WIDTH = 45
local SEARCH_RESULT_PADDING = 10
local SEARCH_SPACING = 8
local SEARCH_RIGHT_OFFSET = -15
local DOTS_ANIMATION_SPEED = 2
local DOTS_ANIMATION_MAX = 4
local NO_RESULTS_COUNT = 0
local MS_PER_SECOND = (TimeConstants and TimeConstants.MS_PER_SECOND) or 1000
local SEARCH_THRESHOLD_LARGE = 1000
local SEARCH_THRESHOLD_MEDIUM = 500
local VERSION_INCREMENT = 1
local COLUMN_COUNT = 3
local PRESET_WIDTH = 200
local PRESET_INDEX_OFFSET = (GeneralConstants and GeneralConstants.FIRST_INDEX) or 1
local PRESET_FIRST_INDEX = (FiltersConstants and FiltersConstants.DEFAULT_CUSTOM_PRESET_INDEX) or 0

-- Lazy-loads module dependencies to avoid circular reference issues
local function ensure_dependencies()
    if not Theme then
        Theme = BetterConsole.Theme
    end
    if not TooltipManager then
        TooltipManager = BetterConsole.TooltipManager
    end
end

-- Returns plural suffix for level count (empty for 1, "s" for others)
-- @param count number: Count of levels
-- @return string: Empty string or "s"
local function pluralize_level(count)
    return count == SINGLE_ITEM_COUNT and "" or "s"
end

-- Adds formatted level filter details to details table
-- @param details table: Array of detail strings to append to
-- @param included_levels number: Count of included levels
-- @param excluded_levels number: Count of excluded levels
local function add_level_filter_detail(details, included_levels, excluded_levels)
    if included_levels > EMPTY_COUNT and excluded_levels > EMPTY_COUNT then
        table.insert(details, string.format("%d level%s, exclude %d",
            included_levels, pluralize_level(included_levels), excluded_levels))
    elseif included_levels > EMPTY_COUNT then
        table.insert(details, string.format("%d level%s",
            included_levels, pluralize_level(included_levels)))
    elseif excluded_levels > EMPTY_COUNT then
        table.insert(details, string.format("exclude %d level%s",
            excluded_levels, pluralize_level(excluded_levels)))
    end
end

-- Counts active filters and generates human-readable summary
-- @param window table: BetterConsole window instance with filters
-- @return number: Count of active filters
-- @return string: Comma-separated description of active filters
M.count_active_filters = function(window)
    local count = EMPTY_COUNT
    local details = {}

    local has_level_filter = false
    local included_levels = EMPTY_COUNT
    local excluded_levels = EMPTY_COUNT
    for level, state in pairs(window.filters.level_states or {}) do
        if state == FILTER_STATE_INCLUDED then
            included_levels = included_levels + FILTER_COUNT_INCREMENT
            has_level_filter = true
        elseif state == FILTER_STATE_EXCLUDED then
            excluded_levels = excluded_levels + FILTER_COUNT_INCREMENT
            has_level_filter = true
        end
    end

    if has_level_filter then
        count = count + FILTER_COUNT_INCREMENT
        add_level_filter_detail(details, included_levels, excluded_levels)
    end

    for cat, state in pairs(window.filters.category_states or {}) do
        if state == FILTER_STATE_INCLUDED then
            count = count + FILTER_COUNT_INCREMENT
            table.insert(details, cat)
        elseif state == FILTER_STATE_EXCLUDED then
            count = count + FILTER_COUNT_INCREMENT
            table.insert(details, "exclude " .. cat)
        end
    end

    if window.filters.search and window.filters.search ~= "" then
        count = count + FILTER_COUNT_INCREMENT
        table.insert(details, string.format("'%s'", window.filters.search))
    end

    return count, table.concat(details, ", ")
end

-- Applies filter change by marking state dirty and optionally updating quick filter
-- @param window table: BetterConsole window instance
-- @param update_levels boolean: Whether to update quick filter preset from level states
local function apply_filter_change(window, update_levels)
    window.state_manager:mark_full_refresh()
    window.state_manager:mark_filters_dirty()
    if update_levels then
        window:update_quick_filter_from_levels()
    end
    BetterConsole.Prefs.save_user_prefs(window)
end

-- Clears all level filters by enabling all levels
-- @param window table: BetterConsole window instance with filters
local function clear_all_levels(window)
    for lvl, _ in pairs(window.filters.levels) do
        window.filters.levels[lvl] = true
    end
end

-- Converts seconds to milliseconds
-- @param seconds number: Time in seconds
-- @return number: Time in milliseconds
local function to_milliseconds(seconds)
    return seconds * MS_PER_SECOND
end

-- Cancels running search coroutine by incrementing version and clearing state
-- @param window table: BetterConsole window instance with search coroutine
local function cancel_search_coroutine(window)
    if window.search_coroutine then
        window.search_version = window.search_version + VERSION_INCREMENT
        window.search_coroutine = nil
        window.search_in_progress = false
    end
end

-- Clears all category filter states to CLEARED (no filter)
-- @param window table: BetterConsole window instance with category_states
local function clear_all_category_states(window)
    for cat, _ in pairs(window.filters.category_states) do
        window.filters.category_states[cat] = FILTER_STATE_CLEARED
    end
end

-- Renders search filter chip with clear button if search is active
-- @param window table: BetterConsole window instance with search filter
local function render_search_chip(window)
    ensure_dependencies()
    if not (window.filters.search and window.filters.search ~= "") then
        return
    end

    if Theme.filter_chip(string.format("search: '%s' ×", window.filters.search), "search") then
        window.filters.search = ""
        window.search.text = ""
        window.search.pending_text = ""
        apply_filter_change(window, false)
    end
    TooltipManager.show_on_hover("Click to clear search filter")
    GUI:SameLine()
end

-- Renders level filter chips with click/right-click handlers
-- @param window table: BetterConsole window instance
-- @param enabled_levels table: Array of enabled level names
local function render_level_chips(window, enabled_levels)
    ensure_dependencies()
    for _, level in ipairs(enabled_levels) do
        if Theme.filter_chip(string.format("%s ×", level), "level") then
            if #enabled_levels == SINGLE_LEVEL_COUNT then
                clear_all_levels(window)
            else
                window.filters.levels[level] = false
            end
            apply_filter_change(window, true)
        end

        if GUI:IsItemClicked(MOUSE_BUTTON_RIGHT) then
            clear_all_levels(window)
            window.filters.exclude_levels[level] = true
            apply_filter_change(window, true)
        end

        if TooltipManager.should_show() then
            if #enabled_levels == SINGLE_LEVEL_COUNT then
                TooltipManager.show("Click to clear level filter\nright-click to exclude " .. level .. " level")
            else
                TooltipManager.show("Click to remove " .. level .. " from filter\nright-click to exclude " .. level .. " level")
            end
        end

        GUI:SameLine()
    end
end

-- Renders category filter chips with click/right-click handlers
-- @param window table: BetterConsole window instance
-- @param enabled_categories table: Array of enabled category names
local function render_category_chips(window, enabled_categories)
    ensure_dependencies()
    for _, cat in ipairs(enabled_categories) do
        if Theme.filter_chip(string.format("%s ×", cat), "category") then
            window.filters.categories[cat] = nil
            apply_filter_change(window, false)
        end

        if GUI:IsItemClicked(MOUSE_BUTTON_RIGHT) then
            window.filters.categories[cat] = nil
            window.filters.exclude_categories[cat] = true
            apply_filter_change(window, false)
        end

        TooltipManager.show_on_hover("Click to remove " .. cat .. " category filter\nright-click to exclude " .. cat .. " category")
        GUI:SameLine()
    end
end

-- Renders excluded level chips with click/right-click handlers
-- @param window table: BetterConsole window instance
-- @param excluded_levels table: Array of excluded level names
local function render_excluded_level_chips(window, excluded_levels)
    ensure_dependencies()
    for _, level in ipairs(excluded_levels) do
        if Theme.filter_chip(string.format("X %s ×", level), "exclude") then
            window.filters.exclude_levels[level] = nil
            apply_filter_change(window, false)
        end

        if GUI:IsItemClicked(MOUSE_BUTTON_RIGHT) then
            window.filters.exclude_levels[level] = nil
            window.filters.levels[level] = true
            apply_filter_change(window, true)
        end

        TooltipManager.show_on_hover("Click to remove " .. level .. " level exclusion\nright-click to enable only " .. level .. " level")
        GUI:SameLine()
    end
end

-- Renders excluded category chips with click/right-click handlers
-- @param window table: BetterConsole window instance
-- @param excluded_categories table: Array of excluded category names
local function render_excluded_category_chips(window, excluded_categories)
    ensure_dependencies()
    for _, cat in ipairs(excluded_categories) do
        if Theme.filter_chip(string.format("X %s ×", cat), "exclude") then
            window.filters.exclude_categories[cat] = nil
            apply_filter_change(window, false)
        end

        if GUI:IsItemClicked(MOUSE_BUTTON_RIGHT) then
            window.filters.exclude_categories[cat] = nil
            window.filters.categories[cat] = true
            apply_filter_change(window, false)
        end

        TooltipManager.show_on_hover("Click to remove " .. cat .. " category exclusion\nright-click to filter only " .. cat .. " category")
        GUI:SameLine()
    end
end

-- Renders row of active filter chips showing current filtering state
-- Displays level, category, search, and exclusion filters as removable chips
-- @param window table: BetterConsole window instance with filters
M.render_active_filter_chips = function(window)
    local enabled_levels = {}
    local disabled_levels = EMPTY_COUNT
    for level, enabled in pairs(window.filters.levels) do
        if enabled then
            table.insert(enabled_levels, level)
        else
            disabled_levels = disabled_levels + FILTER_COUNT_INCREMENT
        end
    end

    local enabled_categories = {}
    for cat, enabled in pairs(window.filters.categories) do
        if enabled == true then
            table.insert(enabled_categories, cat)
        end
    end

    local excluded_levels = {}
    for level, excluded in pairs(window.filters.exclude_levels) do
        if excluded == true then
            table.insert(excluded_levels, level)
        end
    end

    local excluded_categories = {}
    for cat, excluded in pairs(window.filters.exclude_categories) do
        if excluded == true then
            table.insert(excluded_categories, cat)
        end
    end

    local has_search = window.filters.search and window.filters.search ~= ""
    local has_level_filters = disabled_levels > EMPTY_COUNT and disabled_levels < MAX_LOG_LEVELS
    local has_any_chips = has_search or has_level_filters or
                        #enabled_categories > EMPTY_COUNT or
                        #excluded_levels > EMPTY_COUNT or
                        #excluded_categories > EMPTY_COUNT

    if not has_any_chips then
        return
    end

    GUI:Text("Active Filters:")
    GUI:SameLine()

    render_search_chip(window)

    if has_level_filters then
        render_level_chips(window, enabled_levels)
    end

    render_category_chips(window, enabled_categories)
    render_excluded_level_chips(window, excluded_levels)
    render_excluded_category_chips(window, excluded_categories)

    GUI:NewLine()
end

-- Renders complete header section with primary actions and advanced filters
-- @param window table: BetterConsole window instance
M.render = function(window)
    ensure_dependencies()
    GUI:PushStyleVar(GUI.StyleVar_ItemSpacing, { STYLE_SPACING_X, STYLE_SPACING_Y })

    M.render_primary_actions(window)

    if GUI:CollapsingHeader("Advanced Filters", window.show_advanced_filters) then
        window.show_advanced_filters = true
        M.render_advanced_filters(window)
    else
        window.show_advanced_filters = false
    end
    TooltipManager.show_on_hover("Click to show/hide advanced filter options")

    GUI:PopStyleVar()
    GUI:Separator()
end

-- Renders primary action row with Clear, quick filters, and search
-- Includes debounced search input with live result count and coroutine handling
-- @param window table: BetterConsole window instance
M.render_primary_actions = function(window)
    ensure_dependencies()
    if GUI:Button(L("clear_button")) then
        window:clear()
    end
    TooltipManager.show_on_hover(L("tooltip_clear"))

    GUI:SameLine()
    local preset_names = {}
    for i, preset in ipairs(window.quick_filter_presets) do
        preset_names[i] = preset.name
    end

    GUI:PushItemWidth(BetterConsole.Models.Constants.UI.LEVEL_DROPDOWN_WIDTH)
    local new_level_index, level_changed = GUI:Combo("##QuickFilter", window.current_quick_filter, preset_names)
    GUI:PopItemWidth()
    TooltipManager.show_on_hover(L("tooltip_quick_filter"))

    if level_changed then
        window.current_quick_filter = new_level_index
        window:apply_quick_filter_preset(new_level_index)
    end

    GUI:SameLine()
    local categories = window:get_available_categories()

    GUI:PushItemWidth(BetterConsole.Models.Constants.UI.CATEGORY_DROPDOWN_WIDTH)
    local new_category_index, category_changed = GUI:Combo("##CategoryFilter", window.current_category_filter, categories)
    GUI:PopItemWidth()
    TooltipManager.show_on_hover("Quick category filter")

    if category_changed then
        window.current_category_filter = new_category_index
        local selected_category = categories[new_category_index]

        clear_all_category_states(window)

        if selected_category ~= CATEGORY_ALL then
            window.filters.category_states[selected_category] = FILTER_STATE_INCLUDED
        end

        window.state_manager:mark_full_refresh()
        window.state_manager:mark_filters_dirty()
        BetterConsole.Prefs.save_user_prefs(window)

        cancel_search_coroutine(window)
    end

    GUI:SameLine()

    if window.state_manager:needs_filters_refresh() or window.cached_filter_count == nil then
        window.cached_filter_count, window.cached_filter_details = M.count_active_filters(window)
        window.state_manager:clear_filters_dirty()
    end
    local filter_count, filter_details = window.cached_filter_count, window.cached_filter_details
    if filter_count > EMPTY_COUNT then
        local clicked = Theme.colored_button(
            string.format("[%d filter%s]", filter_count, pluralize_level(filter_count)),
            {
                button = Theme.Colors.BUTTON_SECONDARY,
                hover = Theme.Colors.BUTTON_SECONDARY_HOVER,
                active = Theme.Colors.BUTTON_SECONDARY_ACTIVE
            }
        )
        if clicked then
            window.filter_window_open = not window.filter_window_open
        end
        if GUI:IsItemClicked(MOUSE_BUTTON_RIGHT) then
            window:clear_all_filters()
        end
        TooltipManager.show_on_hover("Active filters: " .. filter_details .. "\nclick to open filter configuration\nright-click to clear all filters")
    else
        local clicked = Theme.colored_button(
            "[No filters]",
            {
                button = Theme.Colors.BUTTON_SECONDARY,
                hover = Theme.Colors.BUTTON_SECONDARY_HOVER,
                active = Theme.Colors.BUTTON_SECONDARY_ACTIVE
            }
        )
        if clicked then
            window.filter_window_open = not window.filter_window_open
        end
        if GUI:IsItemClicked(MOUSE_BUTTON_RIGHT) then
            window:clear_all_filters()
        end
        TooltipManager.show_on_hover("All log entries are shown\nclick to open filter configuration\nright-click to clear all filters")
    end

    local available_width = GUI:GetContentRegionAvail()
    local adjusted_width = available_width - SCROLLBAR_WIDTH
    local search_width = math.max(MIN_SEARCH_WIDTH, adjusted_width * SEARCH_WIDTH_RATIO)
    local result_text = ""
    if window.search_in_progress then
        local dots = string.rep(".", (math.floor(os.clock() * DOTS_ANIMATION_SPEED) % DOTS_ANIMATION_MAX))
        if window.partial_result_count > EMPTY_COUNT then
            result_text = string.format("(%d results%s)", window.partial_result_count, dots)
        else
            if window.filters.search ~= "" and window.display_entries and #window.display_entries == NO_RESULTS_COUNT then
                result_text = "(0 results)"
            else
                result_text = string.format("Searching%s", dots)
            end
        end
    else
        result_text = string.format("(%d results)", #window.display_entries)
    end
    local results_text_width = GUI:CalcTextSize(result_text) + SEARCH_RESULT_PADDING
    local total_width = SEARCH_LABEL_WIDTH + search_width + results_text_width + SEARCH_SPACING * 2

    local current_x = GUI:GetCursorPosX()
    local base_x = current_x + adjusted_width - total_width - SEARCH_RIGHT_OFFSET
    local results_x = base_x
    local search_label_x = base_x + results_text_width + SEARCH_SPACING
    local search_input_x = search_label_x + SEARCH_LABEL_WIDTH + SEARCH_SPACING

    if results_x > current_x then
        GUI:SameLine()
        GUI:SetCursorPosX(results_x)
    else
        GUI:SameLine()
    end

    local is_actually_searching = window.search_in_progress and
        not (window.filters.search ~= "" and window.display_entries and
             #window.display_entries == NO_RESULTS_COUNT and window.partial_result_count == NO_RESULTS_COUNT)

    if is_actually_searching then
        Theme.colored_text(Theme.Colors.TEXT_WARNING, result_text)
        if TooltipManager.should_show() then
            local elapsed_time = to_milliseconds(os.clock()) - window.search_start_time
            TooltipManager.show(string.format("Searching... %d results so far (%.1fms elapsed)",
                window.partial_result_count, elapsed_time))
        end
    else
        GUI:TextDisabled(result_text)
        TooltipManager.show_on_hover(string.format("%d results found", #window.display_entries))
    end

    GUI:SameLine()
    GUI:SetCursorPosX(search_label_x)
    GUI:Text(L("search_label"))

    GUI:SameLine()
    GUI:SetCursorPosX(search_input_x)

    if window.focus_target == "search" then
        GUI:SetKeyboardFocusHere(0)
        window.focus_target = nil
    end

    GUI:PushItemWidth(search_width)

    local new_text, changed = GUI:InputText("##SearchInput", window.search.text or "")

    GUI:PopItemWidth()

    if changed then
        window.search.text = new_text
        window.search.pending_text = new_text
        window.search.last_input_time = to_milliseconds(os.clock())
    end

    window.search.is_focused = GUI:IsItemFocused()

    if window.search.is_focused and BetterConsole.Keymap then
        BetterConsole.Keymap.process_search_shortcuts(window.search.is_focused, window)
    end

    local current_time = to_milliseconds(os.clock())
    local pending_search = window.search.pending_text

    if window.search.pending_text ~= window.filters.search and
        (current_time - window.search.last_input_time) >= BetterConsole.Models.Constants.Performance.SEARCH_DEBOUNCE_DELAY then
        window.filters.search = pending_search
        window.state_manager:mark_filters_dirty()

        if window.search_coroutine then
            window.search_version = window.search_version + VERSION_INCREMENT
            window.search_coroutine = nil
        end

        if window.chunk_state.is_processing then
            window.chunk_state.is_processing = false
        end

        window.search_version = window.search_version + VERSION_INCREMENT
        window.search_in_progress = true
        window.search_start_time = to_milliseconds(os.clock())
        window.partial_result_count = EMPTY_COUNT

        local entry_count = window.data_store:get_entry_count()
        local has_search = window.filters.search and window.filters.search ~= ""
        local use_coroutine_search = entry_count > SEARCH_THRESHOLD_LARGE or (has_search and entry_count > SEARCH_THRESHOLD_MEDIUM)

        if use_coroutine_search then
            window.search_coroutine = window:create_search_coroutine(
                window.data_store:get_entries(),
                window.filters.search,
                window.search_version
            )
        else
            window.state_manager:mark_full_refresh()
            window.search_in_progress = false
        end
    end

end

-- Renders advanced filter section with log levels, categories, and presets
-- Provides checkbox grids for fine-grained filtering and preset management
-- @param window table: BetterConsole window instance with filters and presets
M.render_advanced_filters = function(window)
    GUI:PushStyleVar(GUI.StyleVar_ItemSpacing, { STYLE_SPACING_X, STYLE_SPACING_Y })

    if GUI:CollapsingHeader("Log Levels", true) then
        GUI:Text("Include:")
        GUI:Columns(COLUMN_COUNT, nil, false)
        for i, level in ipairs(BetterConsole.Models.LogLevel.ALL_LEVELS) do
            local enabled, changed = GUI:Checkbox(level.name, window.filters.levels[level.name])
            if changed then
                window.filters.levels[level.name] = enabled
                window.state_manager:mark_full_refresh()
                window.state_manager:mark_filters_dirty()
                window:update_quick_filter_from_levels()
                BetterConsole.Prefs.save_user_prefs(window)

                if window.search_coroutine then
                    window.search_version = window.search_version + 1
                    window.search_coroutine = nil
                    window.search_in_progress = false
                end
            end
            if TooltipManager.should_show() then
                local tooltips = {
                    TRACE = "Show detailed trace messages for debugging",
                    DEBUG = "Show debug information for development",
                    INFO = "Show informational messages",
                    WARN = "Show warning messages",
                    ERROR = "Show error messages"
                }
                TooltipManager.show(tooltips[level.name] or ("Toggle " .. level.name .. " level messages"))
            end
            if i % 3 ~= 0 then
                GUI:NextColumn()
            else
                GUI:NextColumn()
                GUI:Separator()
            end
        end
        GUI:Columns(1)

        GUI:Separator()
        GUI:Text("Exclude:")
        GUI:Columns(COLUMN_COUNT, nil, false)
        for i, level in ipairs(BetterConsole.Models.LogLevel.ALL_LEVELS) do
            local excluded = window.filters.exclude_levels[level.name] or false
            local changed
            excluded, changed = GUI:Checkbox("X " .. level.name, excluded)
            if changed then
                window.filters.exclude_levels[level.name] = excluded
                window.state_manager:mark_full_refresh()
                window.state_manager:mark_filters_dirty()
                BetterConsole.Prefs.save_user_prefs(window)

                cancel_search_coroutine(window)
            end
            TooltipManager.show_on_hover("Hide all " .. level.name .. " level messages")
            if i % COLUMN_COUNT ~= EMPTY_COUNT then
                GUI:NextColumn()
            else
                GUI:NextColumn()
                GUI:Separator()
            end
        end
        GUI:Columns(1)
    end

    GUI:Separator()

    if GUI:CollapsingHeader("Categories", true) then
        local categories = window:get_available_categories()
        local num_categories = EMPTY_COUNT
        for _, cat in ipairs(categories) do
            if cat ~= CATEGORY_ALL then
                num_categories = num_categories + FILTER_COUNT_INCREMENT
            end
        end

        if num_categories == EMPTY_COUNT then
            GUI:TextDisabled("No categories available")
        else
            GUI:Text("Include:")
            GUI:Columns(COLUMN_COUNT, nil, false)
            local count = EMPTY_COUNT
            for _, cat in ipairs(categories) do
                if cat ~= CATEGORY_ALL then
                    local enabled = window.filters.categories[cat]
                    if enabled == nil then
                        enabled = true
                    end
                    local changed
                    enabled, changed = GUI:Checkbox(cat, enabled)
                    if changed then
                        window.filters.categories[cat] = enabled
                        window.state_manager:mark_full_refresh()
                        window.state_manager:mark_filters_dirty()
                        BetterConsole.Prefs.save_user_prefs(window)

                        cancel_search_coroutine(window)
                    end
                    TooltipManager.show_on_hover("Toggle " .. cat .. " category messages")
                    count = count + FILTER_COUNT_INCREMENT
                    if count % COLUMN_COUNT ~= EMPTY_COUNT then
                        GUI:NextColumn()
                    else
                        GUI:NextColumn()
                        GUI:Separator()
                    end
                end
            end
            GUI:Columns(1)

            GUI:Separator()
            GUI:Text("Exclude:")
            GUI:Columns(COLUMN_COUNT, nil, false)
            count = EMPTY_COUNT
            for _, cat in ipairs(categories) do
                if cat ~= CATEGORY_ALL then
                    local excluded = window.filters.exclude_categories[cat] or false
                    local changed
                    excluded, changed = GUI:Checkbox("X " .. cat, excluded)
                    if changed then
                        window.filters.exclude_categories[cat] = excluded
                        window.state_manager:mark_full_refresh()
                        window.state_manager:mark_filters_dirty()
                        BetterConsole.Prefs.save_user_prefs(window)

                        cancel_search_coroutine(window)
                    end
                    TooltipManager.show_on_hover("Hide all " .. cat .. " category messages")
                    count = count + FILTER_COUNT_INCREMENT
                    if count % COLUMN_COUNT ~= EMPTY_COUNT then
                        GUI:NextColumn()
                    else
                        GUI:NextColumn()
                        GUI:Separator()
                    end
                end
            end
            GUI:Columns(1)
        end
    end

    GUI:Separator()

    if GUI:CollapsingHeader("Search Options", false) then
        local case_value, case_changed = GUI:Checkbox("Case Sensitive", window.search.case_sensitive)
        if case_changed then
            window.search.case_sensitive = case_value
            window.state_manager:mark_full_refresh()
            BetterConsole.Prefs.save_user_prefs(window)
        end
        TooltipManager.show_on_hover("Match exact letter case in searches")
    end

    GUI:PopStyleVar()

    GUI:Separator()

    if GUI:CollapsingHeader("Filter Presets", false) then
        if #window.custom_filter_presets == EMPTY_COUNT then
            GUI:TextDisabled("No saved presets")
        else
            local preset_names = { "Select Preset..." }
            for i, preset in ipairs(window.custom_filter_presets) do
                table.insert(preset_names, preset.name)
            end

            GUI:PushItemWidth(PRESET_WIDTH)
            local selected_preset = window.current_custom_preset
            if selected_preset == PRESET_FIRST_INDEX then
                selected_preset = SINGLE_ITEM_COUNT
            else
                selected_preset = selected_preset + PRESET_INDEX_OFFSET
            end

            local new_index, changed = GUI:Combo("##PresetSelect", selected_preset, preset_names)
            GUI:PopItemWidth()

            if changed and new_index > SINGLE_ITEM_COUNT then
                window:apply_filter_preset(new_index - PRESET_INDEX_OFFSET)
            end

            TooltipManager.show_on_hover("Load a saved filter preset")

            if window.current_custom_preset > PRESET_FIRST_INDEX and window.current_custom_preset <= #window.custom_filter_presets then
                GUI:SameLine()
                if GUI:Button("Delete") then
                    window:delete_filter_preset(window.current_custom_preset)
                    window.current_custom_preset = PRESET_FIRST_INDEX
                end
                if TooltipManager.should_show() then
                    local preset = window.custom_filter_presets[window.current_custom_preset]
                    if preset then
                        TooltipManager.show("Delete preset: " .. preset.name)
                    end
                end
            end
        end

        GUI:Separator()
        GUI:Text("Save Current Filters:")
        GUI:PushItemWidth(PRESET_WIDTH)
        local new_name, text_changed = GUI:InputText("##PresetName", window.preset_name_input)
        if text_changed then
            window.preset_name_input = new_name
        end
        GUI:PopItemWidth()

        GUI:SameLine()
        if GUI:Button("Save As Preset") then
            if window:save_current_filter_as_preset(window.preset_name_input) then
                window.preset_name_input = ""
            end
        end
        TooltipManager.show_on_hover("Save current filter configuration as a preset")
    end

    GUI:Separator()

    if GUI:CollapsingHeader("Display Options", true) then

    end

    GUI:PopStyleVar()
end

BetterConsole.Header = M
    UIComponents.Header = M
end

-- LogList module providing scrollable log display with virtual scrolling
-- Manages rendering of log entries with selection and context menu support
do
local M = {}

-- Renders scrollable log display area with virtual scrolling for performance
-- @param window table: BetterConsole window instance
-- @param width number: Width of display area (0 for auto)
M.render = function(window, width)

    width = width or 0

    local _, available_height = GUI:GetContentRegionAvail()
    local reserved_height = 55
    available_height = math.max(100, available_height - reserved_height)

    if available_height <= 0 then
        available_height = 100
    end

    GUI:BeginChild("LogDisplay##BetterConsole", width, available_height, true, GUI.WindowFlags_HorizontalScrollbar)

    if #window.display_entries == 0 then
        GUI:Text("No log entries to display")
    else
        local visible_start, visible_end = BetterConsole.VirtualScroll.update(
            window.virtual_scroll,
            window,
            #window.display_entries,
            available_height
        )

        BetterConsole.VirtualScroll.render_spacers_with_ranges(
            window,
            visible_start,
            visible_start,
            visible_end,
            #window.display_entries
        )
    end

    GUI:EndChild()
end

-- Renders individual log entry with selection, highlighting, and context menu
-- Handles click/right-click events, metadata tooltips, and search highlighting
-- @param window table: BetterConsole window instance
-- @param entry table: LogEntry instance to render
-- @param index number: Index of entry in display list
M.render_log_entry = function(window, entry, index)
    local color = window:get_cached_color(entry)

    local text = entry:get_processed_display_text(window.display.timestamp, window.display.level, window.display.category, 2000) or ""

    local window_pos_x, window_pos_y = GUI:GetWindowPos()
    local content_width, _ = GUI:GetContentRegionAvail()

    GUI:PushStyleVar(GUI.StyleVar_ItemSpacing, { 8, 2 })
    GUI:PushStyleVar(GUI.StyleVar_FramePadding, { 0, 0 })
    GUI:PushStyleColor(GUI.Col_Text, color[1], color[2], color[3], color[4])

    local available_width = content_width

    local is_selected = window.selection_manager:is_selected(index)
    local is_metadata_selected = (window.selected_entry_for_metadata == entry)

    local start_x, start_y = GUI:GetCursorScreenPos()
    local cursor_pos_x, cursor_pos_y = GUI:GetCursorPos()

    GUI:PushStyleColor(GUI.Col_Text, 0, 0, 0, 0)

    local left_padding = 8
    GUI:PushTextWrapPos(window_pos_x + available_width - left_padding)

    GUI:Dummy(left_padding, 0)
    GUI:SameLine(0, 0)

    if window.filters.search ~= "" then
        window:render_highlighted_text(text, window.filters.search)
    else
        GUI:TextWrapped(text)
    end

    GUI:PopTextWrapPos()
    GUI:PopStyleColor()
    GUI:PopStyleColor()

    local end_x, end_y = GUI:GetCursorScreenPos()
    local line_spacing = GUI:GetTextLineHeightWithSpacing() - GUI:GetTextLineHeight()
    local item_spacing_y = 2
    local item_height = (end_y - start_y) - line_spacing - item_spacing_y

    GUI:SetCursorPos(cursor_pos_x, cursor_pos_y)

    GUI:Selectable("##log_" .. tostring(index), is_selected,
        GUI.SelectableFlags_SpanAllColumns + GUI.SelectableFlags_AllowDoubleClick,
        available_width, item_height)

    local is_selectable_hovered = GUI:IsItemHovered()
    local is_selectable_right_clicked = GUI:IsItemClicked(1)
    local is_selectable_clicked = GUI:IsItemClicked(0)

    local after_selectable_x, after_selectable_y = GUI:GetCursorPos()

    if is_selectable_clicked then
        local ctrl_down = GUI:IsKeyDown(17)
        local shift_down = GUI:IsKeyDown(16)

        if shift_down and window.selection_manager:get_last_index() then
            window:select_range(window.selection_manager:get_last_index(), index)
        elseif ctrl_down then
            window:toggle_entry_selection(index)
        else
            window:clear_selection()
            window:select_entry(index)
            window.selected_entry_for_metadata = entry
        end
    end

    GUI:SetCursorScreenPos(start_x, start_y)
    GUI:PushTextWrapPos(window_pos_x + available_width - left_padding)
    GUI:PushStyleColor(GUI.Col_Text, color[1], color[2], color[3], color[4])

    GUI:Dummy(left_padding, 0)
    GUI:SameLine(0, 0)

    if window.filters.search ~= "" then
        window:render_highlighted_text(text, window.filters.search)
    else
        GUI:TextWrapped(text)
    end

    GUI:PopStyleColor()
    GUI:PopTextWrapPos()

    GUI:SetCursorPos(after_selectable_x, after_selectable_y)

    if is_selectable_hovered and window.display.metadata then
        window:render_entry_tooltip(entry)
    end

    GUI:PopStyleVar(2)

    if is_selectable_right_clicked then
        GUI:OpenPopup(window.context_menus.log.popup_id .. tostring(index))
    end

    window:render_context_menu(entry, index)
end

BetterConsole.LogList = M
    UIComponents.LogList = M
end

-- CommandInput module providing Lua command input with history navigation
-- Handles input text, execute button, and context menu for cut/copy/paste
do
local M = {}

-- Renders command input widget with execute button and keyboard shortcuts
-- Supports UP/DOWN history navigation and right-click context menu
-- @param window table: BetterConsole window instance with command input state
M.render = function(window)
    GUI:Separator()

    local available_width = GUI:GetContentRegionAvail()
    local button_width = 58
    local right_offset = 2
    local spacing = 6

    local input_width = available_width - button_width - spacing - right_offset

    if window.focus_target == "input" then
        GUI:SetKeyboardFocusHere(0)
        window.focus_target = nil
    end

    GUI:PushItemWidth(input_width)
    local input_id = string.format("##CommandInput%d", window.input_widget_id)
    local new_text, changed = GUI:InputText(input_id, window.command_input)
    GUI:PopItemWidth()

    if GUI:IsItemHovered() then
        GUI:SetTooltip(
            "Enter Lua code here to execute.\nUse UP/DOWN arrows for history")
    end

    if GUI:IsItemClicked(1) then
        GUI:OpenPopup(window.context_menus.input.popup_id)
    end

    if changed then
        window.command_input = new_text
    end

    local is_focused = GUI:IsItemFocused()
    if is_focused and BetterConsole.Keymap then
        BetterConsole.Keymap.process_input_shortcuts(is_focused, window)
    end

    GUI:SameLine(0, spacing)

    if GUI:Button("Execute", button_width, 0) then
        window:execute_command_from_input()
    end
    if GUI:IsItemHovered() then
        GUI:SetTooltip("Execute Lua code (Enter)")
    end

    M.render_context_menu(window)
end

-- Renders context menu for command input with Cut/Copy/Paste/Clear options
-- @param window table: BetterConsole window instance with command input state
M.render_context_menu = function(window)
    if GUI:BeginPopup(window.context_menus.input.popup_id) then
        if GUI:MenuItem("Cut") then
            local text = window.command_input
            if text and text ~= "" then
                GUI:SetClipboardText(text)
                window.command_input = ""
                window.input_widget_id = window.input_widget_id + 1
                window.focus_target = "input"
            end
        end
        if GUI:MenuItem("Copy") then
            local text = window.command_input
            if text and text ~= "" then
                GUI:SetClipboardText(text)
            end
        end
        if GUI:MenuItem("Paste") then
            local clipboard_text = GUI:GetClipboardText()
            if clipboard_text and clipboard_text ~= "" then
                local sanitized_text = window:sanitize_clipboard_text(clipboard_text)
                sanitized_text = sanitized_text:gsub("\n", " "):gsub("\r", "")
                window.command_input = (window.command_input or "") .. sanitized_text
                window.input_widget_id = window.input_widget_id + 1
                window.focus_target = "input"
            end
        end
        GUI:Separator()
        if GUI:MenuItem("Select All") then
            window.input_widget_id = window.input_widget_id + 1
            window.focus_target = "input"
        end
        if GUI:MenuItem("Clear") then
            window.command_input = ""
            window.input_widget_id = window.input_widget_id + 1
            window.focus_target = "input"
        end
        GUI:EndPopup()
    end
end

BetterConsole.CommandInput = M
    UIComponents.CommandInput = M
end

-- StatusBar module displaying statistics and temporary notifications
-- Shows entry counts, memory usage, update time, and spam blocking stats
do
local M = {}

-- Renders status bar with stats or temporary notification message
-- Displays total entries, filtered count, memory, update time, and blocked messages
-- @param window table: BetterConsole window instance with stats and notifications
M.render = function(window)
    GUI:Separator()

    local status_text
    local current_time = os.clock()

    if window.status_notification.message and current_time < window.status_notification.expiry_time then
        status_text = window.status_notification.message
    else
        if window.status_notification.message then
            window.status_notification.message = nil
            window.status_notification.expiry_time = 0
        end

        local stats = window:get_stats()
        local anti_spam_stats = window.anti_spam:get_stats()
        local metrics = window.metrics:get_metrics()

        status_text = string.format("Entries: %d | Filtered: %d | Memory: %.1fKB | Update: %.1fms",
            stats.total_entries or 0,
            #window.display_entries,
            (stats.memory_usage or 0) / 1024,
            metrics.update_time_ms or 0
        )

        if anti_spam_stats.total_blocked > 0 then
            status_text = status_text .. string.format(" | Blocked: %d", anti_spam_stats.total_blocked)
        end
    end

    GUI:Text(status_text)
end

BetterConsole.StatusBar = M
    UIComponents.StatusBar = M
end

-- FiltersWindow module providing popup window for advanced filter configuration
-- Manages log levels, categories, search options with include/exclude states
do
local M = {}

local Theme = nil
local TooltipManager = nil

-- Lazy-loads module dependencies to avoid circular reference issues
local function ensure_dependencies()
    if not Theme then
        Theme = BetterConsole.Theme
    end
    if not TooltipManager then
        TooltipManager = BetterConsole.TooltipManager
    end
end

-- Renders selectable filter item with visual state indication
-- @param label string: Filter label text
-- @param is_included boolean: Whether filter is in included state
-- @param is_excluded boolean: Whether filter is in excluded state
-- @param tooltip string: Tooltip text to display on hover
-- @return boolean: True if left-clicked
-- @return boolean: True if right-clicked
local function render_selectable_filter(label, is_included, is_excluded, tooltip)
    ensure_dependencies()

    local display_label = label
    if is_excluded then
        display_label = "× " .. label
        GUI:PushStyleColor(GUI.Col_Text, unpack(Theme.Colors.CHIP_EXCLUDE_TEXT))
    end

    local selected, clicked = GUI:Selectable(display_label, is_included, 0, 0, 0)

    if is_excluded then
        GUI:PopStyleColor()
    end

    local right_clicked = GUI:IsItemClicked(1)

    if TooltipManager.should_show() then
        if is_excluded then
            TooltipManager.show(tooltip .. "\n" .. L("tooltip_filter_left_include") .. "\n" .. L("tooltip_filter_right_clear_exclusion"))
        elseif is_included then
            TooltipManager.show(tooltip .. "\n" .. L("tooltip_filter_left_clear_include") .. "\n" .. L("tooltip_filter_right_exclude"))
        else
            TooltipManager.show(tooltip .. "\n" .. L("tooltip_filter_left_include") .. "\n" .. L("tooltip_filter_right_exclude"))
        end
    end

    return clicked, right_clicked
end

-- Ensures all filter table structures exist with defaults
-- @param window table: BetterConsole window instance
local function ensure_filter_tables(window)
    window.filters = window.filters or {}
    window.filters.level_states = window.filters.level_states or {
        TRACE = 0, DEBUG = 0, INFO = 0, WARN = 0, ERROR = 0
    }
    window.filters.category_states = window.filters.category_states or {}
    window.filters.levels = window.filters.levels or {}
    window.filters.exclude_levels = window.filters.exclude_levels or {}
    window.filters.categories = window.filters.categories or {}
    window.filters.exclude_categories = window.filters.exclude_categories or {}
end

-- Synchronizes legacy level filter maps from modern state representation
-- @param window table: BetterConsole window instance with level_states
local function sync_level_maps_from_states(window)
    ensure_filter_tables(window)
    window.filters.levels = {}
    window.filters.exclude_levels = {}
    for _, level in ipairs(BetterConsole.Models.LogLevel.ALL_LEVELS) do
        local st = window.filters.level_states[level.name] or 0
        if st == 1 then
            window.filters.levels[level.name] = true
        elseif st == 2 then
            window.filters.exclude_levels[level.name] = true
        end
    end
end

-- Synchronizes legacy category filter maps from modern state representation
-- @param window table: BetterConsole window instance with category_states
-- @param categories table: Array of available category names
local function sync_category_maps_from_states(window, categories)
    ensure_filter_tables(window)
    window.filters.categories = {}
    window.filters.exclude_categories = {}
    for _, cat in ipairs(categories) do
        if cat ~= "All" then
            local st = window.filters.category_states[cat] or 0
            if st == 1 then
                window.filters.categories[cat] = true
            elseif st == 2 then
                window.filters.exclude_categories[cat] = true
            end
        end
    end
end

-- Marks window state dirty and cancels search when filter changes
-- @param window table: BetterConsole window instance
local function on_any_filter_changed(window)
    window.state_manager:mark_full_refresh()
    window.prefs_need_save = true
    window.last_filter_change_time = os.clock() * 1000
    if window.search_coroutine then
        window.search_version = window.search_version + 1
        window.search_coroutine = nil
        window.search_in_progress = false
    end
end

-- Renders popup filter configuration window with selectable lists
-- Provides searchable category list and Clear/Invert buttons for batch operations
-- @param window table: BetterConsole window instance with filter_window_open flag
M.render = function(window)
    ensure_dependencies()
    if not window.filter_window_open then
        return
    end

    local visible, open = GUI:Begin(L("filter_window_title"), window.filter_window_open, GUI.WindowFlags_AlwaysAutoResize)

    if not open then
        window.filter_window_open = false
    end

    if visible then
        GUI:PushStyleVar(GUI.StyleVar_ItemSpacing, { 8, 4 })

        GUI:Dummy(400, 0)

        ensure_filter_tables(window)

        local display_count = #window.display_entries
        local total_count = window.data_store:get_entry_count()
        GUI:TextColored(0, 1, 1, 1, L("showing_entries", display_count, total_count))
        GUI:Separator()

        if GUI:CollapsingHeader(L("search_options")) then
            local case_value, case_changed = GUI:Checkbox(L("case_sensitive"), window.search.case_sensitive)
            if case_changed then
                window.search.case_sensitive = case_value
                on_any_filter_changed(window)
            end
            TooltipManager.show_on_hover(L("tooltip_case_sensitive"))

            GUI:Spacing()
            GUI:Text(L("active_search_term"))

            local has_search = window.filters.search and window.filters.search ~= ""

            if not has_search then
                GUI:TextDisabled(L("no_active_search"))
            else

                if Theme.colored_button(
                    '"' .. window.filters.search .. '" ×##search',
                    {
                        button = Theme.Colors.CHIP_SEARCH_ALT,
                        hover = Theme.Colors.CHIP_SEARCH_HOVER,
                        active = Theme.Colors.CHIP_SEARCH_ACTIVE
                    }
                ) then
                    window.filters.search = ""
                    on_any_filter_changed(window)
                end

                TooltipManager.show_on_hover(L("tooltip_remove_search", window.filters.search))
            end
        end

        GUI:Separator()

        if GUI:CollapsingHeader(L("log_levels")) then
            if GUI:SmallButton(L("filter_clear") .. "##Levels") then
                for _, level in ipairs(BetterConsole.Models.LogLevel.ALL_LEVELS) do
                    window.filters.level_states[level.name] = 0
                end
                sync_level_maps_from_states(window)
                on_any_filter_changed(window)
                window:update_quick_filter_from_levels()
            end
            TooltipManager.show_on_hover(L("tooltip_clear_levels"))

            GUI:SameLine()
            if GUI:SmallButton(L("filter_invert") .. "##Levels") then
                for _, level in ipairs(BetterConsole.Models.LogLevel.ALL_LEVELS) do
                    local current = window.filters.level_states[level.name] or 0
                    if current == 1 then
                        window.filters.level_states[level.name] = 2
                    elseif current == 2 then
                        window.filters.level_states[level.name] = 1
                    end
                end
                sync_level_maps_from_states(window)
                on_any_filter_changed(window)
                window:update_quick_filter_from_levels()
            end
            TooltipManager.show_on_hover(L("tooltip_invert_levels"))

            GUI:Spacing()

            local item_height = GUI:GetTextLineHeightWithSpacing()
            local num_levels = #BetterConsole.Models.LogLevel.ALL_LEVELS
            local child_height = item_height * num_levels + 16

            GUI:BeginChild("LevelsScroll", 0, child_height, true)

            if not window.filters.level_states then
                window.filters.level_states = {
                    TRACE = 0,
                    DEBUG = 0,
                    INFO = 0,
                    WARN = 0,
                    ERROR = 0
                }
            end

            local tooltips = {
                TRACE = {
                    include = L("tooltip_level_trace"),
                    exclude = L("tooltip_hide_trace")
                },
                DEBUG = {
                    include = L("tooltip_level_debug"),
                    exclude = L("tooltip_hide_debug")
                },
                INFO = {
                    include = L("tooltip_level_info"),
                    exclude = L("tooltip_hide_info")
                },
                WARN = {
                    include = L("tooltip_level_warn"),
                    exclude = L("tooltip_hide_warn")
                },
                ERROR = {
                    include = L("tooltip_level_error"),
                    exclude = L("tooltip_hide_error")
                }
            }

            for _, level in ipairs(BetterConsole.Models.LogLevel.ALL_LEVELS) do
                local current_state = window.filters.level_states[level.name] or 0
                local is_included = current_state == 1
                local is_excluded = current_state == 2
                local tooltip = tooltips[level.name] or {include = "Show " .. level.name, exclude = "Hide " .. level.name}
                local tooltip_text = is_excluded and tooltip.exclude or tooltip.include

                local left_clicked, right_clicked = render_selectable_filter(level.name, is_included, is_excluded, tooltip_text)

                if left_clicked then

                    if current_state == 1 then
                        window.filters.level_states[level.name] = 0
                    else
                        window.filters.level_states[level.name] = 1
                    end
                    sync_level_maps_from_states(window)
                    on_any_filter_changed(window)
                    window:update_quick_filter_from_levels()
                elseif right_clicked then

                    if current_state == 2 then
                        window.filters.level_states[level.name] = 0
                    else
                        window.filters.level_states[level.name] = 2
                    end
                    sync_level_maps_from_states(window)
                    on_any_filter_changed(window)
                    window:update_quick_filter_from_levels()
                end
            end

            GUI:EndChild()
        end

        GUI:Separator()

        if GUI:CollapsingHeader(L("categories")) then
            local categories = window:get_available_categories()
            local num_categories = 0
            for _, cat in ipairs(categories) do
                if cat ~= "All" then
                    num_categories = num_categories + 1
                end
            end

            if num_categories == 0 then
                GUI:TextDisabled(L("no_categories_available"))
            else
                if GUI:SmallButton(L("filter_clear") .. "##Categories") then
                    for _, cat in ipairs(categories) do
                        if cat ~= "All" then
                            window.filters.category_states[cat] = 0
                        end
                    end
                    sync_category_maps_from_states(window, categories)
                    on_any_filter_changed(window)
                end
                TooltipManager.show_on_hover(L("tooltip_clear_categories"))

                GUI:SameLine()
                if GUI:SmallButton(L("filter_invert") .. "##Categories") then
                    for _, cat in ipairs(categories) do
                        if cat ~= "All" then
                            local current = window.filters.category_states[cat] or 0
                            if current == 1 then
                                window.filters.category_states[cat] = 2
                            elseif current == 2 then
                                window.filters.category_states[cat] = 1
                            end
                        end
                    end
                    sync_category_maps_from_states(window, categories)
                    on_any_filter_changed(window)
                end
                TooltipManager.show_on_hover(L("tooltip_invert_categories"))

                GUI:Spacing()

                GUI:PushItemWidth(-1)
                window.category_search_text = window.category_search_text or ""
                local new_search, search_changed = GUI:InputText("##CategorySearch", window.category_search_text)
                if search_changed then
                    window.category_search_text = new_search
                end
                GUI:PopItemWidth()
                TooltipManager.show_on_hover(L("tooltip_category_search"))

                GUI:Spacing()
            end

            local item_height = GUI:GetTextLineHeightWithSpacing()
            local max_display_items = 20
            local display_items = math.min(num_categories, max_display_items)
            local category_height = item_height * display_items + 16

            GUI:BeginChild("CategoriesScroll", 0, category_height, true)

            if num_categories > 0 then
                if not window.filters.category_states then
                    window.filters.category_states = {}
                end

                local search_lower = (window.category_search_text or ""):lower()
                for _, cat in ipairs(categories) do
                    if cat ~= "All" then
                        if search_lower == "" or cat:lower():find(search_lower, 1, true) then
                            local current_state = window.filters.category_states[cat] or 0
                            local is_included = current_state == 1
                            local is_excluded = current_state == 2
                            local tooltip_text = is_excluded and L("tooltip_hide_category_messages", cat) or L("tooltip_show_category_messages", cat)

                            local left_clicked, right_clicked = render_selectable_filter(cat, is_included, is_excluded, tooltip_text)

                            if left_clicked then
                                if current_state == 1 then
                                    window.filters.category_states[cat] = 0
                                else
                                    window.filters.category_states[cat] = 1
                                end
                                sync_category_maps_from_states(window, categories)
                                on_any_filter_changed(window)
                            elseif right_clicked then
                                if current_state == 2 then
                                    window.filters.category_states[cat] = 0
                                else
                                    window.filters.category_states[cat] = 2
                                end
                                sync_category_maps_from_states(window, categories)
                                on_any_filter_changed(window)
                            end
                        end
                    end
                end
            end

            GUI:EndChild()
        end

        GUI:Separator()

        if GUI:Button(L("filter_clear_all"), 100, 0) then
            window:clear_all_filters()

            ensure_filter_tables(window)
            sync_level_maps_from_states(window)
            local categories = window:get_available_categories()
            sync_category_maps_from_states(window, categories)
            on_any_filter_changed(window)
            window:update_quick_filter_from_levels()
        end
        GUI:SameLine()
        if GUI:Button(L("filter_close"), 100, 0) then
            window.filter_window_open = false
        end

        GUI:PopStyleVar()
    end

    GUI:End()
end

BetterConsole.FiltersWindow = M
    UIComponents.FiltersWindow = M
end

-- MetadataPanel module displaying detailed log entry information
-- Shows timestamp, level, category, message, and nested data structures
do
local M = {}

local COLORS = {
    STRING      = { 0.4, 0.9, 1.0 - 0.1, 1.0 },
    NUMBER      = { 0.5, 0.8, 1.0,       1.0 },
    BOOLEAN     = { 1.0, 0.7, 0.3,       1.0 },
    NIL         = { 0.5, 0.5, 0.5,       1.0 },
    TABLE_BRACE = { 0.8, 0.8, 0.8,       1.0 },
    KEY         = { 1.0, 0.8, 0.3,       1.0 },
}

-- Renders colored text using RGBA color array
-- @param color table: RGBA color values {r, g, b, a}
-- @param s string: Text to display
local function text_colored(color, s)
    GUI:TextColored(color[1], color[2], color[3], color[4], s)
end

-- Recursively renders Lua value with syntax-highlighted colors
-- Handles strings, numbers, booleans, tables with circular reference detection
-- @param value any: Value to render
-- @param indent string: Current indentation string
-- @param visited table: Set of visited tables to detect circular references
-- @param depth number: Current recursion depth
-- @param max_depth number: Maximum recursion depth before truncating
local function render_value_colored(value, indent, visited, depth, max_depth)
    indent   = indent or ""
    visited  = visited or {}
    depth    = depth or 0
    max_depth = max_depth or 5

    if depth > max_depth then
        text_colored(COLORS.NIL, indent .. "[MAX DEPTH]")
        return
    end

    local t = type(value)

    if value == nil then
        text_colored(COLORS.NIL, indent .. "nil")

    elseif t == "string" then
        if value:find("\n") then
            local lines = {}
            for line in value:gmatch("[^\n]+") do
                lines[#lines + 1] = line
            end

            local limit = math.min(#lines, 10)
            for i = 1, limit do
                text_colored(COLORS.STRING, indent .. "  " .. lines[i])
            end
            if #lines > 10 then
                text_colored(
                    COLORS.NIL,
                    indent .. "  ... [" .. (#lines - 10) .. " more lines]"
                )
            end
        else
            local display = (#value > 100)
                and (value:sub(1, 100) .. "... [" .. (#value - 100) .. " more chars]")
                or value
            text_colored(COLORS.STRING, indent .. display)
        end

    elseif t == "number" then
        text_colored(COLORS.NUMBER, indent .. tostring(value))

    elseif t == "boolean" then
        text_colored(COLORS.BOOLEAN, indent .. tostring(value))

    elseif t == "table" then
        if visited[value] then
            text_colored(COLORS.NIL, indent .. "[CIRCULAR]")
            return
        end
        visited[value] = true

        local is_array = true
        local array_size = 0
        for k, _ in pairs(value) do
            array_size = array_size + 1
            if type(k) ~= "number" then
                is_array = false
                break
            end
        end

        if is_array and array_size > 0 then
            local max_items = 15

            if array_size <= 15 then
                text_colored(COLORS.TABLE_BRACE, indent .. "[")
                GUI:SameLine(0, 0)

                for i = 1, array_size do
                    if i > 1 then
                        text_colored(COLORS.TABLE_BRACE, ", ")
                        GUI:SameLine(0, 0)
                    end

                    local item = value[i]
                    local it = type(item)

                    if it == "string" then
                        local display = (#item > 30) and (item:sub(1, 30) .. "...") or item
                        text_colored(COLORS.STRING, display)
                    elseif it == "number" then
                        text_colored(COLORS.NUMBER, tostring(item))
                    elseif it == "boolean" then
                        text_colored(COLORS.BOOLEAN, tostring(item))
                    elseif it == "table" then
                        text_colored(COLORS.TABLE_BRACE, "{...}")
                    else
                        GUI:Text(tostring(item))
                    end

                    if i < array_size then
                        GUI:SameLine(0, 0)
                    end
                end

                GUI:SameLine(0, 0)
                text_colored(COLORS.TABLE_BRACE, "]")
            else
                text_colored(COLORS.TABLE_BRACE, indent .. "[")
                local count = 0
                for i = 1, array_size do
                    count = count + 1
                    if count > max_items then
                        text_colored(
                            COLORS.NIL,
                            indent .. "  ... [" .. (array_size - max_items) .. " more]"
                        )
                        break
                    end
                    render_value_colored(value[i], indent .. "  ", visited, depth + 1, max_depth)
                end
                text_colored(COLORS.TABLE_BRACE, indent .. "]")
            end
        else

            local items = {}
            for k, v in pairs(value) do
                items[#items + 1] = { key = k, value = v }
            end

            table.sort(items, function(a, b)
                local ta, tb = type(a.key), type(b.key)
                if ta ~= tb then
                    if ta == "number" then return true end
                    if tb == "number" then return false end
                    if ta == "string" then return true end
                    if tb == "string" then return false end
                end
                if ta == "number" or ta == "string" then
                    return a.key < b.key
                end
                return tostring(a.key) < tostring(b.key)
            end)

            local n = #items
            if n <= 3 and depth > 0 then
                text_colored(COLORS.TABLE_BRACE, indent .. "{ ")
                GUI:SameLine(0, 0)

                for i, item in ipairs(items) do
                    if i > 1 then
                        text_colored(COLORS.TABLE_BRACE, ", ")
                        GUI:SameLine(0, 0)
                    end

                    local k, v = item.key, item.value
                    local key_str = (type(k) == "string") and k or ("[" .. tostring(k) .. "]")

                    text_colored(COLORS.KEY, key_str .. ": ")
                    GUI:SameLine(0, 0)

                    local vt = type(v)
                    if vt == "string" then
                        local display = (#v > 20) and (v:sub(1, 20) .. "...") or v
                        text_colored(COLORS.STRING, display)
                    elseif vt == "number" then
                        text_colored(COLORS.NUMBER, tostring(v))
                    elseif vt == "boolean" then
                        text_colored(COLORS.BOOLEAN, tostring(v))
                    elseif vt == "table" then
                        text_colored(COLORS.TABLE_BRACE, "{...}")
                    else
                        GUI:Text(tostring(v))
                    end

                    if i < n then
                        GUI:SameLine(0, 0)
                    end
                end

                GUI:SameLine(0, 0)
                text_colored(COLORS.TABLE_BRACE, " }")
            else
                text_colored(COLORS.TABLE_BRACE, indent .. "{")

                local count = 0
                local max_items = 20

                for i, item in ipairs(items) do
                    count = count + 1
                    if count > max_items then
                        text_colored(
                            COLORS.NIL,
                            indent .. "  ... [" .. (n - max_items) .. " more fields]"
                        )
                        break
                    end

                    local k, v = item.key, item.value
                    local key_str = (type(k) == "string") and k or ("[" .. tostring(k) .. "]")

                    text_colored(COLORS.KEY, indent .. "  " .. key_str .. ":")
                    if type(v) == "table" then
                        render_value_colored(v, indent .. "    ", visited, depth + 1, max_depth)
                    else
                        GUI:SameLine(0, 1)
                        local vt = type(v)
                        if vt == "string" then
                            GUI:PushTextWrapPos(0)
                            text_colored(COLORS.STRING, v)
                            GUI:PopTextWrapPos()
                        elseif vt == "number" then
                            text_colored(COLORS.NUMBER, tostring(v))
                        elseif vt == "boolean" then
                            text_colored(COLORS.BOOLEAN, tostring(v))
                        elseif v == nil then
                            text_colored(COLORS.NIL, "nil")
                        else
                            GUI:Text(tostring(v))
                        end
                    end
                end

                text_colored(COLORS.TABLE_BRACE, indent .. "}")
            end
        end

        visited[value] = nil
    else
        GUI:Text(indent .. tostring(value))
    end
end

-- Renders metadata panel showing selected log entry details
-- Displays entry metadata with syntax-highlighted nested structures
-- @param window table: BetterConsole window instance with selected_entry_for_metadata
-- @param width number: Panel width (0 for auto)
-- @param height number: Panel height (0 for auto)
M.render = function(window, width, height)
    if not window then
        return
    end

    width  = width or 0
    height = height or 0

    GUI:BeginChild("MetadataPanel##BetterConsole", width, height, true, 0)

    if not window.selected_entry_for_metadata then
        GUI:TextDisabled("Click on a log entry to view details")
    else
        local entry    = window.selected_entry_for_metadata
        local ts       = entry.time_string or entry.timestamp or "Unknown"
        local level    = (entry.level and entry.level.name) or "Unknown"
        local category = entry.category or "System"
        local color    = entry:get_color()

        GUI:Text("Time: " .. ts)

        GUI:Text("Level: ")
        GUI:SameLine()
        GUI:PushStyleColor(GUI.Col_Text, color[1], color[2], color[3], color[4])
        GUI:Text(level)
        GUI:PopStyleColor()

        GUI:PushStyleColor(GUI.Col_Text, 0.2, 0.8, 1.0, 1.0)
        GUI:Text("Category: " .. category)
        GUI:PopStyleColor()

        GUI:Separator()

        if entry.message and #entry.message > 0 then
            text_colored({ 0.7, 0.7, 0.7, 1.0 }, "Message:")
            GUI:PushTextWrapPos(0)
            GUI:PushStyleColor(GUI.Col_Text, color[1], color[2], color[3], color[4])
            GUI:TextWrapped(entry.message)
            GUI:PopStyleColor()
            GUI:PopTextWrapPos()
            GUI:Separator()
        end

        if entry.data and type(entry.data) == "table" then
            local has_data = false
            for _ in pairs(entry.data) do
                has_data = true
                break
            end

            if has_data then
                text_colored({ 0.7, 0.7, 0.7, 1.0 }, "Metadata:")
                GUI:Spacing()

                local sorted_keys = {}
                for k in pairs(entry.data) do
                    sorted_keys[#sorted_keys + 1] = k
                end
                table.sort(sorted_keys, function(a, b)
                    local ta, tb = type(a), type(b)
                    if ta ~= tb then
                        if ta == "number" then return true end
                        if tb == "number" then return false end
                        if ta == "string" then return true end
                        if tb == "string" then return false end
                    end
                    if ta == "number" or ta == "string" then
                        return a < b
                    end
                    return tostring(a) < tostring(b)
                end)

                for _, k in ipairs(sorted_keys) do
                    local v = entry.data[k]
                    text_colored(COLORS.KEY, "  " .. tostring(k) .. ":")
                    render_value_colored(v, "    ", {}, 0, 5)
                    GUI:Spacing()
                end
            else
                text_colored({ 0.5, 0.5, 0.5, 1.0 }, "Metadata:")
                GUI:Spacing()
                GUI:TextDisabled("  No additional metadata available")
            end
        else
            text_colored({ 0.5, 0.5, 0.5, 1.0 }, "Metadata:")
            GUI:Spacing()
            GUI:TextDisabled("  No additional metadata available")
        end
    end

    GUI:EndChild()
end

BetterConsole.MetadataPanel = M
    UIComponents.MetadataPanel = M
end

-- ContextMenu module providing right-click menu for log entries
-- Handles copy operations, filtering actions, and multi-selection operations
do
local M = {}

-- Renders context menu for log entry with copy, filter, and selection options
-- @param window table: BetterConsole window instance
-- @param entry table: LogEntry instance that was right-clicked
-- @param index number: Index of entry in display list
M.render_log_entry_menu = function(window, entry, index)
    local popup_id = window.context_menus.log.popup_id .. tostring(index)

    if GUI:BeginPopup(popup_id) then
        local selected_count = window.selection_manager:get_count()

        local has_selection = selected_count > 0

        if has_selection then
            if GUI:MenuItem("Select all") then
                window:select_all()
            end

            GUI:Separator()
        end

        if GUI:MenuItem("Copy entry to clipboard") then
            window:copy_entry_to_clipboard(entry)
        end

        if GUI:MenuItem("Copy entry value only") then
            window:copy_entry_value_to_clipboard(entry)
        end

        if GUI:MenuItem("Copy metadata") then
            window:copy_metadata_to_clipboard(entry)
        end

        if has_selection then
            local copy_label = "Copy entries to clipboard (" .. selected_count .. " selected)"
            if GUI:MenuItem(copy_label) then
                window:export_selected_entries()
            end
        end

        GUI:Separator()

        if GUI:MenuItem("Filter by this level") then
            window:filter_by_level(entry)
        end

        if GUI:MenuItem("Filter by this category") then
            window:filter_by_category(entry)
        end

        if has_selection and selected_count > 1 then
            if GUI:MenuItem("Smart filter from selection (" .. selected_count .. " selected)") then
                window:smart_filter_from_selection()
            end
            if GUI:IsItemHovered() then
                GUI:SetTooltip("Filter by all levels and categories in selection")
            end
        end

        GUI:Separator()

        if GUI:MenuItem("Show similar entries") then
            window:show_similar_entries(entry)
        end

        GUI:EndPopup()
    end
end

BetterConsole.ContextMenu = M
    UIComponents.ContextMenu = M
end

-- TooltipManager module providing consistent tooltip display utilities
-- Simplifies tooltip rendering with hover detection and warning formatting
do
local M = {}

-- Displays tooltip with specified text
-- @param text string: Tooltip text to display
function M.show(text)
    if not text or text == "" then return end
    GUI:SetTooltip(text)
end

-- Displays warning tooltip with formatted header
-- @param text string: Warning text to display
function M.show_warning(text)
    if not text or text == "" then return end
    local warning_text = "WARNING\n" .. string.rep("-", 7) .. "\n" .. text
    GUI:SetTooltip(warning_text)
end

-- Checks if tooltip should be shown based on item hover state
-- @return boolean: True if previous GUI item is hovered
function M.should_show()
    return GUI:IsItemHovered()
end

-- Shows tooltip only if previous item is hovered
-- @param text string: Tooltip text to display on hover
-- @return boolean: True if tooltip was shown
function M.show_on_hover(text)
    if M.should_show() then
        M.show(text)
        return true
    end
    return false
end

BetterConsole.TooltipManager = M
    UIComponents.TooltipManager = M
end

return UIComponents
