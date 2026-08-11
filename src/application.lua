local Application = {}

-- Localization
local L = function(key, ...)
    if BetterConsole.Localization then
        return BetterConsole.Localization.get(key, ...)
    end
    return key
end

do
local M = {}

local Models = BetterConsole and BetterConsole.Models
local Constants = Models and Models.Constants

local CATEGORY_ALL = (Constants and Constants.Categories and Constants.Categories.ALL) or "All"
local STATUS_DURATION_DEFAULT = (Constants and Constants.Notifications and Constants.Notifications.DEFAULT_DURATION) or 3
local STATUS_DURATION_CLIPBOARD = (Constants and Constants.Notifications and Constants.Notifications.CLIPBOARD_DURATION) or 2
local STATS_CACHE_INTERVAL_MS = (Constants and Constants.Time and Constants.Time.MS_PER_SECOND) or 1000
local MS_PER_SECOND = (Constants and Constants.Time and Constants.Time.MS_PER_SECOND) or 1000
local CATEGORY_PRUNE_INTERVAL_MS = 30000
local DEFAULT_CUSTOM_PRESET_INDEX = (Constants and Constants.Filters and Constants.Filters.DEFAULT_CUSTOM_PRESET_INDEX) or 0
local MEMORY_USAGE_SCALAR = 1024
local EMPTY_SELECTION_MESSAGE = "No entries selected"
local CLIPBOARD_ERROR_CATEGORY = "Console"
local COMMAND_INPUT_FOCUS_TARGET = "input"

local Validators = nil

