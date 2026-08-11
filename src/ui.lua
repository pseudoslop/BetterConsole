--[[
    BetterConsole UI Module

    This module provides the main UI layer for the BetterConsole system.
    It contains several sub-modules that handle different aspects of the UI:

    - UI.View: Window rendering, chrome, and event handling
    - UI.Update: Entry filtering, display updates, and state management
    - UI.Keymap: Keyboard shortcuts and input handling
    - UI.Theme: Color schemes and styling utilities
    - UI.VirtualScroll: Virtual scrolling for efficient rendering of large lists

    Dependencies:
    - BetterConsole.Models for constants and data structures
    - GUI library for ImGui bindings
    - Various BetterConsole components (LogList, MenuBar, Header, etc.)
]]

local UI = {}

-- Import constants from BetterConsole modules
local Models = BetterConsole and BetterConsole.Models
local Constants = Models and Models.Constants
local TimeConstants = Constants and Constants.Time
local FiltersConstants = Constants and Constants.Filters
local FilterStates = FiltersConstants and FiltersConstants.States
local GeneralConstants = Constants and Constants.General

-- Localization
local L = function(key, ...)
    if BetterConsole.Localization then
        return BetterConsole.Localization.get(key, ...)
    end
    return key
end

-- Module-level constants
local INITIAL_TIME = 0
local INITIAL_INDEX = (GeneralConstants and GeneralConstants.FIRST_INDEX) or 1
local MS_PER_SECOND = (TimeConstants and TimeConstants.MS_PER_SECOND) or 1000
local FILTER_STATE_CLEARED = (FilterStates and FilterStates.CLEARED) or 0
local FILTER_STATE_INCLUDED = (FilterStates and FilterStates.INCLUDED) or 1

--- Converts seconds to milliseconds
-- @param seconds number The time in seconds
-- @return number Time in milliseconds
local function to_milliseconds(seconds)
    return seconds * MS_PER_SECOND
end

--- Checks if there are entries in the data store but display is empty
-- @param current_count number Current entry count
-- @param display_count number Number of displayed entries
-- @return boolean True if entries exist but display is empty
local function has_entries_but_empty_display(current_count, display_count)
    return current_count > INITIAL_TIME and display_count == INITIAL_TIME
end

--- Checks if a preset enables all log levels
-- @param level_map table Map of log levels to enabled states
-- @return boolean True if all levels are enabled
local function preset_enables_all_levels(level_map)
    if not level_map then
        return false
    end

    local has_levels = false
    for _, enabled in pairs(level_map) do
        if not enabled then
            return false
        end
        has_levels = true
    end

    return has_levels
end

do
--[[
    UI.View Module

    Handles the main window rendering, chrome (window decorations),
    event handling, and layout management for the BetterConsole window.

    Responsibilities:
    - Window creation and state management
    - Event handling (mouse, keyboard, collapse/expand)
    - Layout management (side-by-side vs full-width)
    - Orchestrating render calls to sub-components
]]

local M = {}

-- Window constraints and styling
local WINDOW_MIN_WIDTH = 860
local WINDOW_MIN_HEIGHT = 500
local STYLE_VAR_COUNT = 1
local MOUSE_BUTTON_RIGHT = 1
local KEY_ESCAPE = 27

-- Filter and preference saving
local FILTER_SAVE_DELAY_MS = 200

-- Layout constants
local METADATA_DEFAULT_RATIO = 0.30
local LAYOUT_SPACING = 4
local RESERVED_HEIGHT = 55
local MIN_PANEL_HEIGHT = 100

--- Renders the main window chrome and handles window lifecycle
-- Sets window constraints, manages collapsed state, and executes the main render callback
-- @param self table The window instance
-- @param should_be_open boolean Whether the window should be open
-- @param callback function The function to execute when window is visible
function M.render_window_chrome(self, should_be_open, callback)
    GUI:PushStyleVar(GUI.StyleVar_WindowMinSize, WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT)

    if self.collapsed ~= nil then
        GUI:SetNextWindowCollapsed(self.collapsed, GUI.SetCond_Always)
        self.collapsed = nil
    end

    -- Begin has to be matched by End on every path, so the content callback
    -- and the filter window each get their own pcall and the first failure is
    -- re-raised only once the ImGui stack has been unwound. An error escaping
    -- between Begin and End leaves the window stack unbalanced for the rest of
    -- the frame. Reporting is left to the caller so there is one throttled
    -- error path rather than a d() call every frame.
    local visible, window_open
    local began, begin_err = pcall(function()
        visible, window_open = GUI:Begin("BetterConsole##BetterConsole", should_be_open, self.window_flags)
    end)

    local failure = nil

    if began then
        self.is_visible = visible
        if visible then
            local ok, err = pcall(callback)
            if not ok then
                failure = err
            end
        end
        GUI:End()
    else
        failure = begin_err
    end

    GUI:PopStyleVar(STYLE_VAR_COUNT)

    if began and not window_open and should_be_open then
        if BetterConsole.Init and BetterConsole.Init.set_visible then
            BetterConsole.Init.set_visible(false)
        else
            self.is_visible = false
        end
    end

    local filters_ok, filters_err = pcall(BetterConsole.FiltersWindow.render, self)
    if not filters_ok and not failure then
        failure = filters_err
    end

    if failure then
        error(failure, 0)
    end
end

--- Handles window-level events like mouse interactions, keyboard shortcuts, and deferred saves
-- Processes right-click collapse, filter save delays, preference saves, and garbage collection
-- @param self table The window instance
function M.handle_window_events(self)
    if not GUI:IsWindowCollapsed() then
        if GUI:IsWindowHovered(GUI.HoveredFlags_RootWindow) then
            local mouse_x, mouse_y = GUI:GetMousePos()
            local win_x, win_y = GUI:GetWindowPos()
            local win_width, win_height = GUI:GetWindowSize()
            local title_bar_height = GUI:GetFrameHeight()

            if mouse_y >= win_y and mouse_y <= win_y + title_bar_height and
                mouse_x >= win_x and mouse_x <= win_x + win_width then
                if GUI:IsMouseClicked(MOUSE_BUTTON_RIGHT) then
                    self.collapsed = true
                end
            end
        end
    end

    M.handle_keyboard_shortcuts(self)

    if self.last_filter_change_time > INITIAL_TIME then
        local current_time = to_milliseconds(os.clock())
        local time_since_change = current_time - self.last_filter_change_time

        if time_since_change >= FILTER_SAVE_DELAY_MS then
            if self.state_manager:needs_full_refresh() then
                self.last_filter_change_time = INITIAL_TIME
            end
        end
    end

    if self.prefs_need_save then
        BetterConsole.Prefs.save_user_prefs(self)
        self.prefs_need_save = false
    end

    if self.pending_gc_time and os.clock() >= self.pending_gc_time then
        collectgarbage("collect")
        self.pending_gc_time = nil
    end
