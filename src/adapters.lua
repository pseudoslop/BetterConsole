-- Adapter layer providing external system integrations and utility functions for Windows
-- Contains clipboard operations, file I/O, time handling, data export, and persistence
-- Note: FFXIV Minion is Windows-only, so paths are hardcoded for Windows
local Adapters = {}

if not BetterConsole then
    BetterConsole = {}
end

local Models = BetterConsole and BetterConsole.Models
local Constants = Models and Models.Constants
local TimeConstants = Constants and Constants.Time
local FiltersConstants = Constants and Constants.Filters
local GeneralConstants = Constants and Constants.General
local Private = BetterConsole and BetterConsole.Private or {}

local PATH_SEPARATOR = (Private and Private.separator) or "\\"
local ALT_SEPARATOR = "/"
local MODULE_NAME = (Private and Private.module_name) or "BetterConsole"
local LOGS_FOLDER_NAME = "logs"
local PREFS_RELATIVE_PATH = "userPrefs.lua"

-- Normalizes file path separators to Windows standard
-- Converts forward slashes to backslashes and removes duplicate separators
-- @param path string: File path to normalize
-- @return string|nil: Normalized Windows path or nil if invalid input
local function normalize_path(path)
    if type(path) ~= "string" then
        return nil
    end

    path = path:gsub(ALT_SEPARATOR, PATH_SEPARATOR)
    path = path:gsub(PATH_SEPARATOR .. "+", PATH_SEPARATOR)
    return path
end

-- Ensures path ends with Windows path separator (backslash)
-- @param path string: Path to modify
-- @return string: Path with trailing separator
local function ensure_trailing_separator(path)
    if type(path) ~= "string" or path == "" then
        return path
    end

    if path:sub(-1) ~= PATH_SEPARATOR then
        path = path .. PATH_SEPARATOR
    end

    return path
end

-- Resolves module root directory using available path functions
-- Attempts multiple strategies: private config, mod path, startup path
-- @return string: Module folder path or empty string if not found
local function fallback_module_folder()
    if Private and type(Private.module_root) == "string" and Private.module_root ~= "" then
        return ensure_trailing_separator(normalize_path(Private.module_root))
    end

    local base = type(GetLuaModsPath) == "function" and normalize_path(GetLuaModsPath()) or nil
    if base and base ~= "" then
        base = ensure_trailing_separator(base)
        return ensure_trailing_separator(base .. MODULE_NAME)
    end

    local startup = type(GetStartupPath) == "function" and normalize_path(GetStartupPath()) or nil
    if startup and startup ~= "" then
        startup = ensure_trailing_separator(startup)
        return ensure_trailing_separator(startup .. "LuaMods" .. PATH_SEPARATOR .. MODULE_NAME)
    end

    return ""
end

-- Resolves logs directory path using multiple fallback strategies
-- Tries private folder utilities, cached paths, and module-relative paths
-- @return string|nil: Logs directory path or nil if not resolvable
local function resolve_logs_directory()
    if Private and type(Private.ensure_folder) == "function" then
        local ensured = Private.ensure_folder(LOGS_FOLDER_NAME)
        if ensured and ensured ~= "" then
            return ensure_trailing_separator(normalize_path(ensured))
        end
    end

    if Private and Private.paths and Private.paths.logs and Private.paths.logs ~= "" then
        local normalized = ensure_trailing_separator(normalize_path(Private.paths.logs))
        if normalized and normalized ~= "" then
            return normalized
        end
    end

    if Private and type(Private.resolve_folder) == "function" then
        local resolved = Private.resolve_folder(LOGS_FOLDER_NAME)
        resolved = ensure_trailing_separator(normalize_path(resolved))
        if resolved and resolved ~= "" then
            return resolved
        end
    end

    local fallback = fallback_module_folder()
    if fallback ~= "" then
        return ensure_trailing_separator(normalize_path(fallback .. LOGS_FOLDER_NAME))
    end

    return nil
end

-- Resolves user preferences file path using cached or fallback methods
-- @return string|nil: Preferences file path or nil if not resolvable
local function resolve_prefs_file()
    if Private and Private.paths and Private.paths.prefs and Private.paths.prefs ~= "" then
        return normalize_path(Private.paths.prefs)
    end

    if Private and type(Private.resolve_file) == "function" then
        local resolved = Private.resolve_file(PREFS_RELATIVE_PATH)
        if resolved and resolved ~= "" then
            return normalize_path(resolved)
        end
    end

    local module_folder = fallback_module_folder()
    if module_folder ~= "" then
        return normalize_path(module_folder .. PREFS_RELATIVE_PATH)
    end

    return nil
end

local CLIPBOARD_TRUNCATION_SUFFIX = "... [TRUNCATED]"
local DEFAULT_METADATA_MAX_DEPTH = 5
local SERIALIZE_INDENT_STEP = "  "
local SERIALIZE_MAX_DEPTH_PLACEHOLDER = "[MAX DEPTH]"
local SERIALIZE_CIRCULAR_PLACEHOLDER = "[CIRCULAR]"
local SERIALIZE_SIMPLE_TYPES = {
    string = true,
    number = true,
    boolean = true
}

local MS_PER_SECOND = (TimeConstants and TimeConstants.MS_PER_SECOND) or 1000
local DEFAULT_METADATA_PANEL_WIDTH_RATIO = 0.30
local FIRST_INDEX = (GeneralConstants and GeneralConstants.FIRST_INDEX) or 1

local MIN_SERIALIZED_LINE_PARTS = 4
local RING_BUFFER_INDEX_BIAS = 2
local SERIALIZED_LINE_TIMESTAMP_INDEX = 1
local SERIALIZED_LINE_LEVEL_INDEX = 2
local SERIALIZED_LINE_CATEGORY_INDEX = 3
local SERIALIZED_LINE_MESSAGE_INDEX = 4
local SERIALIZED_LINE_DATA_INDEX = 5
local SERIALIZED_LINE_TEMPLATE = "%d|%s|%s|%s|%s\n"