-- Creates shallow copy of table with all key-value pairs
-- @param source table: Table to copy
-- @return table: New table with copied key-value pairs
local function copy_table(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end

    for key, value in pairs(source) do
        result[key] = value
    end

    return result
end

-- Resets all values in flag table to zero
-- Used for resetting filter state flags
-- @param target table: Table to reset (optional)
-- @return table: Reset table with all values set to 0
local function reset_flag_table(target)
    local table_to_reset = target or {}
    for key in pairs(table_to_reset) do
        table_to_reset[key] = 0
    end
    return table_to_reset
end

-- Checks if table is non-empty and has at least one entry
-- @param tbl any: Value to check
-- @return boolean: True if table has entries
local function has_entries(tbl)
    return type(tbl) == "table" and next(tbl) ~= nil
end

-- Lazy-loads and caches Validators module
-- @return table: Validators module instance
local function get_validators()
    if not Validators then
        Validators = BetterConsole.Validators
    end
    return Validators
end

-- Comparator function for sorting categories with "All" category first
-- @param a string: First category name
-- @param b string: Second category name
-- @return boolean: True if a should come before b
local function category_sort_comparator(a, b)
    if a == CATEGORY_ALL then return true end
    if b == CATEGORY_ALL then return false end
    return a < b
end

M.ConsoleWindow = {}

-- Creates new console window instance with all subsystems initialized
-- Initializes data store, exporters, anti-spam, selection, commands, state, metrics
-- Loads user preferences and sets up auto-save if enabled
-- @return table: Configured console window instance
function M.new()

    local Exporter = BetterConsole.Exporter
    local Store = BetterConsole.Store
    local SpamBlocker = BetterConsole.SpamBlocker
    local SelectionManager = BetterConsole.SelectionManager
    local CommandHandler = BetterConsole.CommandHandler
    local StateManager = BetterConsole.StateManager
    local Metrics = BetterConsole.Metrics

    local export_manager = Exporter.new()
    export_manager:register_exporter("text", Exporter.TextExporter.new())

    local instance = {

        data_store = Store.new(),
        export_manager = export_manager,
        anti_spam = SpamBlocker.new(),
        selection_manager = SelectionManager.new(),
        command_handler = CommandHandler.new(),
        state_manager = StateManager.new(),
        metrics = Metrics.new(),

        is_visible = true,

        display = {
            timestamp = true,
            level = true,
            category = true,
            metadata = true,
            auto_save_logs = false,
            follow_log = true
        },

        search = {
            text = "",
            case_sensitive = false,
            pending_text = "",
            last_input_time = 0,
            is_focused = false
        },

        filters = {
            search = "",
            levels = {
                TRACE = true,
                DEBUG = true,
                INFO = true,
                WARN = true,
                ERROR = true
            },
            categories = {},
            exclude_categories = {},
            exclude_levels = {},
            level_states = {
                TRACE = 0,
                DEBUG = 0,
                INFO = 0,
                WARN = 0,
                ERROR = 0
            },
            category_states = {}
        },

        display_entries = {},
        last_entry_count = 0,
        last_total_added = 0,
        last_processed_count = 0,

        window_flags = GUI.WindowFlags_MenuBar,
        collapsed = nil,

        command_input = "",
        command_history = {},
        command_history_index = 0,
        max_code_history = BetterConsole.Models.Constants.Performance.MAX_CODE_HISTORY,

        focus_target = nil,
        input_widget_id = 0,

        keybind_states = {
            ctrl_f = false,
            ctrl_k = false,
            ctrl_s = false,
            ctrl_e = false,
            ctrl_a = false,
            escape = false
        },

        color_cache = {},
        context_menus = {
            log = { popup_id = "LogEntryContextMenu##BetterConsole" },
            input = { popup_id = "CommandInputContextMenu##BetterConsole" }
        },

        search_cache = {
            highlight_lru = BetterConsole.LRU.new(BetterConsole.Models.Constants.Performance.LRU_CACHE_SIZE)
        },

        search_coroutine = nil,
        search_version = 0,
        search_in_progress = false,
        search_start_time = 0,
        partial_result_count = 0,

        chunk_state = {
            is_processing = false,
            current_index = 1,
            temp_results = {},
            all_entries = nil,
            iterator = nil,
            total_entries = 0,
            start_time = 0,
            total_processed = 0
        },

        cached_categories = { CATEGORY_ALL },
        category_set = { [CATEGORY_ALL] = true },
        category_to_index = { [CATEGORY_ALL] = 1 },

        show_advanced_filters = false,
        filter_window_open = false,

        cached_filter_count = nil,
        cached_filter_details = "",

        cached_stats = nil,
        last_stats_update = 0,

        pending_gc_time = nil,

        jump_to_bottom_button = {
            visible = false,
            threshold = 100,
            fade_alpha = 1.0,
            last_update_time = 0
        },

        current_quick_filter = 1,
        current_category_filter = 1,
        quick_filter_presets = {
            { name = L("preset_all_levels"),  levels = { TRACE = true, DEBUG = true, INFO = true, WARN = true, ERROR = true } },
            { name = L("preset_errors_only"), levels = { TRACE = false, DEBUG = false, INFO = false, WARN = false, ERROR = true } },
            { name = L("preset_warnings_plus"),   levels = { TRACE = false, DEBUG = false, INFO = false, WARN = true, ERROR = true } },
            { name = L("preset_info_plus"),       levels = { TRACE = false, DEBUG = false, INFO = true, WARN = true, ERROR = true } },
            { name = L("preset_debug_plus"),      levels = { TRACE = false, DEBUG = true, INFO = true, WARN = true, ERROR = true } }
        },

        custom_filter_presets = {},
        current_custom_preset = DEFAULT_CUSTOM_PRESET_INDEX,
        preset_name_input = "",

        filter_instant_apply = false,
        last_filter_change_time = 0,
        prefs_need_save = false,

        virtual_scroll = BetterConsole.VirtualScroll.create(),

        show_metadata_panel = true,
        selected_entry_for_metadata = nil,
        metadata_panel = {
            width_ratio = 0.30,
            min_panel_size = 200
        },

        status_notification = {
            message = nil,
            expiry_time = 0
        }
    }

    setmetatable(instance, { __index = M.ConsoleWindow })

    BetterConsole.Prefs.load_user_prefs(instance)

    instance.export_manager:initialize_auto_save(instance.display.auto_save_logs)

    return instance
end

-- Renders console window UI for current frame
-- Delegates to View module for actual rendering
-- @param delta_time number: Time elapsed since last frame in seconds
-- @return any: Render result from View module
function M.ConsoleWindow:render(delta_time)
    return BetterConsole.View.render(self, delta_time)
end

-- Updates display entries based on current filters and search
-- Delegates to Update module for processing
-- @return any: Update result from Update module
function M.ConsoleWindow:update_display_entries()
    return BetterConsole.Update.update_display_entries(self)
end

-- Applies predefined quick filter preset by index
-- Delegates to Update module for filter application
-- @param preset_index number: Index of quick filter preset to apply
-- @return any: Result from Update module
function M.ConsoleWindow:apply_quick_filter_preset(preset_index)
    return BetterConsole.Update.apply_quick_filter_preset(self, preset_index)
end

-- Updates quick filter selection to match current level filters
-- Delegates to Update module for synchronization
-- @return any: Result from Update module
function M.ConsoleWindow:update_quick_filter_from_levels()
    return BetterConsole.Update.update_quick_filter_from_levels(self)
end

-- Creates search coroutine for incremental search processing
-- Delegates to Search module for coroutine creation
-- @param entries table: Entries to search through
-- @param search_text string: Text to search for
-- @param version number: Search version for cancellation
-- @return coroutine: Search coroutine from Search module
function M.ConsoleWindow:create_search_coroutine(entries, search_text, version)
    return BetterConsole.Search.create_search_coroutine(self, entries, search_text, version)
end

-- Resets search progress and cancels active search coroutine
-- Increments search version to invalidate in-progress searches
function M.ConsoleWindow:reset_search_progress()
    if not self.search_coroutine then
        return
    end

    self.search_version = self.search_version + 1
    self.search_coroutine = nil
    self.search_in_progress = false
end

-- Handles filter change events and triggers necessary updates
-- Marks state for refresh, saves preferences, and resets search
-- @param options table: Optional configuration with refresh_quick_filter flag
function M.ConsoleWindow:on_filters_changed(options)
    local opts = options or {}

    self.state_manager:mark_full_refresh()
    self.state_manager:mark_filters_dirty()

    if opts.refresh_quick_filter then
        self:update_quick_filter_from_levels()
    end

    BetterConsole.Prefs.save_user_prefs(self)
    self:reset_search_progress()
end

-- Resets all level filter states to zero for fresh filtering
-- @return table: Reset level states table
function M.ConsoleWindow:reset_level_states()
    local level_states = reset_flag_table(self.filters.level_states)
    for level in pairs(self.filters.levels or {}) do
        level_states[level] = 0
    end

    self.filters.level_states = level_states
    return level_states
end

-- Resets all category filter states to zero for fresh filtering
-- @return table: Reset category states table
function M.ConsoleWindow:reset_category_states()
    self.filters.category_states = reset_flag_table(self.filters.category_states)
    return self.filters.category_states
end

-- Copies text to system clipboard with status notification
-- Shows success notification or logs error on failure
-- @param text string: Text to copy to clipboard
-- @param success_message string: Message to show on successful copy
-- @param error_prefix string: Error message prefix for failures
-- @return boolean: True if copy succeeded
function M.ConsoleWindow:copy_text_to_clipboard(text, success_message, error_prefix)
    local ClipboardHelper = BetterConsole.ClipboardHelper
    local sanitized_text = text or ""
    local success, err = ClipboardHelper.copy(sanitized_text)

    if success then
        self:show_status_notification(success_message, STATUS_DURATION_CLIPBOARD)
        return true
    end

    self:add_entry("ERROR", CLIPBOARD_ERROR_CATEGORY, string.format("%s: %s", error_prefix, tostring(err)))
    return false
end

-- Registers new category in available categories list
-- Maintains sorted category list with "All" category first
-- @param category string: Category name to register
function M.ConsoleWindow:register_category(category)
    if not category or self.category_set[category] then
        return
    end

    self.category_set[category] = true
    table.insert(self.cached_categories, category)

    table.sort(self.cached_categories, category_sort_comparator)

    for i, cat in ipairs(self.cached_categories) do
        self.category_to_index[cat] = i
    end
end

-- Adds warning notification about anti-spam blocking
-- Creates truncated preview of blocked message
-- @param message string: Message that was blocked
-- @param category string: Category of blocked message
-- @return table: Created log entry or nil
function M.ConsoleWindow:add_anti_spam_notification(message, category)
    local Constants = BetterConsole.Models.Constants
    local truncated_message = message
    if #message > Constants.Display.MESSAGE_TRUNCATE_PREVIEW then
        truncated_message = string.format("%s...", string.sub(message, 1, Constants.Display.MESSAGE_TRUNCATE_PREVIEW))
    end
    local notification_message = string.format("Anti-spam: blocking rapid messages from [%s]: '%s'",
        category or "System", truncated_message)

    local entry = self.data_store:add_entry("WARN", "AntiSpam", notification_message, {})
    if entry then
        self:register_category("AntiSpam")
        self.state_manager:mark_entries_dirty()
    end
    return entry
end

-- Adds new log entry with anti-spam filtering and auto-save
-- Registers category, marks state dirty, and triggers auto-save if enabled
-- @param level string: Log level (TRACE, DEBUG, INFO, WARN, ERROR)
-- @param category string: Log category
-- @param message string: Log message
-- @param data table: Optional metadata
-- @return table|boolean: Created log entry or false if blocked by anti-spam
function M.ConsoleWindow:add_entry(level, category, message, data)
    local should_block, block_data, is_first_block = self.anti_spam:should_block_message(level, category, message)

    if should_block then
        if is_first_block then
            self:add_anti_spam_notification(message, category)
        end
        return false
    end

    local entry = self.data_store:add_entry(level, category, message, data)
    if entry then
        self:register_category(category)
        self.state_manager:mark_entries_dirty()

        if self.display.auto_save_logs then
            self.export_manager:append_log_entry(entry)
        end
    end
    return entry
end

-- Gets cached color for log entry's level with fallback
-- Caches color by level name for performance
-- @param entry table: Log entry to get color for
-- @return table: RGBA color array {r, g, b, a}
function M.ConsoleWindow:get_cached_color(entry)
    if not (entry and entry.level and entry.level.name) then
        return {1.0, 1.0, 1.0, 1.0}
    end

    local level_name = entry.level.name
    local cached_color = self.color_cache[level_name]

    if cached_color then
        return cached_color
    end

    local ErrorHandler = BetterConsole.ErrorHandler
    local success, result = ErrorHandler.try_catch(function() return entry:get_color() end, "get_cached_color")
    local color = success and result or {1.0, 1.0, 1.0, 1.0}
    self.color_cache[level_name] = color
    return color
end

-- Renders text with search term highlighting
-- Falls back to regular text wrapping if no search term
-- @param text string: Text to render
-- @param search_text string: Search term to highlight
function M.ConsoleWindow:render_highlighted_text(text, search_text)
    if not (search_text and search_text ~= "") then
        GUI:TextWrapped(text)
        return
    end

    local segments = self:get_cached_highlight_segments(text, search_text)
    self:render_text_segments(segments)
end

-- Gets cached highlight segments for text with search term
-- Uses LRU cache with truncated keys for large text
-- @param text string: Text to segment
-- @param search_text string: Search term for highlighting
-- @return array: Array of text segments with highlight flags
function M.ConsoleWindow:get_cached_highlight_segments(text, search_text)

    local Constants = BetterConsole.Models.Constants
    local cache_key
    if #text > Constants.Caching.HIGHLIGHT_CACHE_KEY_MAX then
        cache_key = string.format("%s#%d|%s",
            string.sub(text, 1, Constants.Caching.HIGHLIGHT_CACHE_KEY_TRUNCATE),
            #text,
            search_text:lower())
    else
        cache_key = string.format("%s|%s", text, search_text:lower())
    end
    local cached = self.search_cache.highlight_lru:get(cache_key)

    if cached then
        return cached
    end

    local segments = self:create_highlight_segments(text, search_text)
    self.search_cache.highlight_lru:put(cache_key, segments)

    return segments
end

-- Creates text segments with highlight markers for search term
-- Performs case-insensitive search and marks matching regions
-- @param text string: Text to segment
-- @param search_text string: Search term to highlight
-- @return array: Array of segments with text and highlight flag
function M.ConsoleWindow:create_highlight_segments(text, search_text)
    local search_pattern = search_text:lower()
    local text_to_search = text:lower()
    local segments = {}
    local start_pos = 1

    while start_pos <= #text do
        local match_start, match_end = string.find(text_to_search, search_pattern, start_pos, true)

        if not match_start then
            if start_pos <= #text then
                table.insert(segments, { text = string.sub(text, start_pos), highlight = false })
            end
            break
        end

        if match_start > start_pos then
            table.insert(segments, { text = string.sub(text, start_pos, match_start - 1), highlight = false })
        end

        table.insert(segments, { text = string.sub(text, match_start, match_end), highlight = true })
        start_pos = match_end + 1
    end

    return segments
end

-- Renders text segments with highlighted portions in orange
-- Uses tight spacing to create continuous text appearance
-- @param segments array: Array of segments with text and highlight flag
function M.ConsoleWindow:render_text_segments(segments)
    GUI:PushStyleVar(GUI.StyleVar_ItemSpacing, { 0, -2 })
    GUI:PushStyleVar(GUI.StyleVar_FramePadding, { 0, 0 })

    for i, segment in ipairs(segments) do
        if i > 1 then
            GUI:SameLine(0, 0)
        end

        if segment.highlight then
            local color = {1.0, 0.65, 0.0, 1.0}
            GUI:PushStyleColor(GUI.Col_Text, color[1], color[2], color[3], color[4])
            GUI:Text(segment.text)
            GUI:PopStyleColor()
        else
            GUI:Text(segment.text)
        end
    end

    GUI:PopStyleVar(2)
end

-- Renders detailed tooltip for log entry on hover
-- Shows timestamp, level, category, message preview, and metadata
-- @param entry table: Log entry to display tooltip for
function M.ConsoleWindow:render_entry_tooltip(entry)
    if not entry then
        return
    end

    local Constants = BetterConsole.Models.Constants
    local tooltip_lines = {}

    local timestamp = entry.time_string or entry.timestamp or "Unknown"
    table.insert(tooltip_lines, string.format("Time: %s", timestamp))

    local level = (entry.level and entry.level.name) or "Unknown"
    table.insert(tooltip_lines, string.format("Level: %s", level))

    local category = entry.category or "System"
    table.insert(tooltip_lines, string.format("Category: %s", category))

    if entry.message and #entry.message > 0 then
        local message = entry.message
        if #message > Constants.Clipboard.MAX_TOOLTIP_LENGTH then
            message = string.format("%s...", string.sub(message, 1, Constants.Clipboard.MAX_TOOLTIP_LENGTH))
        end
        table.insert(tooltip_lines, "")
        table.insert(tooltip_lines, "Message:")
        table.insert(tooltip_lines, message)
    end

    if entry.data and type(entry.data) == "table" then
        local has_data = false
        for k, v in pairs(entry.data) do
            has_data = true
            break
        end

        if has_data then
            table.insert(tooltip_lines, "")
            table.insert(tooltip_lines, "Metadata:")
            for k, v in pairs(entry.data) do
                local value_str = BetterConsole.Strx.serialize_value(v)
                if #value_str > Constants.Clipboard.MAX_METADATA_PREVIEW then
                    value_str = string.format("%s...", string.sub(value_str, 1, Constants.Clipboard.MAX_METADATA_PREVIEW))
                end
                table.insert(tooltip_lines, string.format("  %s: %s", tostring(k), value_str))
            end
        end
    end

    local tooltip_text = table.concat(tooltip_lines, "\n")
    GUI:SetTooltip(tooltip_text)
end

-- Renders context menu for log entry
-- Delegates to ContextMenu module for menu rendering
-- @param entry table: Log entry to show menu for
-- @param index number: Index of entry in display list
function M.ConsoleWindow:render_context_menu(entry, index)
    BetterConsole.ContextMenu.render_log_entry_menu(self, entry, index)
end

-- Rebuilds the category structures from the entries currently retained
-- register_category keeps them current as entries arrive, so this exists only
-- to drop categories whose entries have since rolled out of the store. It
-- rewrites all three structures together; replacing cached_categories alone
-- leaves category_set claiming a pruned category is still registered, after
-- which register_category refuses to re-add it and it never reappears.
function M.ConsoleWindow:rebuild_category_cache()
    local categories = { CATEGORY_ALL }
    local category_set = { [CATEGORY_ALL] = true }

    local entries = self.data_store:get_entries()
    if type(entries.iterate) == "function" then
        for _, entry in entries:iterate() do
            local category = entry and entry.category
            if category and not category_set[category] then
                categories[#categories + 1] = category
                category_set[category] = true
            end
        end
    end

    table.sort(categories, category_sort_comparator)

    local category_to_index = {}
    for index, name in ipairs(categories) do
        category_to_index[name] = index
    end

    self.cached_categories = categories
    self.category_set = category_set
    self.category_to_index = category_to_index
    self.last_category_prune = os.clock() * MS_PER_SECOND
end

-- Gets list of available categories from log entries
-- A read, not a scan: register_category adds each new category as its first
-- entry arrives, so the cache is already current. The full rebuild only prunes
-- rolled-out categories and is rate limited, because it costs 13ms with a full
-- store and every intercepted message marks the categories dirty, which had it
-- running on every frame.
-- @return array: Sorted array of category names with "All" first
function M.ConsoleWindow:get_available_categories()
    if self.state_manager:needs_categories_update() then
        self.state_manager:clear_categories_dirty()

        local now = os.clock() * MS_PER_SECOND
        if not self.last_category_prune
            or (now - self.last_category_prune) >= CATEGORY_PRUNE_INTERVAL_MS then
            self:rebuild_category_cache()
        end
    end

    return self.cached_categories
end

-- Clears all log entries from console
-- Delegates to command handler for execution
-- @return any: Result from command handler
function M.ConsoleWindow:clear()
    return self.command_handler:execute("clear", self)
end

-- Clears all active filters and resets to defaults
-- Delegates to command handler for execution
-- @return any: Result from command handler
function M.ConsoleWindow:clear_all_filters()
    return self.command_handler:execute("clear_filters", self)
end

-- Saves current filter settings as named preset
-- Validates preset name and checks for duplicates before saving
-- @param name string: Name for the filter preset
-- @return boolean: True if preset was saved successfully
function M.ConsoleWindow:save_current_filter_as_preset(name)
    local validators = get_validators()

    local ok, result = validators.validate_preset_name(name)
    if not ok then
        self:add_entry("WARN", "Console", result)
        return false
    end
    local valid_name = result

    for _, preset in ipairs(self.custom_filter_presets) do
        if preset.name == valid_name then
            self:add_entry("WARN", "Console", string.format("Preset name already exists: %s", valid_name))
            return false
        end
    end

    local preset = {
        name = valid_name,
        filters = {
            levels = copy_table(self.filters.levels),
            categories = copy_table(self.filters.categories),
            exclude_levels = copy_table(self.filters.exclude_levels),
            exclude_categories = copy_table(self.filters.exclude_categories)
        }
    }

    table.insert(self.custom_filter_presets, preset)
    BetterConsole.Prefs.save_user_prefs(self)

    self:show_status_notification(string.format("Saved filter preset: %s", valid_name), STATUS_DURATION_DEFAULT)
    return true
end

-- Applies saved filter preset by index
-- Restores level filters, category filters, and exclusions from preset
-- @param index number: Index of preset to apply (1-based)
-- @return boolean: True if preset was applied successfully
function M.ConsoleWindow:apply_filter_preset(index)
    if index < 1 or index > #self.custom_filter_presets then
        return false
    end

    local preset = self.custom_filter_presets[index]
    if not preset then
        return false
    end

    local preset_filters = preset.filters or {}
    local level_filters = preset_filters.levels or {}
    local level_targets = self.filters.levels or {}

    for level in pairs(level_targets) do
        level_targets[level] = level_filters[level] or false
    end
    for level, enabled in pairs(level_filters) do
        level_targets[level] = enabled
    end

    self.filters.categories = copy_table(preset_filters.categories)
    self.filters.exclude_levels = copy_table(preset_filters.exclude_levels)
    self.filters.exclude_categories = copy_table(preset_filters.exclude_categories)

    self.current_custom_preset = index
    self:on_filters_changed({ refresh_quick_filter = true })

    self:show_status_notification(string.format("Applied filter preset: %s", preset.name), STATUS_DURATION_DEFAULT)
    return true
end

-- Deletes filter preset at specified index
-- Updates current preset index if necessary after deletion
-- @param index number: Index of preset to delete (1-based)
-- @return boolean: True if preset was deleted successfully
function M.ConsoleWindow:delete_filter_preset(index)
    if index < 1 or index > #self.custom_filter_presets then
        return false
    end

    local preset = self.custom_filter_presets[index]
    local name = preset.name

    table.remove(self.custom_filter_presets, index)

    if self.current_custom_preset == index then
        self.current_custom_preset = DEFAULT_CUSTOM_PRESET_INDEX
    elseif self.current_custom_preset > index then
        self.current_custom_preset = self.current_custom_preset - 1
    end

    BetterConsole.Prefs.save_user_prefs(self)

    self:show_status_notification(string.format("Deleted filter preset: %s", name), STATUS_DURATION_DEFAULT)
    return true
end

-- Gets console statistics with caching
-- Returns cached stats if still valid based on cache interval
-- @return table: Statistics including total entries, displayed entries, memory usage
function M.ConsoleWindow:get_stats()

    local current_time = os.clock() * STATS_CACHE_INTERVAL_MS
    if self.cached_stats and (current_time - self.last_stats_update) < STATS_CACHE_INTERVAL_MS then
        return self.cached_stats
    end

    self.cached_stats = {
        total_entries = self.data_store:get_entry_count(),
        displayed_entries = #self.display_entries,
        memory_usage = collectgarbage("count") * MEMORY_USAGE_SCALAR,
        capacity = BetterConsole.Models.Constants.Performance.MAX_ENTRIES,
        is_enabled = true,
        min_level = "TRACE"
    }
    self.last_stats_update = current_time

    return self.cached_stats
end

-- Shows temporary status notification message
-- Sets message and expiry time for display in UI
-- @param message string: Notification message to display
-- @param duration_seconds number: Optional duration in seconds (defaults to 3)
function M.ConsoleWindow:show_status_notification(message, duration_seconds)
    duration_seconds = duration_seconds or STATUS_DURATION_DEFAULT
    self.status_notification.message = message
    self.status_notification.expiry_time = os.clock() + duration_seconds
end

-- Exports current log entries to clipboard
-- Delegates to command handler for export execution
-- @return any: Result from command handler
function M.ConsoleWindow:export_to_clipboard()
    return self.command_handler:execute("export", self)
end

-- Copies single log entry's full display text to clipboard
-- @param entry table: Log entry to copy
function M.ConsoleWindow:copy_entry_to_clipboard(entry)
    if not entry then
        return
    end

    local text = entry:get_display_text()
    self:copy_text_to_clipboard(text, "Copied log entry to clipboard", "Failed to copy entry")
end

-- Copies only log entry's message text to clipboard
-- @param entry table: Log entry to copy message from
function M.ConsoleWindow:copy_entry_value_to_clipboard(entry)
    if not entry then
        return
    end

    self:copy_text_to_clipboard(entry.message or "", "Copied log entry message to clipboard", "Failed to copy entry message")
end

-- Copies log entry's metadata to clipboard as formatted text
-- Shows warning if entry has no metadata
-- @param entry table: Log entry to copy metadata from
function M.ConsoleWindow:copy_metadata_to_clipboard(entry)
    if not entry then
        return
    end

    if not has_entries(entry.data) then
        self:add_entry("WARN", "Console", "No metadata to copy")
        return
    end

    local ClipboardHelper = BetterConsole.ClipboardHelper
    local text = ClipboardHelper.serialize_metadata(entry.data)
    self:copy_text_to_clipboard(text, "Copied metadata to clipboard", "Failed to copy metadata")
end

-- Sets search filter to show entries similar to given entry
-- Uses entry's message as search term and triggers full refresh
-- @param entry table: Log entry to find similar entries for
function M.ConsoleWindow:show_similar_entries(entry)
    if not entry then return end

    local search_text = entry.message or ""
    self.search.text = search_text
    self.search.pending_text = search_text
    self.search.last_input_time = 0
    self.search.is_focused = false
    self.filters.search = search_text
    self.state_manager:mark_full_refresh()

    self:add_entry("INFO", "Console", string.format("Showing similar entries to: %s", search_text))
end

-- Filters console to show only entries with same level as given entry
-- Resets all level filters and enables only the specified level
-- @param entry table: Log entry whose level to filter by
function M.ConsoleWindow:filter_by_level(entry)
    if not entry or not entry.level or not entry.level.name then
        return
    end

    local level_name = entry.level.name
    local level_states = self:reset_level_states()
    level_states[level_name] = 1

    self:on_filters_changed({ refresh_quick_filter = true })
    self:add_entry("INFO", "Console", string.format("Filtering by level: %s", level_name))
end

-- Filters console to show only entries with same category as given entry
-- Resets all category filters and enables only the specified category
-- @param entry table: Log entry whose category to filter by
function M.ConsoleWindow:filter_by_category(entry)
    if not entry or not entry.category then
        return
    end

    local category_states = self:reset_category_states()
    category_states[entry.category] = 1

    self:on_filters_changed()
    self:add_entry("INFO", "Console", string.format("Filtering by category: %s", entry.category))
end

-- Creates smart filter from selected entries
-- Filters by unique levels and categories from all selected entries
function M.ConsoleWindow:smart_filter_from_selection()
    local selected_entries = self:get_selected_entries()

    if #selected_entries == 0 then
        self:add_entry("WARN", "Console", EMPTY_SELECTION_MESSAGE)
        return
    end

    local level_states = self:reset_level_states()
    local category_states = self:reset_category_states()
    local level_set = {}
    local category_set = {}

    for _, entry in ipairs(selected_entries) do
        local level_name = entry.level and entry.level.name
        if level_name then
            level_set[level_name] = true
            level_states[level_name] = 1
        end

        if entry.category then
            category_set[entry.category] = true
            category_states[entry.category] = 1
        end
    end

    self:on_filters_changed({ refresh_quick_filter = true })

    local level_count = 0
    for _ in pairs(level_set) do
        level_count = level_count + 1
    end

    local cat_count = 0
    for _ in pairs(category_set) do
        cat_count = cat_count + 1
    end

    self:add_entry("INFO", "Console", string.format("Smart filter: %d level(s), %d categor%s",
        level_count, cat_count, cat_count == 1 and "y" or "ies"))
end

-- Exports single log entry selection to clipboard with error handling
-- Shows status notification on success or logs error on failure
-- @param entry table: Log entry to export
function M.ConsoleWindow:export_entry_selection(entry)
    if not entry then return end

    local ErrorHandler = BetterConsole.ErrorHandler
    local ClipboardHelper = BetterConsole.ClipboardHelper

    local success, result = ErrorHandler.try_catch(function()
        return entry:get_display_text()
    end, "export_entry_selection")

    if success then
        local copy_success, copy_err = ClipboardHelper.copy(result)
        if copy_success then
            self:show_status_notification("Entry exported to clipboard", STATUS_DURATION_CLIPBOARD)
        else
            ErrorHandler.report_error(self, "export entry to clipboard", copy_err)
        end
    else
        ErrorHandler.report_error(self, "export entry to clipboard", result)
    end
end

-- Executes command from input field and manages command history
-- Adds command to history if not duplicate and maintains history size limit
function M.ConsoleWindow:execute_command_from_input()
    local input = self.command_input
    if input ~= "" then
        self:execute_command(input)

        if self.command_history[#self.command_history] ~= input then
            table.insert(self.command_history, input)
            while #self.command_history > self.max_code_history do
                table.remove(self.command_history, 1)
            end
        end
        self.command_history_index = #self.command_history + 1
    end
    self.command_input = ""
    self.focus_target = COMMAND_INPUT_FOCUS_TARGET
end

-- Executes validated command string
-- Validates command syntax and delegates to command handler
-- @param command string: Command string to execute
-- @return boolean: True if command executed successfully
function M.ConsoleWindow:execute_command(command)
    local validators = get_validators()

    local ok, result = validators.validate_command(command)
    if not ok then
        self:add_entry("WARN", "Console", result)
        return false
    end
    local valid_command = result

    local context = { command = valid_command }
    setmetatable(context, { __index = self })
    return self.command_handler:execute("execute", context)
end

-- Saves current log entries to file with optional filename
-- Validates filename if provided and delegates to command handler
-- @param filename string: Optional filename for log file
-- @return boolean: True if logs were saved successfully
function M.ConsoleWindow:save_logs_to_file(filename)
    local validators = get_validators()

    if filename and filename ~= "" then
        local ok, result = validators.validate_filename(filename)
        if not ok then
            self:add_entry("ERROR", "Console", result)
            return false
        end
        filename = result
    end

    local context = { filename = filename }
    setmetatable(context, { __index = self })
    return self.command_handler:execute("save_logs", context)
end

-- Clears all selected entries
function M.ConsoleWindow:clear_selection()
    self.selection_manager:clear()
end

-- Toggles selection state of entry at index
-- @param index number: Index of entry to toggle
function M.ConsoleWindow:toggle_entry_selection(index)
    self.selection_manager:toggle(index)
end

-- Selects entry at specified index
-- @param index number: Index of entry to select
function M.ConsoleWindow:select_entry(index)
    self.selection_manager:select(index)
end

-- Selects range of entries between start and end indices
-- @param start_index number: Starting index of range
-- @param end_index number: Ending index of range
function M.ConsoleWindow:select_range(start_index, end_index)
    self.selection_manager:select_range(start_index, end_index)
end

-- Selects all currently displayed entries
function M.ConsoleWindow:select_all()
    self.selection_manager:select_all(self.display_entries)
end

-- Gets array of currently selected log entries
-- @return array: Array of selected log entry objects
function M.ConsoleWindow:get_selected_entries()
    return self.selection_manager:get_selected(self.display_entries)
end

-- Exports all selected entries to clipboard
-- Shows warning if no entries are selected
function M.ConsoleWindow:export_selected_entries()
    local selected_entries = self:get_selected_entries()

    if #selected_entries == 0 then
        self:add_entry("WARN", "Console", EMPTY_SELECTION_MESSAGE)
        return
    end

    local success, message = self.export_manager:export_to_clipboard(selected_entries)

    if success then
        local status_message = message or string.format("Exported %d selected entries to clipboard", #selected_entries)
        self:show_status_notification(status_message, STATUS_DURATION_CLIPBOARD)
    else
        self:add_entry("ERROR", "Console", message or "Failed to export selected entries")
    end
end

-- Sanitizes text for clipboard by removing control characters and enforcing length limit
-- @param text string: Text to sanitize
-- @return string: Sanitized text safe for clipboard
function M.ConsoleWindow:sanitize_clipboard_text(text)
    if not text or text == "" then
        return ""
    end

    local Constants = BetterConsole.Models.Constants
    local sanitized = text

    sanitized = sanitized:gsub("[%z\1-\8\11-\31\127]", "")

    if #sanitized > Constants.Clipboard.MAX_CLIPBOARD_LENGTH then
        sanitized = string.sub(sanitized, 1, Constants.Clipboard.MAX_CLIPBOARD_LENGTH)
    end

    return sanitized
end

-- Handles tab completion for command input
-- Searches command history for matches and auto-completes first match
function M.ConsoleWindow:handle_tab_completion()
    local input = self.command_input or ""

    if input:match("^%s*$") then
        return
    end

    local matches = {}
    for i = #self.command_history, 1, -1 do
        local cmd = self.command_history[i]
        if cmd and cmd:sub(1, #input) == input and cmd ~= input then
            local found = false
            for _, match in ipairs(matches) do
                if match == cmd then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(matches, cmd)
            end
        end
    end

    if #matches > 0 then
        self.command_input = matches[1]
        self.input_widget_id = self.input_widget_id + 1
        self.focus_target = COMMAND_INPUT_FOCUS_TARGET
    end
end

BetterConsole.App = M
Application.ConsoleWindow = M
Application.App = M
end

Application.Update = BetterConsole.Update

if BetterConsole.CommandHandler then
    Application.CommandHandler = BetterConsole.CommandHandler
    Application.ClearEntriesCommand = BetterConsole.CommandHandler.ClearEntriesCommand
    Application.ClearFiltersCommand = BetterConsole.CommandHandler.ClearFiltersCommand
    Application.ExecuteCodeCommand = BetterConsole.CommandHandler.ExecuteCodeCommand
    Application.ExportCommand = BetterConsole.CommandHandler.ExportCommand
    Application.SaveLogsCommand = BetterConsole.CommandHandler.SaveLogsCommand
end

return Application