end

--- Renders the main content area of the console
-- Orchestrates rendering of menu bar, header, log display, and status bar
-- @param self table The window instance
function M.render_main_content(self)
    BetterConsole.MenuBar.render(self)
    BetterConsole.Header.render(self)

    self.metrics:start_update()
    self:update_display_entries()
    self.metrics:end_update()

    local available_width, available_height = GUI:GetContentRegionAvail()

    if self.show_metadata_panel then
        M.render_side_by_side_layout(self, available_width, available_height)
    else
        M.render_full_width_layout(self)
    end

    BetterConsole.CommandInput.render(self)
    BetterConsole.StatusBar.render(self)
end

--- Renders side-by-side layout with log list and metadata panel
-- Calculates widths based on metadata panel ratio and renders both components
-- @param self table The window instance
-- @param available_width number Available width for the layout
-- @param available_height number Available height for the layout
function M.render_side_by_side_layout(self, available_width, available_height)
    local metadata_ratio = self.metadata_panel.width_ratio or METADATA_DEFAULT_RATIO
    local log_display_width = (available_width - LAYOUT_SPACING) * (1 - metadata_ratio)
    local metadata_width = (available_width - LAYOUT_SPACING) * metadata_ratio

    local panel_height = math.max(MIN_PANEL_HEIGHT, available_height - RESERVED_HEIGHT)

    BetterConsole.LogList.render(self, log_display_width)

    GUI:SameLine(0, LAYOUT_SPACING)

    BetterConsole.MetadataPanel.render(self, metadata_width, panel_height)
end

--- Renders full-width layout with only the log list
-- @param self table The window instance
function M.render_full_width_layout(self)
    BetterConsole.LogList.render(self, INITIAL_TIME)
end

--- Main render entry point for the UI
-- Checks visibility and orchestrates the window render pipeline
-- @param self table The window instance
-- @param delta_time number Time since last frame (unused but available for future use)
function M.render(self, delta_time)
    if not self.is_visible then
        return
    end

    M.render_window_chrome(self, self.is_visible, function()
        M.handle_window_events(self)
        M.render_main_content(self)
    end)
end

--- Handles keyboard shortcuts for window operations
-- Processes global shortcuts and ESC key for clearing selections
-- @param self table The window instance
function M.handle_keyboard_shortcuts(self)
    if BetterConsole.Keymap then
        BetterConsole.Keymap.process_global_shortcuts(self)
    end

    local escape_pressed = GUI:IsKeyDown(KEY_ESCAPE)
    if escape_pressed and not self.search.is_focused then
        if not self.keybind_states.escape then
            self.keybind_states.escape = true
            local selection_manager = self.selection_manager
            local selected_count = (selection_manager and selection_manager.get_count) and selection_manager:get_count() or INITIAL_TIME
            if selected_count > INITIAL_TIME then
                self:clear_selection()
            end
        end
    else
        self.keybind_states.escape = false
    end
end

BetterConsole.View = M
    UI.View = M
end

do
--[[
    UI.Update Module

    Handles updating and filtering of console log entries for display.
    Manages incremental and full filtering, chunked processing for large datasets,
    and search coroutine execution.

    Key Features:
    - Incremental filtering for new entries
    - Full filtering with chunked processing for large datasets
    - Search coroutine management for responsive UI
    - Quick filter presets for common filtering patterns
    - State management for dirty/refresh tracking

    Performance Considerations:
    - Uses chunking to avoid frame drops on large datasets
    - Implements time-budgeted processing per frame
    - Supports coroutine-based search for interruptible operations
]]

local M = {}

local FilterEvaluator = BetterConsole.FilterEvaluator

local PRESET_MIN_INDEX = 1
local NOTIFICATION_DURATION = 3