local DEFAULT_EXPORTER_NAME = "text"
local LOG_FILENAME_PREFIX = "console_"
local LOG_FILENAME_EXTENSION = ".log"
local LOG_FILENAME_TIMESTAMP_FORMAT = "%Y%m%d_%H%M%S"
local CLOCK_TIME_FORMAT = "%H:%M:%S"
local CLOCK_DATE_FORMAT = "%Y-%m-%d"
local CLOCK_DATE_TIME_FORMAT = "%Y-%m-%d %H:%M:%S"
local TEXT_TIMESTAMP_FORMAT = CLOCK_DATE_TIME_FORMAT
local AUTOSAVE_LOG_PREFIX = "BetterConsole_log_"
local AUTOSAVE_FLUSH_INTERVAL_MS = 250
local AUTOSAVE_FLUSH_WRITES = 50
local LOG_SESSION_HEADER_PREFIX = "-- BetterConsole Log Session Started at "

local FILE_REPOSITORY_DEFAULT_CACHE_SIZE = 1000
local FILE_REPOSITORY_INDEX_SAVE_INTERVAL = 100
local FILE_REPOSITORY_INDEX_SUFFIX = ".index"
local FILE_REPOSITORY_FLUSH_THRESHOLD = 20
local FILE_REPOSITORY_FLUSH_INTERVAL_MS = 250
local MEMORY_REPOSITORY_DEFAULT_CAPACITY = 50000

local DEFAULT_CUSTOM_PRESET_INDEX = (FiltersConstants and FiltersConstants.DEFAULT_CUSTOM_PRESET_INDEX) or 0
local QUERY_UNBOUNDED_LIMIT = math.huge

local PREFERENCE_DISPLAY_FIELDS = { "timestamp", "level", "category", "metadata", "auto_save_logs", "follow_log" }
local PREFERENCE_SEARCH_FIELDS = { "case_sensitive" }
local PREFERENCE_METADATA_PANEL_FIELDS = { "width_ratio" }

-- Checks if log entry matches filter criteria and search term
-- Performs level, category, and text search filtering
-- @param entry table: Log entry to test
-- @param filter table: Filter criteria (level, category)
-- @param search_lower string: Lowercase search term for text matching
-- @return boolean: True if entry matches all filter conditions
local function entry_matches_filter(entry, filter, search_lower)
    if not entry then
        return false
    end

    if not filter then
        return true
    end

    if filter.level and (not entry.level or entry.level.name ~= filter.level) then
        return false
    end

    if filter.category and entry.category ~= filter.category then
        return false
    end

    if not search_lower then
        return true
    end

    local message = entry.message_lower
    if not message and entry.message ~= nil then
        message = string.lower(tostring(entry.message))
    end

    local category = entry.category_lower
    if not category and entry.category then
        category = string.lower(entry.category)
    end

    local found_in_message = message and string.find(message, search_lower, 1, true)
    local found_in_category = category and string.find(category, search_lower, 1, true)

    return (found_in_message ~= nil) or (found_in_category ~= nil)
end

-- Copies specified fields from source table to target table
-- Used for applying preference settings with field filtering
-- @param target table: Destination table to modify
-- @param source table: Source table containing values
-- @param fields array: List of field names to copy
local function apply_table_fields(target, source, fields)
    if type(target) ~= "table" or type(source) ~= "table" then
        return
    end

    for _, key in ipairs(fields) do
        if source[key] ~= nil then
            target[key] = source[key]
        end
    end
end

-- Applies filter level settings to target filter configuration
-- @param target table: Target filter levels to modify
-- @param levels table: Source filter levels (level_name -> enabled)
local function apply_filter_levels(target, levels)
    if type(target) ~= "table" or type(levels) ~= "table" then
        return
    end

    for level, enabled in pairs(levels) do
        if target[level] ~= nil then
            target[level] = enabled
        end
    end
end

-- Conditionally assigns value to target table if value is not nil
-- @param target table: Target table to modify
-- @param key string: Key to assign
-- @param source_value any: Value to assign if not nil
local function shallow_assign(target, key, source_value)
    if source_value ~= nil then
        target[key] = source_value
    end
end

local PREFERENCE_FILTER_LIST_FIELDS = {
    "categories",
    "exclude_categories",
    "exclude_levels"
}

-- Creates directory if it doesn't exist using Windows file operations
-- @param path string: Directory path to create
-- @return string|nil: Created directory path or nil on failure
local function ensure_directory_exists(path)
    path = normalize_path(path)
    if not path or path == "" then
        return nil
    end

    if FolderExists(path) then
        return ensure_trailing_separator(path)
    end

    if FolderCreate(path) then
        return ensure_trailing_separator(path)
    end

    return nil
end

-- Executes function with error handling using BetterConsole error system
-- Falls back to pcall if error handler is unavailable
-- @param label string: Operation label for error reporting
-- @param fn function: Function to execute with error protection
-- @return boolean, any: Success flag and result or error message
local function try_with_error_handler(label, fn)
    local ErrorHandler = BetterConsole.ErrorHandler
    if ErrorHandler and ErrorHandler.try_catch then
        return ErrorHandler.try_catch(fn, label)
    end

    local ok, result = pcall(fn)
    if ok then
        return true, result
    end

    return false, result
end

-- Creates query state object for tracking pagination and filtering
-- @param options table: Query options containing limit and offset
-- @return table: Query state with counters for pagination
local function create_query_state(options)
    return {
        limit = options.limit or QUERY_UNBOUNDED_LIMIT,
        offset = options.offset or 0,
        skipped = 0,
        matched = 0
    }
end

-- Processes single query entry and updates pagination state
-- @param results array: Results array to append to
-- @param entry table: Log entry to process
-- @param state table: Query state for pagination tracking
-- @return boolean: True if query limit reached
local function process_query_entry(results, entry, state)
    if state.skipped < state.offset then
        state.skipped = state.skipped + 1
        return false
    end

    results[#results + 1] = entry
    state.matched = state.matched + 1
    return state.matched >= state.limit
end

-- Executes filtered query against entry iterator with pagination
-- @param iterator_wrapper table: Iterator providing entry access
-- @param options table: Query options (search, filters, pagination)
-- @return array: Filtered and paginated results
local function query_entries(iterator_wrapper, options)
    local normalized_options = options or {}
    local state = create_query_state(normalized_options)
    local search_lower = normalized_options.search and string.lower(normalized_options.search)
    local results = {}

    for _, entry in iterator_wrapper:iterate() do
        if entry_matches_filter(entry, normalized_options, search_lower) and process_query_entry(results, entry, state) then
            break
        end
    end

    return results
end

do
local M = {}

-- Truncates text to clipboard size limits with suffix indicator
-- @param text string: Text to sanitize for clipboard
-- @return string: Truncated text with suffix if needed
local function sanitize_clipboard_text(text)
    if type(text) ~= "string" then
        return text
    end

    local Constants = BetterConsole.Models.Constants
    local clipboard = Constants and Constants.Clipboard
    local max_length = clipboard and clipboard.MAX_CLIPBOARD_LENGTH

    if not max_length or #text <= max_length then
        return text
    end

    return string.sub(text, 1, max_length) .. CLIPBOARD_TRUNCATION_SUFFIX
end

-- Determines if table has sequential numeric keys (array-like)
-- @param value table: Table to analyze
-- @return boolean, number: True if sequential, count of elements
local function is_sequential_table(value)
    local count = 0
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" then
            return false, count
        end
    end

    return count > 0, count
end

-- Recursively serializes values to readable string format with depth limiting
-- Handles circular references and maintains proper indentation
-- @param value any: Value to serialize
-- @param indent string: Current indentation level
-- @param visited table: Circular reference tracking
-- @param depth number: Current recursion depth
-- @param max_depth number: Maximum allowed depth
-- @return string: Serialized representation
local function serialize_value(value, indent, visited, depth, max_depth)
    local current_indent = indent or ""
    local seen = visited or {}
    local current_depth = depth or 0

    if current_depth > max_depth then
        return current_indent .. SERIALIZE_MAX_DEPTH_PLACEHOLDER
    end

    if value == nil then
        return current_indent .. "nil"
    end

    local value_type = type(value)
    if SERIALIZE_SIMPLE_TYPES[value_type] then
        return current_indent .. tostring(value)
    end

    if value_type ~= "table" then
        return current_indent .. tostring(value)
    end

    if seen[value] then
        return current_indent .. SERIALIZE_CIRCULAR_PLACEHOLDER
    end

    seen[value] = true

    local lines = {}
    local is_array, array_size = is_sequential_table(value)

    if is_array then
        lines[#lines + 1] = current_indent .. "["
        local child_indent = current_indent .. SERIALIZE_INDENT_STEP
        for index = FIRST_INDEX, array_size do
            lines[#lines + 1] = serialize_value(value[index], child_indent, seen, current_depth + 1, max_depth)
        end
        lines[#lines + 1] = current_indent .. "]"
    else
        lines[#lines + 1] = current_indent .. "{"
        local child_indent = current_indent .. SERIALIZE_INDENT_STEP
        for key, child in pairs(value) do
            local key_str = (type(key) == "string") and key or ("[" .. tostring(key) .. "]")
            if type(child) == "table" then
                lines[#lines + 1] = child_indent .. key_str .. ":"
                lines[#lines + 1] = serialize_value(child, child_indent .. SERIALIZE_INDENT_STEP, seen, current_depth + 1, max_depth)
            else
                local serialized_child = serialize_value(child, "", seen, current_depth + 1, max_depth)
                lines[#lines + 1] = child_indent .. key_str .. ": " .. serialized_child
            end
        end
        lines[#lines + 1] = current_indent .. "}"
    end

    seen[value] = nil

    return table.concat(lines, "\n")
end

-- Copies text to system clipboard with error handling and sanitization
-- @param text string: Text to copy
-- @param callback function: Optional callback for async operation result
-- @return boolean, string: Success flag and error message if failed
function M.copy(text, callback)
    if not text or text == "" then
        local err = "No text provided"
        if callback then
            callback(false, err)
        end
        return false, err
    end

    local sanitized = sanitize_clipboard_text(text)
    local success, err = try_with_error_handler("clipboard_copy", function()
        GUI:SetClipboardText(sanitized)
    end)

    local result_err = success and nil or tostring(err)

    if callback then
        callback(success, result_err)
    end

    return success, result_err
end

-- Serializes metadata table to human-readable string format
-- @param data table: Metadata to serialize
-- @param max_depth number: Optional depth limit override
-- @return string: Serialized metadata or empty string
function M.serialize_metadata(data, max_depth)
    if type(data) ~= "table" then
        return ""
    end

    local Constants = BetterConsole.Models.Constants
    local caching = Constants and Constants.Caching
    local effective_max_depth = max_depth or (caching and caching.METADATA_SERIALIZE_MAX_DEPTH) or DEFAULT_METADATA_MAX_DEPTH

    return serialize_value(data, "", {}, 0, effective_max_depth)
end

BetterConsole.Clipboard = M
if BetterConsole.ClipboardHelper == nil then
    BetterConsole.ClipboardHelper = M
end
end

do
local M = {}

-- Returns current time in milliseconds using high-precision clock
-- @return number: Current time in milliseconds
function M.now_ms()
    return os.clock() * MS_PER_SECOND
end

-- Returns current Unix timestamp in seconds
-- @return number: Current time in seconds since epoch
function M.now_sec()
    return os.time()
end

-- Formats timestamp as time string (HH:MM:SS)
-- @param timestamp number: Optional Unix timestamp, defaults to current time
-- @return string: Formatted time string
function M.format_time(timestamp)
    timestamp = timestamp or os.time()
    return os.date(CLOCK_TIME_FORMAT, timestamp)
end

-- Formats timestamp as date string (YYYY-MM-DD)
-- @param timestamp number: Optional Unix timestamp, defaults to current time
-- @return string: Formatted date string
function M.format_date(timestamp)
    timestamp = timestamp or os.time()
    return os.date(CLOCK_DATE_FORMAT, timestamp)
end

-- Formats timestamp as date and time string (YYYY-MM-DD HH:MM:SS)
-- @param timestamp number: Optional Unix timestamp, defaults to current time
-- @return string: Formatted date-time string
function M.format_date_time(timestamp)
    timestamp = timestamp or os.time()
    return os.date(CLOCK_DATE_TIME_FORMAT, timestamp)
end

-- Formats timestamp for log filename (YYYYMMDD_HHMMSS)
-- @param timestamp number: Optional Unix timestamp, defaults to current time
-- @return string: Filename-safe timestamp string
function M.format_filename(timestamp)
    timestamp = timestamp or os.time()
    return os.date(LOG_FILENAME_TIMESTAMP_FORMAT, timestamp)
end

-- Calculates elapsed time in milliseconds between two timestamps
-- @param start_ms number: Start time in milliseconds
-- @param end_ms number: Optional end time, defaults to current time
-- @return number: Elapsed milliseconds
function M.elapsed_ms(start_ms, end_ms)
    end_ms = end_ms or M.now_ms()
    return end_ms - start_ms
end

-- Checks if timeout period has elapsed since start time
-- @param start_ms number: Start time in milliseconds
-- @param timeout_ms number: Timeout duration in milliseconds
-- @return boolean: True if timeout period has elapsed
function M.has_expired(start_ms, timeout_ms)
    return M.elapsed_ms(start_ms) >= timeout_ms
end

BetterConsole.Clock = M
end

do
local M = {}

-- Resolves exporter by name, falling back to default if not specified
-- @param self table: Exporter manager instance
-- @param exporter_name string: Optional exporter name
-- @return string, table: Exporter name and exporter instance
local function resolve_exporter(self, exporter_name)
    local name = exporter_name or self.default_exporter
    return name, self.exporters[name]
end

-- Executes export operation with error handling and consistent error formatting
-- @param label string: Operation label for error tracking
-- @param error_prefix string: Error message prefix
-- @param handler function: Export operation to execute
-- @return any, string: Result or false, and error message if failed
local function execute_export(label, error_prefix, handler)
    local success, result = try_with_error_handler(label, handler)
    if success then
        return result
    end

    return false, error_prefix .. tostring(result)
end

-- Creates new exporter manager instance
-- @return table: Configured exporter manager
function M.new()
    local instance = {
        exporters = {},
        default_exporter = DEFAULT_EXPORTER_NAME,
        log_directory = nil,
        current_log_file = nil,
        auto_save_enabled = false,
        log_handle = nil,
        writes_since_flush = 0,
        last_flush_ms = 0
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Registers new exporter with manager
-- @param name string: Exporter identifier
-- @param exporter table: Exporter implementation
function M:register_exporter(name, exporter)
    self.exporters[name] = exporter
end

-- Exports log entries to system clipboard using specified exporter
-- @param entries array: Log entries to export
-- @param exporter_name string: Optional exporter name, uses default if nil
-- @return boolean, string: Success flag and result message or error
function M:export_to_clipboard(entries, exporter_name)
    local name, exporter = resolve_exporter(self, exporter_name)

    if not exporter then
        return false, "Unknown exporter: " .. tostring(name)
    end

    return execute_export(
        "export_to_clipboard",
        "Export to clipboard failed: ",
        function()
            return exporter:export_to_clipboard(entries)
        end
    )
end

-- Exports log entries to file using specified exporter
-- @param entries array: Log entries to export
-- @param filename string: Optional filename, generates timestamp-based name if nil
-- @param exporter_name string: Optional exporter name, uses default if nil
-- @return boolean, string: Success flag and result message or error
function M:export_to_file(entries, filename, exporter_name)
    local name, exporter = resolve_exporter(self, exporter_name)

    if not exporter then
        return false, "Unknown exporter: " .. tostring(name)
    end

    local resolved_filename = filename or self:generate_log_filename()

    return execute_export(
        "export_to_file",
        "Export to file failed: ",
        function()
            return exporter:export_to_file(entries, resolved_filename)
        end
    )
end

-- Ensures log directory exists and is accessible
-- Creates directory if needed and updates cached path
-- @return string|nil: Validated log directory path or nil if unavailable
function M:ensure_log_directory()
    if not self.log_directory or self.log_directory == "" then
        self.log_directory = resolve_logs_directory()
    end

    if not self.log_directory or self.log_directory == "" then
        return nil
    end

    local ensured = ensure_directory_exists(self.log_directory)
    if ensured and ensured ~= "" then
        self.log_directory = ensured
        return self.log_directory
    end

    self.log_directory = nil
    return nil
end

-- Generates timestamp-based filename for log files
-- @return string: Filename with timestamp in format console_YYYYMMDD_HHMMSS.log
function M:generate_log_filename()
    local timestamp = os.date(LOG_FILENAME_TIMESTAMP_FORMAT)
    return LOG_FILENAME_PREFIX .. timestamp .. LOG_FILENAME_EXTENSION
end

-- Initializes automatic log saving to file
-- Creates session log file with header if auto-save is enabled
-- @param enabled boolean: Whether to enable auto-save functionality
-- Flushes and closes the auto-save handle if one is open
function M:close_auto_save()
    if not self.log_handle then
        return
    end

    pcall(function()
        self.log_handle:flush()
        self.log_handle:close()
    end)

    self.log_handle = nil
    self.writes_since_flush = 0
end

-- Pushes buffered writes to disk, on a threshold or a time interval
-- The handle stays open between entries, so this is what bounds how long a
-- written line can sit in the C runtime's buffer before it reaches the file.
-- @param force boolean: Flush regardless of threshold or interval
function M:flush_auto_save(force)
    if not self.log_handle then
        return
    end

    if not force then
        if self.writes_since_flush == 0 then
            return
        end

        local elapsed = os.clock() * MS_PER_SECOND - self.last_flush_ms
        if self.writes_since_flush < AUTOSAVE_FLUSH_WRITES and elapsed < AUTOSAVE_FLUSH_INTERVAL_MS then
            return
        end
    end

    pcall(function()
        self.log_handle:flush()
    end)

    self.writes_since_flush = 0
    self.last_flush_ms = os.clock() * MS_PER_SECOND
end

-- Initializes automatic log saving to file
-- Creates session log file with header if auto-save is enabled
-- @param enabled boolean: Whether to enable auto-save functionality
function M:initialize_auto_save(enabled)
    self:close_auto_save()
    self.auto_save_enabled = not not enabled

    if not self.auto_save_enabled then
        self.current_log_file = nil
        return
    end

    local directory = self:ensure_log_directory()
    if not directory then
        self.current_log_file = nil
        return
    end

    local timestamp = os.date(LOG_FILENAME_TIMESTAMP_FORMAT)
    self.current_log_file = AUTOSAVE_LOG_PREFIX .. timestamp .. LOG_FILENAME_EXTENSION

    local file = io.open(directory .. self.current_log_file, "w")
    if not file then
        self.current_log_file = nil
        return
    end

    file:write(LOG_SESSION_HEADER_PREFIX .. os.date(TEXT_TIMESTAMP_FORMAT) .. "\n")
    file:flush()

    -- Held open for the session. Reopening per entry cost an ensure_log_directory
    -- call plus an open and close on the draw thread, measured at 69us against
    -- 1us for a write to an open handle.
    self.log_handle = file
    self.writes_since_flush = 0
    self.last_flush_ms = os.clock() * MS_PER_SECOND
end

-- Appends single log entry to auto-save file
-- Formats entry using default exporter and writes to current log file
-- @param entry table: Log entry to append to file
function M:append_log_entry(entry)
    if not self.auto_save_enabled or not self.log_handle then
        return
    end

    local _, exporter = resolve_exporter(self)
    if not exporter or not exporter.format_entry then
        return
    end

    local ok = pcall(function()
        self.log_handle:write(exporter:format_entry(entry), "\n")
    end)

    if not ok then
        self:close_auto_save()
        self.auto_save_enabled = false
        return
    end

    self.writes_since_flush = self.writes_since_flush + 1
    self:flush_auto_save()
end

M.TextExporter = {}

-- Creates new text exporter instance
-- @return table: Text exporter with default configuration
function M.TextExporter.new()
    local instance = {
        name = DEFAULT_EXPORTER_NAME,
        description = "Plain text exporter"
    }

    setmetatable(instance, { __index = M.TextExporter })
    return instance
end

-- Collects formatted lines from log entries using exporter
-- @param exporter table: Exporter instance with format_entry method
-- @param entries array: Log entries to format
-- @return array: Array of formatted text lines
local function collect_export_lines(exporter, entries)
    local lines = {}
    for _, entry in ipairs(entries or {}) do
        lines[#lines + 1] = exporter:format_entry(entry)
    end
    return lines
end

-- Exports log entries to system clipboard as plain text
-- @param entries array: Log entries to export
-- @return boolean, string: Success flag and result message
function M.TextExporter:export_to_clipboard(entries)
    local lines = collect_export_lines(self, entries)
    local export_text = table.concat(lines, "\n")

    if export_text == "" then
        return false, "No entries to export"
    end

    GUI:SetClipboardText(export_text)
    return true, "Exported " .. #lines .. " entries to clipboard"
end

-- Exports log entries to file as plain text
-- @param entries array: Log entries to export
-- @param filename string: Target filename for export
-- @return boolean, string: Success flag and result message or error
function M.TextExporter:export_to_file(entries, filename)
    local lines = collect_export_lines(self, entries)
    local export_text = table.concat(lines, "\n")

    local directory = resolve_logs_directory()
    directory = ensure_directory_exists(directory)

    if not directory then
        return false, "Log directory is unavailable for export"
    end

    local full_path = directory .. filename
    local file = io.open(full_path, "w")

    if not file then
        return false, "Failed to open file: " .. full_path
    end

    file:write(export_text)
    file:close()
    return true, "Exported " .. #lines .. " entries to " .. full_path
end

-- Formats single log entry as plain text with timestamp, level, category, and message
-- @param entry table: Log entry with timestamp, level, category, and message fields
-- @return string: Formatted text line for the entry
function M.TextExporter:format_entry(entry)
    local parts = {}

    if entry.timestamp then
        parts[#parts + 1] = os.date(TEXT_TIMESTAMP_FORMAT, entry.timestamp)
    end

    if entry.level and entry.level.name then
        parts[#parts + 1] = "[" .. entry.level.name .. "]"
    end

    if entry.category then
        parts[#parts + 1] = "[" .. entry.category .. "]"
    end

    if entry.message ~= nil then
        parts[#parts + 1] = tostring(entry.message)
    end

    return table.concat(parts, " ")
end

BetterConsole.Exporter = M
end

do
local RepositoryInterface = BetterConsole.RepositoryInterface
local Models = BetterConsole.Models

local M = {}
setmetatable(M, { __index = RepositoryInterface.IRepository })

-- Returns current time in milliseconds using available clock utilities
-- @return number: Current time in milliseconds
local function now_ms()
    local clock = BetterConsole.Clock
    if clock and clock.now_ms then
        return clock.now_ms()
    end
    return os.clock() * MS_PER_SECOND
end

-- Reads entire file content into string
-- @param path string: File path to read
-- @return string|nil: File content or nil if read failed
local function read_all(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end

    local content = handle:read("*all")
    handle:close()
    return content
end

-- Initializes total_added counter from index file
-- Used to maintain entry count across repository restarts
-- @param repository table: Repository instance to initialize
local function seed_total_added(repository)
    local content = read_all(repository.index_file)
    if not content or content == "" then
        return
    end

    local index_data = repository:deserialize(content)
    if not index_data then
        return
    end

    repository.total_added = index_data.total_added or 0
end

-- Creates new file repository instance with caching and write batching
-- @param file_path string: Path to log file for persistent storage
-- @param cache_size number: Optional cache size, defaults to configured value
-- @return table: Configured file repository instance
function M.new(file_path, cache_size)
    if not file_path then
        error("FileRepository requires a filePath")
    end

    local instance = {
        file_path = file_path,
        cache_size = cache_size or FILE_REPOSITORY_DEFAULT_CACHE_SIZE,
        cache = {},
        total_added = 0,
        file_handle = nil,
        index_file = file_path .. FILE_REPOSITORY_INDEX_SUFFIX,
        pending_lines = {},
        pending_count = 0,
        last_flush_time = now_ms(),
        flush_threshold = FILE_REPOSITORY_FLUSH_THRESHOLD,
        flush_interval_ms = FILE_REPOSITORY_FLUSH_INTERVAL_MS,
        index_dirty = false
    }

    setmetatable(instance, { __index = M })
    instance:initialize()
    return instance
end

function M:initialize()
    seed_total_added(self)

    local handle = io.open(self.file_path, "a+")
    if not handle then
        error("Failed to open file for writing: " .. self.file_path)
    end

    self.file_handle = handle
    self.last_flush_time = now_ms()
    self:load_recent_entries()
end

function M:load_recent_entries()
    local file = io.open(self.file_path, "r")
    if not file then
        return
    end

    local entries = {}
    for line in file:lines() do
        local entry = self:deserialize_line(line)
        if entry then
            entries[#entries + 1] = entry
        end
    end
    file:close()

    local start_idx = math.max(FIRST_INDEX, #entries - self.cache_size + FIRST_INDEX)
    local cache = {}
    for index = start_idx, #entries do
        cache[#cache + 1] = entries[index]
    end

    self.cache = cache
end

-- Serializes log entry to pipe-delimited line format with escaping
-- @param entry table: Log entry to serialize with timestamp, level, category, message, data
-- @return string: Serialized line in format "timestamp|level|category|message|data"
function M:serialize_line(entry)
    local data_json = self:serialize(entry.data)
    local escaped_message = entry.message
        :gsub("|", "\\|")
        :gsub("\n", "\\n")

    return string.format(
        SERIALIZED_LINE_TEMPLATE,
        entry.timestamp,
        entry.level.name,
        entry.category,
        escaped_message,
        data_json or "{}"
    )
end

-- Deserializes pipe-delimited line back to log entry object
-- Handles escape sequences and creates proper log entry with all fields
-- @param line string: Serialized line from file
-- @return table|nil: Deserialized log entry or nil if parsing failed
function M:deserialize_line(line)
    if not line or line == "" then
        return nil
    end

    local parts = {}
    local current = ""
    local escaped = false

    for index = FIRST_INDEX, #line do
        local char = line:sub(index, index)
        if escaped then
            if char == "|" then
                current = current .. "|"
            elseif char == "n" then
                current = current .. "\n"
            else
                current = current .. "\\" .. char
            end
            escaped = false
        elseif char == "\\" then
            escaped = true
        elseif char == "|" then
            parts[#parts + 1] = current
            current = ""
        else
            current = current .. char
        end
    end
    parts[#parts + 1] = current

    if #parts < MIN_SERIALIZED_LINE_PARTS then
        return nil
    end

    local timestamp = tonumber(parts[SERIALIZED_LINE_TIMESTAMP_INDEX])
    local level = parts[SERIALIZED_LINE_LEVEL_INDEX]
    local category = parts[SERIALIZED_LINE_CATEGORY_INDEX]
    local message = parts[SERIALIZED_LINE_MESSAGE_INDEX]
    local data_json = parts[SERIALIZED_LINE_DATA_INDEX] or "{}"

    local data = self:deserialize(data_json) or {}

    return Models.LogEntry.new(level, category, message, data)
end

-- Serializes table object to simple JSON-like format
-- Converts key-value pairs to quoted format for storage
-- @param obj any: Object to serialize, typically a table
-- @return string: Serialized string representation
function M:serialize(obj)
    if type(obj) ~= "table" then
        return tostring(obj)
    end

    local parts = {}
    for key, value in pairs(obj) do
        local key_str = tostring(key)
        local value_str = type(value) == "table" and self:serialize(value) or tostring(value)
        parts[#parts + 1] = string.format('"%s":"%s"', key_str, value_str)
    end

    if #parts == 0 then
        return "{}"
    end

    return "{" .. table.concat(parts, ",") .. "}"
end

-- Deserializes JSON-like string back to table object
-- Parses key-value pairs and converts numeric strings to numbers
-- @param str string: Serialized string to deserialize
-- @return table: Deserialized table or empty table if parsing failed
function M:deserialize(str)
    if not str or str == "" or str == "{}" then
        return {}
    end

    local result = {}
    local content = str:match("^%s*{(.-)%}%s*$")
    if not content or content == "" then
        return {}
    end

    for pair in content:gmatch('[^,]+') do
        local key, value = pair:match('^%s*"([^"]+)"%s*:%s*"([^"]*)"%s*$')
        if key then
            local num_value = tonumber(value)
            result[key] = num_value or value
        end
    end

    return result
end

-- Adds serialized line to pending write buffer for batched file operations
-- @param line string: Serialized log line to enqueue
function M:enqueue_line(line)
    local pending = self.pending_lines
    pending[#pending + 1] = line
    self.pending_count = self.pending_count + 1
end

-- Writes pending log lines to file and flushes file handle
-- Also triggers index save if index is marked dirty
-- @param force boolean: If true, forces flush even if no pending writes
function M:flush_pending_writes(force)
    if not self.file_handle then
        return
    end

    if self.pending_count > 0 then
        self.file_handle:write(table.concat(self.pending_lines))
        self.file_handle:flush()
        self.pending_lines = {}
        self.pending_count = 0
        self.last_flush_time = now_ms()
    elseif force then
        self.file_handle:flush()
    end

    if self.index_dirty then
        self:save_index()
    end
end

-- Conditionally flushes pending writes based on threshold and time interval
-- Implements batching strategy to reduce file I/O operations
-- @param force boolean: If true, forces immediate flush regardless of conditions
function M:maybe_flush(force)
    if not self.file_handle then
        return
    end

    if force then
        self:flush_pending_writes(true)
        return
    end

    if self.pending_count == 0 and not self.index_dirty then
        return
    end

    local current_time = now_ms()
    local should_flush = self.pending_count >= self.flush_threshold or
        (current_time - self.last_flush_time) >= self.flush_interval_ms

    if should_flush then
        self:flush_pending_writes()
    end
end

-- Adds log entry to repository with serialization and caching
-- Enqueues serialized entry for file write and maintains cache
-- @param entry table: Log entry to add to repository
-- @return boolean: True if entry was added successfully
function M:add(entry)
    if not entry then
        return false
    end

    local line = self:serialize_line(entry)
    if self.file_handle then
        self:enqueue_line(line)
    end

    local cache = self.cache
    cache[#cache + 1] = entry

    if #cache > self.cache_size then
        table.remove(cache, 1)
    end

    self.total_added = self.total_added + 1

    if self.total_added % FILE_REPOSITORY_INDEX_SAVE_INTERVAL == 0 then
        self.index_dirty = true
    end

    self:maybe_flush()
    return true
end

-- Saves repository index metadata to file
-- Persists total entry count and last update time for recovery
function M:save_index()
    local index_file = io.open(self.index_file, "w")
    if index_file then
        local index_data = {
            total_added = self.total_added,
            last_update = os.time()
        }
        index_file:write(self:serialize(index_data))
        index_file:close()
    end
    self.index_dirty = false
end

-- Retrieves log entry from cache by index
-- @param index number: 1-based index of entry in cache
-- @return table|nil: Log entry at index or nil if out of bounds
function M:get(index)
    if not index or index < 1 or index > #self.cache then
        return nil
    end
    return self.cache[index]
end

-- Returns iterator wrapper for all cached log entries
-- Provides iterate function and entry count accessor
-- @return table: Iterator wrapper with iterate() and get_entry_count() methods
function M:get_all()
    local cache = self.cache
    local count = #cache

    local function iterator()
        local index = 0
        return function()
            if index >= count then
                return nil
            end
            index = index + 1
            return index, cache[index]
        end
    end

    return {
        iterate = iterator,
        get_entry_count = function()
            return count
        end
    }
end

-- Executes filtered query against cached log entries
-- @param filter table: Query filter with search terms, level, and category filters
-- @return array: Filtered and paginated log entries
function M:query(filter)
    return query_entries(self:get_all(), filter)
end

-- Retrieves entries added since specified total count
-- Handles cache wraparound and returns only new entries from cache
-- @param from_total number: Previous total count to compare against
-- @return array: New log entries added since from_total
function M:get_new_entries(from_total)
    local cache = self.cache
    local entries_in_cache = #cache
    local oldest_cached_total = self.total_added - entries_in_cache

    if from_total >= self.total_added then
        return {}
    end

    local new_entries = {}

    if from_total < oldest_cached_total then
        for index = FIRST_INDEX, entries_in_cache do
            new_entries[#new_entries + 1] = cache[index]
        end
        return new_entries
    end

    local start_idx = math.max(FIRST_INDEX, from_total - oldest_cached_total + FIRST_INDEX)
    for index = start_idx, entries_in_cache do
        new_entries[#new_entries + 1] = cache[index]
    end

    return new_entries
end

-- Clears all repository data and recreates empty storage
-- Flushes pending writes, closes file handle, deletes files, and reinitializes
-- @return boolean: True if repository was cleared successfully
function M:clear()
    if self.file_handle then
        self:maybe_flush(true)
        self.file_handle:close()
        self.file_handle = nil
    end

    os.remove(self.file_path)
    os.remove(self.index_file)

    self.cache = {}
    self.total_added = 0
    self.pending_lines = {}
    self.pending_count = 0
    self.index_dirty = false
    self.last_flush_time = now_ms()

    self.file_handle = io.open(self.file_path, "a+")
    if not self.file_handle then
        return false
    end

    self:save_index()
    return true
end

-- Returns current number of entries in cache
-- @return number: Count of cached log entries
function M:count()
    return #self.cache
end

-- Returns total number of entries ever added to repository
-- Persists across cache wraparounds and repository restarts
-- @return number: Total entries added since creation
function M:get_total_added()
    return self.total_added
end

function M:close()
    if self.file_handle then
        self.index_dirty = true
        self:maybe_flush(true)
        self.file_handle:close()
        self.file_handle = nil
    end
end

BetterConsole.FileRepository = M
end

do
local RingBuffer = BetterConsole.RingBuffer
local RepositoryInterface = BetterConsole.RepositoryInterface

local M = {}
setmetatable(M, { __index = RepositoryInterface.IRepository })

-- Creates new memory repository instance with ring buffer storage
-- @param capacity number: Optional maximum entries to store, uses default if nil
-- @return table: Configured memory repository instance
function M.new(capacity)
    capacity = capacity or MEMORY_REPOSITORY_DEFAULT_CAPACITY

    local instance = {
        ring_buffer = RingBuffer.new(capacity),
        capacity = capacity
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Adds log entry to ring buffer storage
-- @param entry table: Log entry to store
-- @return boolean: True if entry was added successfully
function M:add(entry)
    if not entry then
        return false
    end

    self.ring_buffer:push(entry)
    return true
end

-- Retrieves log entry by index from ring buffer
-- @param index number: 1-based index of entry to retrieve
-- @return table|nil: Log entry at index or nil if out of bounds
function M:get(index)
    if not index or index < 1 or index > self.ring_buffer.count then
        return nil
    end

    local actual_index = (self.ring_buffer.head + index - RING_BUFFER_INDEX_BIAS) % self.ring_buffer.capacity + 1
    return self.ring_buffer.buffer[actual_index]
end

-- Returns iterator wrapper for all entries in ring buffer
-- Provides iterate function and entry count accessor
-- @return table: Iterator wrapper with iterate() and get_entry_count() methods
function M:get_all()
    local buffer = self.ring_buffer
    local count = buffer.count
    local head = buffer.head
    local capacity = buffer.capacity
    local storage = buffer.buffer

    local function iterator()
        local index = 0
        return function()
            if index >= count then
                return nil
            end

            index = index + 1
            local actual_index = (head + index - RING_BUFFER_INDEX_BIAS) % capacity + 1
            return index, storage[actual_index]
        end
    end

    return {
        iterate = iterator,
        get_entry_count = function()
            return count
        end
    }
end

-- Executes filtered query against ring buffer entries
-- @param filter table: Query filter with search terms, level, and category filters
-- @return array: Filtered and paginated log entries
function M:query(filter)
    return query_entries(self:get_all(), filter)
end

-- Retrieves entries added since specified total count
-- Efficiently handles ring buffer wraparound to return only new entries
-- @param from_total number: Previous total count to compare against
-- @return array: New log entries added since from_total
function M:get_new_entries(from_total)
    local buffer = self.ring_buffer
    local current_total = buffer.total_added
    local count = buffer.count

    if from_total >= current_total or count == 0 then
        return {}
    end

    local needed = math.min(current_total - from_total, count)
    local start_index = count - needed + 1
    local entries = {}

    for index = start_index, count do
        local actual_index = (buffer.head + index - RING_BUFFER_INDEX_BIAS) % buffer.capacity + 1
        local entry = buffer.buffer[actual_index]
        if entry then
            entries[#entries + 1] = entry
        end
    end

    return entries
end

-- Clears all entries from ring buffer storage
-- @return boolean: True if buffer was cleared successfully
function M:clear()
    self.ring_buffer:clear()
    return true
end

-- Returns current number of entries in ring buffer
-- @return number: Count of stored log entries
function M:count()
    return self.ring_buffer.count
end

-- Returns total number of entries ever added to ring buffer
-- Persists across buffer wraparounds
-- @return number: Total entries added since creation
function M:get_total_added()
    return self.ring_buffer.total_added
end

-- Export memory repository to global namespace
BetterConsole.MemoryRepository = M
end

-- User preferences management module
-- Handles loading, saving, and applying console preferences with validation
do
local M = {}

-- Returns resolved path to user preferences file
-- @return string|nil: Preferences file path or nil if not resolvable
function M.get_prefs_path()
    return resolve_prefs_file()
end

-- Loads user preferences from file and applies them to window
-- @param window table: Console window instance to configure
-- @return boolean: True if preferences were loaded and applied successfully
function M.load_user_prefs(window)
    if not window then
        return false
    end

    local prefs_path = M.get_prefs_path()
    if not prefs_path or not FileExists(prefs_path) then
        return false
    end

    local success, prefs = try_with_error_handler("load_user_prefs", function()
        return FileLoad(prefs_path)
    end)

    if not success or type(prefs) ~= "table" then
        return false
    end

    M.apply_to_window(window, prefs)
    return true
end

-- Saves current window configuration to user preferences file
-- @param window table: Console window instance to extract preferences from
-- @return boolean: True if preferences were saved successfully
function M.save_user_prefs(window)
    if not window then
        return false
    end

    local prefs_path = M.get_prefs_path()
    if not prefs_path then
        return false
    end

    local prefs = M.extract_from_window(window)
    local success, result = try_with_error_handler("save_user_prefs", function()
        return FileSave(prefs_path, prefs)
    end)

    if not success then
        return false
    end

    return result
end

-- Creates default preferences configuration with sensible defaults
-- @return table: Complete preferences structure with default values
function M.create_defaults()
    return {
        display = {
            timestamp = true,
            level = true,
            category = true,
            metadata = true,
            auto_save_logs = false,
            follow_log = true
        },
        search = {
            case_sensitive = false
        },
        anti_spam = {
            enabled = true
        },
        filters = {
            levels = {
                TRACE = true,
                DEBUG = true,
                INFO = true,
                WARN = true,
                ERROR = true
            },
            categories = {},
            exclude_categories = {},
            exclude_levels = {}
        },
        custom_filter_presets = {},
        current_custom_preset = DEFAULT_CUSTOM_PRESET_INDEX,
        show_metadata_panel = true,
        metadata_panel = {
            width_ratio = DEFAULT_METADATA_PANEL_WIDTH_RATIO
        }
    }
end

-- Applies loaded preferences to console window configuration
-- Updates window settings with preference values using field filtering
-- @param window table: Console window instance to configure
-- @param prefs table: Loaded preferences to apply
function M.apply_to_window(window, prefs)
    if not window or type(prefs) ~= "table" then
        return
    end

    if type(window.display) == "table" then
        apply_table_fields(window.display, prefs.display, PREFERENCE_DISPLAY_FIELDS)
    end

    if type(window.search) == "table" then
        apply_table_fields(window.search, prefs.search, PREFERENCE_SEARCH_FIELDS)
    end

    if window.anti_spam and window.anti_spam.set_enabled then
        local anti_spam_prefs = prefs.anti_spam
        if type(anti_spam_prefs) == "table" and anti_spam_prefs.enabled ~= nil then
            window.anti_spam:set_enabled(anti_spam_prefs.enabled)
        end
    end

    if type(window.filters) == "table" and type(prefs.filters) == "table" then
        if type(prefs.filters.levels) == "table" then
            apply_filter_levels(window.filters.levels, prefs.filters.levels)
        end

        for _, key in ipairs(PREFERENCE_FILTER_LIST_FIELDS) do
            local value = prefs.filters[key]
            if type(value) == "table" then
                window.filters[key] = value
            end
        end
    end

    if type(prefs.custom_filter_presets) == "table" then
        window.custom_filter_presets = prefs.custom_filter_presets
    end

    shallow_assign(window, "current_custom_preset", prefs.current_custom_preset)
    shallow_assign(window, "show_metadata_panel", prefs.show_metadata_panel)

    if type(window.metadata_panel) == "table" then
        apply_table_fields(window.metadata_panel, prefs.metadata_panel, PREFERENCE_METADATA_PANEL_FIELDS)
    end
end

-- Extracts current window configuration as preferences structure
-- Creates preferences from window state for saving to file
-- @param window table: Console window instance to extract from
-- @return table: Preferences structure ready for serialization
function M.extract_from_window(window)
    local prefs = M.create_defaults()
    if not window then
        return prefs
    end

    if type(window.display) == "table" then
        apply_table_fields(prefs.display, window.display, PREFERENCE_DISPLAY_FIELDS)
    end

    if type(window.search) == "table" then
        apply_table_fields(prefs.search, window.search, PREFERENCE_SEARCH_FIELDS)
    end

    if window.anti_spam and window.anti_spam.enabled ~= nil then
        prefs.anti_spam.enabled = window.anti_spam.enabled
    end

    if type(window.filters) == "table" then
        if type(window.filters.levels) == "table" then
            prefs.filters.levels = window.filters.levels
        end

        for _, key in ipairs(PREFERENCE_FILTER_LIST_FIELDS) do
            local value = window.filters[key]
            if type(value) == "table" then
                prefs.filters[key] = value
            end
        end
    end

    if type(window.custom_filter_presets) == "table" then
        prefs.custom_filter_presets = window.custom_filter_presets
    end

    if window.current_custom_preset ~= nil then
        prefs.current_custom_preset = window.current_custom_preset
    end

    if window.show_metadata_panel ~= nil then
        prefs.show_metadata_panel = window.show_metadata_panel
    end

    if type(window.metadata_panel) == "table" then
        apply_table_fields(prefs.metadata_panel, window.metadata_panel, PREFERENCE_METADATA_PANEL_FIELDS)
    end

    return prefs
end

BetterConsole.Prefs = M
end

return Adapters