--- Updates display entries by processing filtering and search operations
-- Main update loop that handles coroutines, chunked filtering, and incremental updates
-- @param self table The window instance
function M.update_display_entries(self)
    if self.data_store and self.data_store.flush_pending then
        self.data_store:flush_pending()
    end

    -- Bounds how long the last autosaved lines can sit unflushed once logging
    -- goes quiet; the write path itself only flushes when more entries arrive.
    if self.export_manager and self.export_manager.flush_auto_save then
        self.export_manager:flush_auto_save()
    end

    local update_start = to_milliseconds(os.clock())
    local current_time = update_start

    if self.search_coroutine then
        local Constants = BetterConsole.Models.Constants
        local start_time = to_milliseconds(os.clock())
        local max_time_per_frame = Constants.Performance.MAX_COROUTINE_TIME_MS
        local coroutine_status = coroutine.status(self.search_coroutine)
        if coroutine_status == "dead" then
            self.search_coroutine = nil
            self.search_in_progress = false
            return
        end

        local status, results, is_complete = coroutine.resume(self.search_coroutine)

        if status then
            if results ~= nil then
                local results_changed = #results ~= #self.display_entries

                if results_changed then
                    self.display_entries = results
                    BetterConsole.VirtualScroll.mark_dirty(self.virtual_scroll)
                end

                if is_complete == true then
                    self.search_coroutine = nil
                    self.search_in_progress = false
                    self.state_manager:clear_full_refresh()
                    self.last_processed_count = self.data_store:get_total_added()

                    if not results_changed then
                        self.display_entries = results
                        BetterConsole.VirtualScroll.mark_dirty(self.virtual_scroll)
                    end
                end
            end
        else
            self.search_coroutine = nil
            self.search_in_progress = false

            if results then
                d("Search coroutine error: " .. tostring(results))
            end
        end
    end

    if self.chunk_state.is_processing then
        local continue_processing = M.apply_filtering_chunked(self, self.chunk_state.all_entries)
        if not continue_processing then
            self.state_manager:clear_full_refresh()
            self.last_processed_count = self.data_store:get_total_added()
        end
        return
    end

    local current_count = self.data_store:get_entry_count()
    local current_total = self.data_store:get_total_added()
    local has_empty_display = has_entries_but_empty_display(current_count, #self.display_entries)
    local entry_count_changed = current_count ~= self.last_entry_count
    local total_entries_changed = current_total ~= self.last_total_added

    if not M.should_refresh_entries(self, current_time) and not has_empty_display and not total_entries_changed then
        self.last_entry_count = current_count
        self.last_total_added = current_total
        self.state_manager:clear_dirty()
        return
    end

    if self.state_manager:needs_full_refresh() or has_empty_display then
        M.apply_filtering(self, self.data_store:get_entries())
        if not self.chunk_state.is_processing then
            self.last_processed_count = self.data_store:get_total_added()
            self.state_manager:clear_full_refresh()
        end
    elseif self.state_manager:has_new_entries() or total_entries_changed then
        local new_entries = self.data_store:get_new_entries(self.last_processed_count)
        if #new_entries > 0 then
            M.apply_incremental_filtering(self, new_entries)
            self.last_processed_count = self.data_store:get_total_added()
        end
        self.state_manager:clear_new_entries()
    end

    self.last_entry_count = current_count
    self.last_total_added = current_total

    self.state_manager:clear_dirty()
end

--- Determines if entries should be refreshed based on state and time
-- @param self table The window instance
-- @param current_time number Current time in milliseconds
-- @return boolean True if entries should be refreshed
function M.should_refresh_entries(self, current_time)
    local is_empty_with_no_history = #self.display_entries == INITIAL_TIME and self.last_entry_count == INITIAL_TIME
    local basic_refresh_needed = self.state_manager:needs_update() or is_empty_with_no_history

    if basic_refresh_needed then
        return true
    end

    local current_count = self.data_store:get_entry_count()
    return current_count ~= self.last_entry_count
end

--- Applies filtering to all entries, using chunking for large datasets
-- Chooses between immediate filtering and chunked filtering based on entry count
-- @param self table The window instance
-- @param all_entries table Collection of entries to filter
function M.apply_filtering(self, all_entries)
    if self.chunk_state.is_processing then
        self.chunk_state.is_processing = false
    end

    FilterEvaluator.ensure_derived_maps(self.filters)

    local entry_count = 0
    if type(all_entries.get_entry_count) == "function" then
        entry_count = all_entries:get_entry_count()
    end

    local Constants = BetterConsole.Models.Constants
    local has_search = self.filters.search and self.filters.search ~= ""
    local use_chunking = entry_count > Constants.Performance.LARGE_DATASET_THRESHOLD or
                        (has_search and entry_count > Constants.Performance.SEARCH_DATASET_THRESHOLD)

    if use_chunking then
        M.apply_filtering_chunked(self, all_entries)
    else
        local results = {}
        local max_results = Constants.Performance.MAX_DISPLAY_RESULTS
        local search_config = { case_sensitive = self.search.case_sensitive }

        if type(all_entries.iterate) == "function" then
            for _, entry in all_entries:iterate() do
                if entry and FilterEvaluator.evaluate_entry(entry, self.filters, search_config) then
                    table.insert(results, entry)
                    if #results >= max_results then
                        break
                    end
                end
            end
        end

        self.display_entries = results
        BetterConsole.VirtualScroll.mark_dirty(self.virtual_scroll)
        self:clear_selection()

        if self.selected_entry_for_metadata then
            local still_exists = false
            for _, entry in ipairs(results) do
                if entry == self.selected_entry_for_metadata then
                    still_exists = true
                    break
                end
            end
            if not still_exists then
                self.selected_entry_for_metadata = nil
            end
        end
    end
end

--- Initializes chunk state for processing large datasets
-- @param chunk_state table State object for chunked processing
-- @param all_entries table Collection of all entries to process
local function initialize_chunk_state(chunk_state, all_entries)
    chunk_state.is_processing = true
    chunk_state.current_index = INITIAL_INDEX
    chunk_state.temp_results = {}
    chunk_state.all_entries = all_entries
    chunk_state.iterator = nil
    chunk_state.total_entries = INITIAL_TIME
    chunk_state.start_time = to_milliseconds(os.clock())
    chunk_state.total_processed = INITIAL_TIME
end

--- Determines if chunked processing should stop early
-- @param chunk_state table Current chunk processing state
-- @param has_search boolean Whether a search filter is active
-- @param min_results number Minimum results needed for search
-- @param max_results number Maximum results to display
-- @return boolean True if processing should stop
local function should_stop_chunking(chunk_state, has_search, min_results, max_results)
    local early_exit = (has_search and #chunk_state.temp_results >= min_results) or
                      #chunk_state.temp_results >= max_results
    return early_exit
end

--- Ensures chunk iterator is initialized and returns it
-- @param chunk_state table Current chunk processing state
-- @return function|nil The iterator function or nil if unavailable
local function ensure_chunk_iterator(chunk_state)
    if chunk_state.iterator then
        return chunk_state.iterator
    end

    if not (chunk_state.all_entries and chunk_state.all_entries.iterate) then
        return nil
    end

    chunk_state.iterator = chunk_state.all_entries:iterate()

    if type(chunk_state.all_entries.get_entry_count) == "function" then
        chunk_state.total_entries = chunk_state.all_entries:get_entry_count()
    else
        chunk_state.total_entries = INITIAL_TIME
    end

    if chunk_state.current_index < INITIAL_INDEX then
        chunk_state.current_index = INITIAL_INDEX
    end

    return chunk_state.iterator
end

--- Resets chunk iterator state
-- @param chunk_state table Current chunk processing state
local function reset_chunk_iterator(chunk_state)
    chunk_state.iterator = nil
    chunk_state.total_entries = INITIAL_TIME
end

--- Processes a single chunk of filtering with time budget
-- Evaluates entries against filters within a frame time budget
-- @param self table The window instance
-- @param chunk_state table Current chunk processing state
-- @param filter_config table Configuration with has_search and search_config
-- @return boolean True if more chunks need processing, false if done
local function process_filter_chunk(self, chunk_state, filter_config)
    local Constants = BetterConsole.Models.Constants
    local chunk_size = Constants.Performance.FILTER_CHUNK_SIZE
    local max_time_ms = Constants.Performance.FILTER_MAX_TIME_MS
    local start_time = to_milliseconds(os.clock())

    local iterator = ensure_chunk_iterator(chunk_state)
    if not iterator then
        return false
    end

    local processed_this_frame = INITIAL_TIME

    while true do
        local raw_index, raw_entry = iterator()

        if raw_index == nil and raw_entry == nil then
            reset_chunk_iterator(chunk_state)
            return false
        end

        local entry = raw_entry
        local entry_index = chunk_state.current_index

        if raw_entry == nil then
            entry = raw_index
        elseif raw_index ~= nil then
            entry_index = raw_index
            if entry_index < chunk_state.current_index then
                entry_index = chunk_state.current_index
            end
        end

        if entry and FilterEvaluator.evaluate_entry(entry, self.filters, filter_config.search_config) then
            table.insert(chunk_state.temp_results, entry)
        end

        processed_this_frame = processed_this_frame + INITIAL_INDEX
        chunk_state.total_processed = chunk_state.total_processed + INITIAL_INDEX
        chunk_state.current_index = entry_index + INITIAL_INDEX

        local elapsed_time = to_milliseconds(os.clock()) - start_time
        local early_exit = should_stop_chunking(
            chunk_state,
            filter_config.has_search,
            Constants.Performance.FILTER_MIN_RESULTS,
            Constants.Performance.MAX_DISPLAY_RESULTS
        )

        if processed_this_frame >= chunk_size or elapsed_time > max_time_ms or early_exit then
            return true
        end
    end

    reset_chunk_iterator(chunk_state)
    return false
end

--- Applies filtering using chunked processing for large datasets
-- Initializes or continues chunked filtering to avoid blocking the UI
-- @param self table The window instance
-- @param all_entries table Collection of entries to filter
-- @return boolean True if more processing is needed, false if complete
function M.apply_filtering_chunked(self, all_entries)
    FilterEvaluator.ensure_derived_maps(self.filters)

    if not self.chunk_state.is_processing then
        initialize_chunk_state(self.chunk_state, all_entries)
    end

    local has_search = self.filters.search and self.filters.search ~= ""
    local should_continue = process_filter_chunk(self, self.chunk_state, {
        has_search = has_search,
        search_config = { case_sensitive = self.search.case_sensitive }
    })

    if not should_continue then
        M.finish_chunked_filtering(self)
    end

    return should_continue
end

--- Finishes chunked filtering and updates display
-- Finalizes chunked processing by setting display entries and resetting state
-- @param self table The window instance
function M.finish_chunked_filtering(self)
    self.display_entries = self.chunk_state.temp_results
    BetterConsole.VirtualScroll.mark_dirty(self.virtual_scroll)
    self:clear_selection()

    if self.selected_entry_for_metadata then
        local still_exists = false
        for _, entry in ipairs(self.chunk_state.temp_results) do
            if entry == self.selected_entry_for_metadata then
                still_exists = true
                break
            end
        end
        if not still_exists then
            self.selected_entry_for_metadata = nil
        end
    end

    self.chunk_state.is_processing = false
    self.chunk_state.current_index = INITIAL_INDEX
    self.chunk_state.temp_results = {}
    self.chunk_state.all_entries = nil
    self.chunk_state.iterator = nil
    self.chunk_state.total_entries = INITIAL_TIME
    self.chunk_state.total_processed = INITIAL_TIME
end

--- Applies filtering to only new entries for incremental updates
-- More efficient than full filtering when only a few entries are added
-- @param self table The window instance
-- @param new_entries table Array of new entries to filter
-- @return number Count of entries added to display
function M.apply_incremental_filtering(self, new_entries)
    FilterEvaluator.ensure_derived_maps(self.filters)

    local Constants = BetterConsole.Models.Constants
    local added_count = INITIAL_TIME
    local max_results = Constants.Performance.MAX_DISPLAY_RESULTS
    local search_config = { case_sensitive = self.search.case_sensitive }

    for _, entry in ipairs(new_entries) do
        if #self.display_entries >= max_results then
            break
        end

        if entry and FilterEvaluator.evaluate_entry(entry, self.filters, search_config) then
            table.insert(self.display_entries, entry)
            added_count = added_count + INITIAL_INDEX
        end
    end

    if added_count > INITIAL_TIME then
        BetterConsole.VirtualScroll.mark_dirty(self.virtual_scroll)
    end

    return added_count
end

--- Applies a quick filter preset by index
-- Updates level states based on preset configuration
-- @param self table The window instance
-- @param preset_index number Index of preset to apply (1-based)
function M.apply_quick_filter_preset(self, preset_index)
    if not preset_index or preset_index < PRESET_MIN_INDEX or preset_index > #self.quick_filter_presets then
        return
    end

    local preset = self.quick_filter_presets[preset_index]
    if not preset or not preset.levels then
        return
    end

    self.filters.level_states = self.filters.level_states or {}
    if preset_enables_all_levels(preset.levels) then
        for level_name in pairs(self.filters.level_states) do
            self.filters.level_states[level_name] = FILTER_STATE_CLEARED
        end
        for level_name in pairs(preset.levels) do
            self.filters.level_states[level_name] = FILTER_STATE_CLEARED
        end
        FilterEvaluator.ensure_derived_maps(self.filters)

        self.state_manager:mark_full_refresh()
        self:show_status_notification("Applied quick filter: " .. preset.name, NOTIFICATION_DURATION)
        return
    end

    for level, enabled in pairs(preset.levels) do
        if enabled then
            self.filters.level_states[level] = FILTER_STATE_INCLUDED
        else
            self.filters.level_states[level] = FILTER_STATE_CLEARED
        end
    end
    FilterEvaluator.ensure_derived_maps(self.filters)

    self.state_manager:mark_full_refresh()
    self:show_status_notification("Applied quick filter: " .. preset.name, NOTIFICATION_DURATION)
end

--- Updates current quick filter selection based on active level filters
-- Checks if current level states match any preset
-- @param self table The window instance
function M.update_quick_filter_from_levels(self)
    FilterEvaluator.ensure_derived_maps(self.filters)
    for i, preset in ipairs(self.quick_filter_presets) do
        local matches = true
        for level, enabled in pairs(preset.levels) do
            if (self.filters.levels[level] or false) ~= enabled then
                matches = false
                break
            end
        end
        if matches then
            self.current_quick_filter = i
            return
        end
    end
end

BetterConsole.Update = M
    UI.Update = M
end

do
--[[
    UI.Keymap Module

    Handles keyboard shortcuts and input processing for the console.
    Provides a unified interface for handling various keyboard events
    including command keys, navigation keys, selection, text input,
    and command history navigation.

    Keyboard Shortcuts Supported:
    - Ctrl+F: Focus search
    - Ctrl+K: Clear console
    - Ctrl+S: Save logs to file
    - Ctrl+E: Export to clipboard
    - Ctrl+A: Select all entries
    - F10: Toggle original console
    - ESC: Clear search or selections
    - Up/Down: Navigate command history
    - Enter: Execute command
    - Tab: Command completion
]]

local M = {}

-- Key code constants for common keys
M.Keys = {
    TAB = 9,
    ENTER = 13,
    ESC = 27,
    UP = 38,
    DOWN = 40,

    CTRL = 17,
    SHIFT = 16,
    ALT = 18,

    A = 65,
    E = 69,
    F = 70,
    K = 75,
    S = 83,

    F10 = 121,
}

-- State tracking to prevent key repeat for control shortcuts
local keybind_states = {
    ctrl_f = false,
    ctrl_k = false,
    ctrl_s = false,
    ctrl_e = false,
    ctrl_a = false,
}

--- Handles command-related keyboard shortcuts
-- Processes Ctrl+K (clear), Ctrl+S (save), Ctrl+E (export)
-- @param window table The window instance
function M.handle_command_keys(window)

    M.handle_ctrl_k(function()
        if window.clear then
            window:clear()
        end
    end)

    M.handle_ctrl_s(function()
        if window.save_logs_to_file then
            window:save_logs_to_file()
        end
    end)

    M.handle_ctrl_e(function()
        if window.export_to_clipboard then
            window:export_to_clipboard()
        end
    end)
end

--- Handles navigation-related keyboard shortcuts
-- Processes Ctrl+F (focus search)
-- @param window table The window instance
function M.handle_navigation_keys(window)

    M.handle_ctrl_f(function()
        if window.focus_search then
            window:focus_search()
        elseif window.focus_target ~= nil then
            window.focus_target = "search"
        end
    end)
end

--- Handles selection-related keyboard shortcuts
-- Processes Ctrl+A (select all)
-- @param window table The window instance
function M.handle_selection_keys(window)

    local ctrl_a = M.is_key_combination(M.Keys.CTRL, M.Keys.A)
    if ctrl_a then
        if not keybind_states.ctrl_a then
            keybind_states.ctrl_a = true
            if window.select_all then
                window:select_all()
            end
        end
    else
        keybind_states.ctrl_a = false
    end
end

--- Handles text input keyboard shortcuts when input is focused
-- Processes Enter (execute command) and Tab (autocomplete)
-- @param is_focused boolean Whether input field is focused
-- @param window table The window instance
function M.handle_text_input_keys(is_focused, window)
    if not is_focused then return end

    M.handle_enter(is_focused, function()
        if window.execute_command_from_input then
            window:execute_command_from_input()
        end
    end)

    M.handle_tab(is_focused, function()
        if window.handle_tab_completion then
            window:handle_tab_completion()
        end
    end)
end

--- Handles command history navigation with arrow keys
-- Processes Up (previous command) and Down (next command)
-- @param is_focused boolean Whether input field is focused
-- @param window table The window instance
function M.handle_command_history_keys(is_focused, window)
    if not is_focused then return end

    M.handle_up_arrow(is_focused, function()
        if window.command_history and #window.command_history > 0 then
            if window.command_history_index <= #window.command_history then
                if window.command_history_index > 1 then
                    window.command_history_index = window.command_history_index - 1
                end
            else
                window.command_history_index = #window.command_history
            end

            window.command_input = window.command_history[window.command_history_index] or ""
            window.input_widget_id = window.input_widget_id + 1
            window.focus_target = "input"
        end
    end)

    M.handle_down_arrow(is_focused, function()
        if window.command_history and #window.command_history > 0 then
            if window.command_history_index <= #window.command_history then
                window.command_history_index = window.command_history_index + 1
                if window.command_history_index > #window.command_history then
                    window.command_input = ""
                else
                    window.command_input = window.command_history[window.command_history_index] or ""
                end
                window.input_widget_id = window.input_widget_id + 1
                window.focus_target = "input"
            end
        end
    end)
end

--- Checks if a key was pressed this frame
-- @param key_code number The key code to check
-- @param repeat_key boolean Whether to allow key repeat (default false)
-- @return boolean True if key was pressed
function M.is_key_pressed(key_code, repeat_key)
    return GUI:IsKeyPressed(key_code, repeat_key or false)
end

--- Checks if a key is currently held down
-- @param key_code number The key code to check
-- @return boolean True if key is down
function M.is_key_down(key_code)
    return GUI:IsKeyDown(key_code)
end

--- Checks if a key combination is active (both keys held)
-- @param modifier number The modifier key code (Ctrl, Shift, Alt)
-- @param key number The main key code
-- @return boolean True if both keys are held
function M.is_key_combination(modifier, key)
    return GUI:IsKeyDown(modifier) and GUI:IsKeyDown(key)
end

--- Handles Ctrl+F keyboard shortcut with state tracking
-- @param callback function Function to call when shortcut is activated
-- @return boolean True if callback was executed
function M.handle_ctrl_f(callback)
    local is_active = M.is_key_combination(M.Keys.CTRL, M.Keys.F)
    if is_active then
        if not keybind_states.ctrl_f then
            keybind_states.ctrl_f = true
            if callback then callback() end
            return true
        end
    else
        keybind_states.ctrl_f = false
    end
    return false
end

function M.handle_ctrl_k(callback)
    local is_active = M.is_key_combination(M.Keys.CTRL, M.Keys.K)
    if is_active then
        if not keybind_states.ctrl_k then
            keybind_states.ctrl_k = true
            if callback then callback() end
            return true
        end
    else
        keybind_states.ctrl_k = false
    end
    return false
end

function M.handle_ctrl_s(callback)
    local is_active = M.is_key_combination(M.Keys.CTRL, M.Keys.S)
    if is_active then
        if not keybind_states.ctrl_s then
            keybind_states.ctrl_s = true
            if callback then callback() end
            return true
        end
    else
        keybind_states.ctrl_s = false
    end
    return false
end

function M.handle_ctrl_e(callback)
    local is_active = M.is_key_combination(M.Keys.CTRL, M.Keys.E)
    if is_active then
        if not keybind_states.ctrl_e then
            keybind_states.ctrl_e = true
            if callback then callback() end
            return true
        end
    else
        keybind_states.ctrl_e = false
    end
    return false
end

function M.handle_f10(callback)
    if M.is_key_pressed(M.Keys.F10, false) then
        if callback then callback() end
        return true
    end
    return false
end

function M.handle_enter(is_focused, callback)
    if is_focused and M.is_key_pressed(M.Keys.ENTER, false) then
        if callback then callback() end
        return true
    end
    return false
end

function M.handle_tab(is_focused, callback)
    if is_focused and M.is_key_pressed(M.Keys.TAB, false) then
        if callback then callback() end
        return true
    end
    return false
end

function M.handle_up_arrow(is_focused, callback)
    if is_focused and M.is_key_pressed(M.Keys.UP, false) then
        if callback then callback() end
        return true
    end
    return false
end

function M.handle_down_arrow(is_focused, callback)
    if is_focused and M.is_key_pressed(M.Keys.DOWN, false) then
        if callback then callback() end
        return true
    end
    return false
end

function M.handle_escape(is_focused, callback)
    if is_focused and M.is_key_pressed(M.Keys.ESC, false) then
        if callback then callback() end
        return true
    end
    return false
end

--- Processes all global keyboard shortcuts for the window
-- Calls handlers for navigation, commands, selection, and F10 toggle
-- @param window table The window instance
function M.process_global_shortcuts(window)
    M.handle_navigation_keys(window)
    M.handle_command_keys(window)
    M.handle_selection_keys(window)

    local init = BetterConsole.Init
    if init and init.is_visible and init.get_show_original_console and init.set_show_original_console then
        if init.is_visible() then
            M.handle_f10(function()
                local current = init.get_show_original_console()
                init.set_show_original_console(not current)
            end)
        end
    end
end

--- Processes keyboard shortcuts for command input field
-- @param is_focused boolean Whether input field is focused
-- @param window table The window instance
function M.process_input_shortcuts(is_focused, window)
    if not is_focused then return end
    M.handle_text_input_keys(is_focused, window)
    M.handle_command_history_keys(is_focused, window)
end

--- Processes keyboard shortcuts for search field
-- Handles ESC to clear search
-- @param is_focused boolean Whether search field is focused
-- @param window table The window instance
function M.process_search_shortcuts(is_focused, window)
    if not is_focused then return end

    M.handle_escape(is_focused, function()
        if window.search then
            window.search.text = ""
            window.search.pending_text = ""
            window.search.last_input_time = to_milliseconds(os.clock())
        end

        if window.filters then
            window.filters.search = ""
        end

        window.state_manager:mark_full_refresh()

        if window.search_coroutine then
            window.search_version = window.search_version + INITIAL_INDEX
            window.search_coroutine = nil
            window.search_in_progress = false
        end
    end)
end

BetterConsole.Keymap = M
    UI.Keymap = M
end

do
--[[
    UI.Theme Module

    Provides color schemes, styling utilities, and themed UI components
    for the BetterConsole interface.

    Features:
    - Predefined color palettes for different UI elements
    - Helper functions for applying colors temporarily
    - Colored text and button utilities
    - Filter chip styling for different filter types
    - Style constants for consistent spacing and sizing
]]

local M = {}

-- Color definitions (RGBA format with values 0.0-1.0)
M.Colors = {
    TEXT_DEFAULT = { 1.0, 1.0, 1.0, 1.0 },
    TEXT_WARNING = { 1.0, 1.0, 0.0, 1.0 },

    BUTTON_SECONDARY = { 0.15, 0.15, 0.15, 1.0 },
    BUTTON_SECONDARY_HOVER = { 0.25, 0.25, 0.25, 1.0 },
    BUTTON_SECONDARY_ACTIVE = { 0.35, 0.35, 0.35, 1.0 },

    CHIP_SEARCH = { 0.2, 0.6, 0.8, 1.0 },
    CHIP_SEARCH_ALT = { 0.2, 0.4, 0.8, 1.0 },
    CHIP_SEARCH_HOVER = { 0.3, 0.5, 0.9, 1.0 },
    CHIP_SEARCH_ACTIVE = { 0.15, 0.35, 0.7, 1.0 },
    CHIP_LEVEL = { 0.3, 0.6, 0.9, 1.0 },
    CHIP_CATEGORY = { 0.3, 0.7, 0.5, 1.0 },
    CHIP_EXCLUDE = { 0.8, 0.3, 0.3, 1.0 },
    CHIP_EXCLUDE_TEXT = { 0.9, 0.3, 0.3, 1.0 },
}

-- Style constants for layout and sizing
M.Styles = {
    ITEM_SPACING = { 8, 4 },

    FILTER_WINDOW_MIN_SIZE = { 300, 570 },

    CATEGORY_DROPDOWN_WIDTH = 150,
}

--- Temporarily applies a color for GUI rendering
-- Pushes color onto GUI stack, executes callback, then pops color
-- @param color_type number GUI color type constant
-- @param color_value table|string RGBA color table or color name from M.Colors
-- @param callback function Function to execute with color applied
function M.with_color(color_type, color_value, callback)
    local color = color_value
    if type(color_value) == "string" then
        color = M.Colors[color_value] or M.Colors.TEXT_DEFAULT
    end
    GUI:PushStyleColor(color_type, unpack(color))
    callback()
    GUI:PopStyleColor()
end

--- Temporarily applies multiple colors for GUI rendering
-- Pushes multiple colors onto GUI stack, executes callback, then pops all colors
-- @param color_pairs table Array of {color_type, color_value} pairs
-- @param callback function Function to execute with colors applied
function M.with_colors(color_pairs, callback)
    local count = 0
    for _, pair in ipairs(color_pairs) do
        local color_type = pair[1]
        local color_value = pair[2]
        local color = color_value
        if type(color_value) == "string" then
            color = M.Colors[color_value] or M.Colors.TEXT_DEFAULT
        end
        GUI:PushStyleColor(color_type, unpack(color))
        count = count + 1
    end
    callback()
    GUI:PopStyleColor(count)
end

--- Renders text with a specific color
-- @param color_value table|string RGBA color table or color name from M.Colors
-- @param text string The text to render
function M.colored_text(color_value, text)
    M.with_color(GUI.Col_Text, color_value, function()
        GUI:Text(text)
    end)
end

--- Renders a button with custom colors
-- @param label string Button label text
-- @param colors table Optional table with button, hover, and active color keys
-- @return boolean True if button was clicked
function M.colored_button(label, colors)
    local color_pairs = {}
    if colors.button then
        table.insert(color_pairs, {GUI.Col_Button, colors.button})
    end
    if colors.hover then
        table.insert(color_pairs, {GUI.Col_ButtonHovered, colors.hover})
    end
    if colors.active then
        table.insert(color_pairs, {GUI.Col_ButtonActive, colors.active})
    end

    local clicked = false
    if #color_pairs > 0 then
        M.with_colors(color_pairs, function()
            clicked = GUI:SmallButton(label)
        end)
    else
        clicked = GUI:SmallButton(label)
    end
    return clicked
end

--- Renders a styled filter chip button
-- @param label string Chip label text
-- @param chip_type string Type of chip: "level", "category", "exclude", or nil for search
-- @return boolean True if chip was clicked
function M.filter_chip(label, chip_type)
    local color = M.Colors.CHIP_SEARCH
    if chip_type == "level" then
        color = M.Colors.CHIP_LEVEL
    elseif chip_type == "category" then
        color = M.Colors.CHIP_CATEGORY
    elseif chip_type == "exclude" then
        color = M.Colors.CHIP_EXCLUDE
    end

    return M.colored_button(label, {button = color})
end

BetterConsole.Theme = M
    UI.Theme = M
end

do
--[[
    UI.VirtualScroll Module

    Implements virtual scrolling for efficient rendering of large log lists.
    Only renders visible items plus a buffer, dramatically improving performance
    when dealing with thousands of log entries.

    Key Features:
    - Viewport calculation based on scroll position
    - Auto-scroll to bottom when new entries arrive
    - Dirty tracking for minimal recalculation
    - Spacer rendering to maintain scroll position
    - Configurable buffer size and item height

    Performance Benefits:
    - Renders only ~50-100 items instead of thousands
    - Maintains smooth 60 FPS even with 10,000+ entries
    - Minimal CPU usage during scrolling
]]

local M = {}

-- Virtual scroll configuration constants
local INITIAL_VISIBLE_END = 30
local AUTO_SCROLL_THRESHOLD = 50

local ESTIMATED_HEIGHT_MULTIPLIER = 2
local BOTTOM_SPACER_HEIGHT = 5
local SCROLL_TOLERANCE = 1

-- Rows wrap, so their real height is neither uniform nor equal to the
-- configured VIRTUAL_SCROLL_ITEM_HEIGHT. render_log_entry already measures each
-- row to size its click target; those measurements feed a smoothed mean here so
-- the spacers and the viewport share one estimate that tracks reality.
local MIN_ROW_HEIGHT = 8
local MAX_ROW_HEIGHT = 600
local ROW_HEIGHT_SMOOTHING = 0.1

-- How far the view must sit clear of the bottom before following lets go.
-- Deliberately much smaller than auto_scroll_threshold, which governs the
-- opposite question of how close counts as back at the bottom. Resuming should
-- be forgiving; releasing should not, or a single wheel notch fails to escape
-- the pin and the view snaps back under the user. This can be tight because
-- ImGui clamping leaves the offset exactly at the maximum, so any real gap is
-- the user's doing.
local FOLLOW_RELEASE_GAP = 8

-- Minimum frames between pins. With a request outstanding every frame the
-- wheel can never win, because the request resolves after wheel input and puts
-- the view back before the movement is observed. Leaving gaps guarantees frames
-- where nothing is queued, so a scroll survives long enough to be seen. At 2 a
-- steadily growing log still re-pins 30 times a second.
local FOLLOW_PIN_INTERVAL_FRAMES = 2

-- Any offset past the real maximum; ImGui clamps a scroll request to the
-- content, so this reaches the bottom without needing to know where it is.
local SCROLL_TO_END = 1e7

--- Creates a new virtual scroll state object
-- @return table New virtual scroll state with default values
function M.create()
    return {
        item_height = BetterConsole.Models.Constants.Performance.VIRTUAL_SCROLL_ITEM_HEIGHT,
        buffer_size = BetterConsole.Models.Constants.Performance.VIRTUAL_SCROLL_BUFFER_SIZE,
        enabled = true,
        visible_start = INITIAL_INDEX,
        visible_end = INITIAL_VISIBLE_END,
        total_height = INITIAL_TIME,
        last_scroll_y = INITIAL_TIME,
        last_available_height = INITIAL_TIME,
        was_at_bottom = false,
        auto_scroll_threshold = AUTO_SCROLL_THRESHOLD,
        is_dirty = true,
        sticky = true,
        follow_applied = false,
        force_follow = false,
        last_observed_scroll = INITIAL_TIME,
        last_total_entries = -1,
        force_pin = true,
        frames_since_pin = 0,
        last_pinned_max = -1,
        row_height = BetterConsole.Models.Constants.Performance.VIRTUAL_SCROLL_ITEM_HEIGHT
    }
end

--- Returns the current estimate of a rendered row's height
-- @param state table Virtual scroll state object
-- @return number Height in pixels, never below MIN_ROW_HEIGHT
local function row_height(state)
    local height = state.row_height or state.item_height
    if not height or height < MIN_ROW_HEIGHT then
        return MIN_ROW_HEIGHT
    end
    return height
end

--- Feeds a measured row height into the running estimate
-- Called from render_log_entry, which measures each row anyway to size its
-- click target. Smoothed rather than taken outright, since row heights vary by
-- an order of magnitude between a short line and a wrapped one.
-- @param state table Virtual scroll state object
-- @param height number Measured height of a rendered row
function M.record_row_height(state, height)
    if not state or type(height) ~= "number" then
        return
    end

    if height < MIN_ROW_HEIGHT or height > MAX_ROW_HEIGHT then
        return
    end

    local current = row_height(state)
    state.row_height = current + (height - current) * ROW_HEIGHT_SMOOTHING
end

--- Checks whether following the newest entry is switched on for this window
-- @param window table The window instance
-- @return boolean True if the follow setting is enabled
local function follow_enabled(window)
    return not (window and window.display and window.display.follow_log == false)
end

--- Requests that the view snap to the newest entry on the next update
-- Used when the setting is switched on, so it takes effect without the user
-- having to scroll to the bottom first.
-- @param state table Virtual scroll state object
function M.request_follow(state)
    if state then
        state.force_follow = true
        state.force_pin = true
        state.sticky = true
    end
end

--- Updates virtual scroll viewport based on current scroll position
-- Calculates which items should be visible and handles auto-scrolling
-- @param state table Virtual scroll state object
-- @param window table The window instance
-- @param total_entries number Total number of entries in the list
-- @param available_height number Available height for rendering
-- @return number, number Start and end indices of visible range
function M.update(state, window, total_entries, available_height)
    if total_entries == INITIAL_TIME then
        return INITIAL_INDEX, INITIAL_TIME
    end

    local scroll_y = GUI:GetScrollY()
    local scroll_max = GUI:GetScrollMaxY()
    local moved_up = scroll_y < state.last_observed_scroll - SCROLL_TOLERANCE

    if state.force_follow then
        state.sticky = true
    elseif state.follow_applied then
        -- Give up following only on both signals at once: the view moved up,
        -- and it now sits clear of the bottom. Either alone produces false
        -- positives. The row-height estimate shifts as different rows scroll
        -- through, which resizes the spacers and makes ImGui clamp the offset
        -- downward with no user involvement, and growth below the viewport
        -- opens a gap that closes again as soon as the pin is applied.
        state.sticky = not (moved_up and scroll_y < scroll_max - FOLLOW_RELEASE_GAP)
    else
        state.sticky = scroll_y >= scroll_max - state.auto_scroll_threshold
    end

    state.last_observed_scroll = scroll_y
    state.was_at_bottom = state.sticky

    local following = state.sticky and follow_enabled(window)
    state.force_follow = false

    if following and not state.follow_applied then
        state.force_pin = true
    end

    if following ~= state.follow_applied then
        -- A transition either way changes which rows belong on screen, so the
        -- cached range must not survive it. Leaving is_dirty clear here is what
        -- stranded the tail range in view after following stopped, drawing the
        -- newest rows far below an empty viewport.
        state.is_dirty = true
    end
    state.follow_applied = following

    local new_total_height = total_entries * row_height(state)
    if math.abs(state.total_height - new_total_height) > SCROLL_TOLERANCE then
        state.total_height = new_total_height
        state.is_dirty = true
    end

    local entries_changed = total_entries ~= state.last_total_entries
    state.last_total_entries = total_entries
    state.frames_since_pin = state.frames_since_pin + 1

    if following then
        -- Only pin when there is something new to follow. Re-pinning on every
        -- frame means a request is always outstanding, and that request is
        -- resolved after wheel input is applied, so it puts the view back
        -- before the movement can be observed and the user cannot break away.
        -- On an idle log this now touches the scroll position not at all.
        -- Pin when the bottom itself has moved, not merely when entries
        -- arrive. Content also grows as the row-height estimate converges, and
        -- keying on entry count alone left the view stranded partway up: it
        -- pinned once, the content then got taller underneath it, and nothing
        -- ever pinned again because no new entries had arrived.
        local bottom_moved = entries_changed
            or math.abs(scroll_max - state.last_pinned_max) > SCROLL_TOLERANCE
        local pinning = state.force_pin
            or (bottom_moved and state.frames_since_pin >= FOLLOW_PIN_INTERVAL_FRAMES)
        if pinning then
            -- Overshoot deliberately. ImGui clamps a scroll request against the
            -- content laid out in the frame it was issued, so this lands on the
            -- true bottom without depending on the row-height estimate.
            GUI:SetScrollY(SCROLL_TO_END)
            state.force_pin = false
            state.frames_since_pin = 0
            state.last_pinned_max = scroll_max
        end

        -- The tail is only the right thing to draw if the view is going to be
        -- at the bottom. Drawing it while parked elsewhere puts the newest rows
        -- below an empty viewport, which is the blank pane this replaced.
        if pinning or scroll_y >= scroll_max - state.auto_scroll_threshold then
            local per_screen = math.ceil(available_height / row_height(state))
                + state.buffer_size * ESTIMATED_HEIGHT_MULTIPLIER
            local visible_start = math.max(INITIAL_INDEX, total_entries - per_screen + INITIAL_INDEX)

            state.visible_start = visible_start
            state.visible_end = total_entries
            state.last_scroll_y = scroll_y
            state.last_available_height = available_height
            state.is_dirty = true

            return visible_start, total_entries
        end
    end

    if math.abs(scroll_y - state.last_scroll_y) > SCROLL_TOLERANCE then
        state.last_scroll_y = scroll_y
        state.is_dirty = true
    end

    if state.last_available_height ~= available_height then
        state.last_available_height = available_height
        state.is_dirty = true
    end

    if state.is_dirty then
        local visible_start, visible_end = M.calculate_viewport(
            state, scroll_y, available_height, total_entries
        )

        state.visible_start = visible_start
        state.visible_end = visible_end
        state.is_dirty = false

        return visible_start, visible_end
    end

    return state.visible_start, state.visible_end
end

--- Calculates which items should be visible based on scroll position
-- @param state table Virtual scroll state object
-- @param scroll_y number Current vertical scroll position in pixels
-- @param available_height number Available height for rendering
-- @param total_entries number Total number of entries
-- @return number, number Start and end indices of visible range (including buffer)
function M.calculate_viewport(state, scroll_y, available_height, total_entries)
    local item_height = row_height(state)
    local buffer_size = state.buffer_size

    local visible_start = math.max(INITIAL_INDEX, math.floor(scroll_y / item_height) - buffer_size)
    local visible_end = math.min(total_entries, math.ceil((scroll_y + available_height) / item_height) + buffer_size)

    -- The estimate can still trail a burst of unusually tall rows, and a start
    -- index past the end of the list renders nothing at all. Show the tail
    -- rather than an empty pane.
    if visible_start > total_entries then
        visible_start = math.max(INITIAL_INDEX, total_entries - buffer_size)
    end

    if visible_end < visible_start then
        visible_end = total_entries
    end

    return visible_start, visible_end
end

--- Marks the virtual scroll state as dirty, requiring recalculation
-- @param state table Virtual scroll state object
-- @param reason string Optional reason for marking dirty (for debugging)
function M.mark_dirty(state, reason)
    state.is_dirty = true
end

--- Renders spacers and log entries for virtual scrolling
-- Renders top spacer for skipped items, visible entries, and bottom spacer
-- @param window table The window instance
-- @param actual_visible_start number Actual start of visible range
-- @param render_start number Start index for rendering entries
-- @param render_end number End index for rendering entries
-- @param total_entries number Total number of entries
function M.render_spacers_with_ranges(window, actual_visible_start, render_start, render_end, total_entries)
    local estimated_item_height = row_height(window.virtual_scroll)

    local top_spacer_start = math.min(actual_visible_start, render_start)
    if top_spacer_start > INITIAL_INDEX then
        local spacer_height = (top_spacer_start - INITIAL_INDEX) * estimated_item_height
        GUI:Dummy(INITIAL_TIME, spacer_height)
    end

    for i = render_start, render_end do
        local entry = window.display_entries[i]
        if entry then
            BetterConsole.LogList.render_log_entry(window, entry, i)
        end
    end

    if render_end < total_entries then
        local spacer_height = (total_entries - render_end) * estimated_item_height
        GUI:Dummy(INITIAL_TIME, spacer_height)
    end

    GUI:Dummy(INITIAL_TIME, BOTTOM_SPACER_HEIGHT)
end

BetterConsole.VirtualScroll = M
    UI.VirtualScroll = M
end

return UI

