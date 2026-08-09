local Core = {}

if not BetterConsole then
    BetterConsole = {}
end

do
local M = {}

M.Category = {
    VALIDATION = "ValidationError",
    IO = "IOError",
    RUNTIME = "RuntimeError",
    NETWORK = "NetworkError",
    PERMISSION = "PermissionError",
    CLIPBOARD = "ClipboardError",
    EXPORT = "ExportError",
    COMMAND = "CommandError",
    UNKNOWN = "UnknownError"
}

M.Severity = {
    WARNING = 1,
    ERROR = 2,
    FATAL = 3
}

M.SeverityToLogLevel = {
    [1] = "WARN",
    [2] = "ERROR",
    [3] = "ERROR"
}

M.CategorySeverity = {
    ValidationError = M.Severity.WARNING,
    IOError = M.Severity.ERROR,
    RuntimeError = M.Severity.ERROR,
    NetworkError = M.Severity.ERROR,
    PermissionError = M.Severity.ERROR,
    ClipboardError = M.Severity.WARNING,
    ExportError = M.Severity.ERROR,
    CommandError = M.Severity.ERROR,
    UnknownError = M.Severity.ERROR
}

-- Creates structured error object with category, message, context, and severity
-- @param category string: Error category from M.Category
-- @param message string: Error message describing the issue
-- @param context any: Optional context information
-- @param severity number: Optional severity override
-- @return table: Error object with all fields and timestamp
function M.create_error(category, message, context, severity)
    category = category or M.Category.UNKNOWN
    severity = severity or M.CategorySeverity[category] or M.Severity.ERROR

    return {
        category = category,
        message = message or "An error occurred",
        context = context,
        severity = severity,
        timestamp = os.time()
    }
end

-- Converts severity level to human-readable name
-- @param severity number: Severity level constant
-- @return string: Severity name (WARNING, ERROR, FATAL, or UNKNOWN)
function M.get_severity_name(severity)
    if severity == M.Severity.WARNING then
        return "WARNING"
    elseif severity == M.Severity.ERROR then
        return "ERROR"
    elseif severity == M.Severity.FATAL then
        return "FATAL"
    else
        return "UNKNOWN"
    end
end

BetterConsole.ErrorTypes = M
Core.ErrorTypes = M
end

do
local M = {}

local ErrorTypes = nil

-- Lazy-loads ErrorTypes module
-- @return table: ErrorTypes module instance
local function get_error_types()
    if not ErrorTypes then
        ErrorTypes = BetterConsole.ErrorTypes
    end
    return ErrorTypes
end

-- Executes function with error handling and optional callback
-- Wraps function in pcall and logs errors if they occur
-- @param func function: Function to execute with error protection
-- @param context any: Context information for error logging
-- @param error_callback function: Optional callback invoked on error
-- @return boolean, any: Success flag and result or error message
function M.try_catch(func, context, error_callback)
    if type(func) ~= "function" then
        return false, "try_catch requires a function"
    end

    local success, result = pcall(func)

    if not success then
        local error_msg = tostring(result)

        M.log_error(error_msg, context)

        if error_callback and type(error_callback) == "function" then
            error_callback(error_msg)
        end

        return false, error_msg
    end

    return true, result
end

-- Logs error message with timestamp and context
-- Uses global d() function for output
-- @param error_msg string: Error message to log
-- @param context any: Optional context (table with operation/name or string)
function M.log_error(error_msg, context)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local context_str = ""

    if context then
        if type(context) == "table" then
            context_str = " [" .. (context.operation or context.name or "Context") .. "]"
        else
            context_str = " [" .. tostring(context) .. "]"
        end
    end

    local log_entry = string.format(
        "[%s] ERROR%s: %s",
        timestamp,
        context_str,
        error_msg
    )

    d(log_entry)
end

-- Reports error to console with formatted message
-- Adds error entry to console or falls back to d() logging
-- @param console table: Console instance with add_entry method
-- @param operation string: Operation that failed
-- @param error any: Error object or message
-- @param severity number: Optional severity level
function M.report_error(console, operation, error, severity)
    local ET = get_error_types()
    severity = severity or ET.Severity.ERROR

    local error_msg = error
    if type(error) == "table" and error.message then
        error_msg = error.message
    end

    local message = string.format(
        "Failed to %s: %s",
        operation,
        tostring(error_msg)
    )

    local level = ET.SeverityToLogLevel[severity] or "ERROR"

    if console and console.add_entry then
        console:add_entry(level, "ErrorHandler", message, {
            operation = operation,
            error = error_msg,
            severity = ET.get_severity_name(severity)
        })
    else
        d("[BetterConsole] " .. message)
    end
end

BetterConsole.ErrorHandler = M
Core.ErrorHandler = M
end

do
local M = {}

M.VALID_LOG_LEVELS = {
    TRACE = true,
    DEBUG = true,
    INFO = true,
    WARN = true,
    ERROR = true
}

M.MAX_CATEGORY_LENGTH = 100
M.MAX_MESSAGE_LENGTH = 10000
M.MAX_PRESET_NAME_LENGTH = 50
M.MAX_FILENAME_LENGTH = 255
M.MAX_COMMAND_LENGTH = 10000
M.MIN_CATEGORY_LENGTH = 1
M.MIN_MESSAGE_LENGTH = 0
M.MIN_PRESET_NAME_LENGTH = 1

M.ERROR_MESSAGES = {
    LEVEL_REQUIRED = "Log level is required",
    LEVEL_INVALID_TYPE = "Log level must be a string",
    LEVEL_INVALID_VALUE = "Invalid log level: %s. Must be one of: TRACE, DEBUG, INFO, WARN, ERROR",

    CATEGORY_REQUIRED = "Category is required",
    CATEGORY_INVALID_TYPE = "Category must be a string",
    CATEGORY_EMPTY = "Category cannot be empty",
    CATEGORY_TOO_LONG = "Category too long (max %d characters)",
    CATEGORY_INVALID_CHARS = "Category contains invalid characters (only alphanumeric, spaces, underscore, dash allowed)",

    MESSAGE_REQUIRED = "Message is required",
    MESSAGE_TOO_LONG = "Message too long (max %d characters)",

    DATA_INVALID_TYPE = "Data must be a table or nil",

    PRESET_NAME_REQUIRED = "Preset name is required",
    PRESET_NAME_EMPTY = "Preset name cannot be empty",
    PRESET_NAME_TOO_LONG = "Preset name too long (max %d characters)",

    FILENAME_REQUIRED = "Filename is required",
    FILENAME_EMPTY = "Filename cannot be empty",
    FILENAME_TOO_LONG = "Filename too long (max %d characters)",
    FILENAME_INVALID_CHARS = "Filename contains invalid characters",

    COMMAND_REQUIRED = "Command is required",
    COMMAND_EMPTY = "Command cannot be empty",
    COMMAND_TOO_LONG = "Command too long (max %d characters)"
}

BetterConsole.ValidationRules = M
Core.ValidationRules = M
end

do
local M = {}

local ValidationRules = nil

-- Lazy-loads ValidationRules module
-- @return table: ValidationRules module instance
local function get_validation_rules()
    if not ValidationRules then
        ValidationRules = BetterConsole.ValidationRules
    end
    return ValidationRules
end

-- Validates and normalizes log level string
-- @param level string: Log level to validate
-- @return boolean, string: Success flag and normalized level or error message
function M.validate_log_level(level)
    local rules = get_validation_rules()

    if not level then
        return false, rules.ERROR_MESSAGES.LEVEL_REQUIRED
    end

    if type(level) ~= "string" then
        return false, rules.ERROR_MESSAGES.LEVEL_INVALID_TYPE
    end

    local normalized_level = string.upper(level)
    if not rules.VALID_LOG_LEVELS[normalized_level] then
        return false, string.format(rules.ERROR_MESSAGES.LEVEL_INVALID_VALUE, level)
    end

    return true, normalized_level
end

-- Validates category string for length and type
-- @param category string: Category to validate
-- @return boolean, string: Success flag and category or error message
function M.validate_category(category)
    local rules = get_validation_rules()

    if not category then
        return false, rules.ERROR_MESSAGES.CATEGORY_REQUIRED
    end

    if type(category) ~= "string" then
        return false, rules.ERROR_MESSAGES.CATEGORY_INVALID_TYPE
    end

    if #category == 0 then
        return false, rules.ERROR_MESSAGES.CATEGORY_EMPTY
    end

    if #category > rules.MAX_CATEGORY_LENGTH then
        return false, string.format(rules.ERROR_MESSAGES.CATEGORY_TOO_LONG, rules.MAX_CATEGORY_LENGTH)
    end

    return true, category
end

-- Validates message and converts to string
-- @param message any: Message to validate
-- @return boolean, string: Success flag and message string or error message
function M.validate_message(message)
    local rules = get_validation_rules()

    if not message then
        return false, rules.ERROR_MESSAGES.MESSAGE_REQUIRED
    end

    local message_str = tostring(message)

    if #message_str > rules.MAX_MESSAGE_LENGTH then
        return false, string.format(rules.ERROR_MESSAGES.MESSAGE_TOO_LONG, rules.MAX_MESSAGE_LENGTH)
    end

    return true, message_str
end

-- Validates metadata table or converts nil to empty table
-- @param data table|nil: Metadata to validate
-- @return boolean, table: Success flag and data table or error message
function M.validate_data(data)
    local rules = get_validation_rules()

    if data == nil then
        return true, {}
    end

    if type(data) ~= "table" then
        return false, rules.ERROR_MESSAGES.DATA_INVALID_TYPE
    end

    return true, data
end

-- Validates all components of log entry
-- @param level string: Log level
-- @param category string: Category
-- @param message any: Message
-- @param data table|nil: Metadata
-- @return boolean, table: Success flag and validated entry object or error message
function M.validate_log_entry(level, category, message, data)
    local ok, result

    ok, result = M.validate_log_level(level)
    if not ok then
        return false, result
    end
    local valid_level = result

    ok, result = M.validate_category(category)
    if not ok then
        return false, result
    end
    local valid_category = result

    ok, result = M.validate_message(message)
    if not ok then
        return false, result
    end
    local valid_message = result

    ok, result = M.validate_data(data)
    if not ok then
        return false, result
    end
    local valid_data = result

    return true, {
        level = valid_level,
        category = valid_category,
        message = valid_message,
        data = valid_data
    }
end

-- Validates filter preset name
-- @param name string: Preset name to validate
-- @return boolean, string: Success flag and name or error message
function M.validate_preset_name(name)
    local rules = get_validation_rules()

    if not name then
        return false, rules.ERROR_MESSAGES.PRESET_NAME_REQUIRED
    end

    if type(name) ~= "string" then
        return false, "Preset name must be a string"
    end

    if #name == 0 then
        return false, rules.ERROR_MESSAGES.PRESET_NAME_EMPTY
    end

    if #name > rules.MAX_PRESET_NAME_LENGTH then
        return false, string.format(rules.ERROR_MESSAGES.PRESET_NAME_TOO_LONG, rules.MAX_PRESET_NAME_LENGTH)
    end

    return true, name
end

-- Validates filename for length and type
-- @param filename string: Filename to validate
-- @return boolean, string: Success flag and filename or error message
function M.validate_filename(filename)
    local rules = get_validation_rules()

    if not filename then
        return false, rules.ERROR_MESSAGES.FILENAME_REQUIRED
    end

    if type(filename) ~= "string" then
        return false, "Filename must be a string"
    end

    if #filename == 0 then
        return false, rules.ERROR_MESSAGES.FILENAME_EMPTY
    end

    if #filename > rules.MAX_FILENAME_LENGTH then
        return false, string.format(rules.ERROR_MESSAGES.FILENAME_TOO_LONG, rules.MAX_FILENAME_LENGTH)
    end

    return true, filename
end

-- Validates command string for length and type
-- @param command string: Command to validate
-- @return boolean, string: Success flag and command or error message
function M.validate_command(command)
    local rules = get_validation_rules()

    if not command then
        return false, rules.ERROR_MESSAGES.COMMAND_REQUIRED
    end

    if type(command) ~= "string" then
        return false, "Command must be a string"
    end

    if #command == 0 then
        return false, rules.ERROR_MESSAGES.COMMAND_EMPTY
    end

    if #command > rules.MAX_COMMAND_LENGTH then
        return false, string.format(rules.ERROR_MESSAGES.COMMAND_TOO_LONG, rules.MAX_COMMAND_LENGTH)
    end

    return true, command
end

BetterConsole.Validators = M
Core.Validators = M
end

do
local M = {}

M.Constants = {
    Time = {
        MS_PER_SECOND = 1000
    },
    General = {
        FIRST_INDEX = 1
    },
    Categories = {
        ALL = "All",
        SYSTEM = "System",
        MINION = "Minion"
    },
    Notifications = {
        DEFAULT_DURATION = 3,
        CLIPBOARD_DURATION = 2
    },
    Filters = {
        States = {
            CLEARED = 0,
            INCLUDED = 1,
            EXCLUDED = 2
        },
        DEFAULT_CUSTOM_PRESET_INDEX = 0
    },
    Colors = {
        DEFAULT_WHITE = { 1.0, 1.0, 1.0, 1.0 },
        ORANGE_HIGHLIGHT = { 1.0, 0.5, 0.0, 1.0 },
        PLACEHOLDER_GRAY = { 0.5, 0.5, 0.5, 0.7 }
    },
    UI = {
        DEFAULT_WINDOW_MIN_SIZE = { 860, 500 },
        LEVEL_DROPDOWN_WIDTH = 110,
        CATEGORY_DROPDOWN_WIDTH = 90,
        ITEM_SPACING = { 8, 4 }
    },
    Performance = {
        MAX_CACHE_SIZE = 500,
        SEARCH_DEBOUNCE_DELAY = 50,
        MAX_ENTRIES = 50000,
        MAX_CODE_HISTORY = 50,
        FILTER_CHUNK_SIZE = 1000,
        FILTER_MIN_RESULTS = 200,
        FILTER_MAX_TIME_MS = 5,
        LRU_CACHE_SIZE = 50,
        MAX_DISPLAY_RESULTS = 50000,
        VIRTUAL_SCROLL_BUFFER_SIZE = 10,
        VIRTUAL_SCROLL_ITEM_HEIGHT = 18,
        LARGE_DATASET_THRESHOLD = 5000,
        SEARCH_DATASET_THRESHOLD = 2000,
        MAX_COROUTINE_TIME_MS = 2
    },
    Clipboard = {
        MAX_CLIPBOARD_LENGTH = 2000,
        MAX_TOOLTIP_LENGTH = 200,
        MAX_METADATA_PREVIEW = 100
    },
    Caching = {
        PROCESSED_TEXT_CACHE_SIZE = 100,
        HIGHLIGHT_CACHE_KEY_TRUNCATE = 50,
        HIGHLIGHT_CACHE_KEY_MAX = 100,
        METADATA_SERIALIZE_MAX_DEPTH = 10,
        METADATA_SERIALIZE_MAX_ITEMS = 10
    },
    Display = {
        MAX_MESSAGE_CHARS = 2000,
        MAX_DISPLAY_LINES = 8,
        CHARS_PER_LINE = 80,
        MESSAGE_TRUNCATE_PREVIEW = 50
    },
    AntiSpam = {
        SPAM_THRESHOLD = 10,
        TIME_WINDOW_MS = 1000,
        BLOCK_EXPIRE_MS = 5000,
        MAX_TRACKED_PATTERNS = 1000,
        MESSAGE_HASH_LENGTH = 32
    }
}

M.LogLevel = {}

M.LogLevel.TRACE = {
    value = 0,
    name = "TRACE",
    prefix = "[TRACE]",
    color = { 0.7, 0.7, 0.7, 1.0 }
}

M.LogLevel.DEBUG = {
    value = 1,
    name = "DEBUG",
    prefix = "[DEBUG]",
    color = { 0.5, 0.8, 1.0, 1.0 }
}

M.LogLevel.INFO = {
    value = 2,
    name = "INFO",
    prefix = "[INFO]",
    color = { 1.0, 1.0, 1.0, 1.0 }
}

M.LogLevel.WARN = {
    value = 3,
    name = "WARN",
    prefix = "[WARN]",
    color = { 1.0, 0.8, 0.2, 1.0 }
}

M.LogLevel.ERROR = {
    value = 4,
    name = "ERROR",
    prefix = "[ERROR]",
    color = { 1.0, 0.3, 0.3, 1.0 }
}

M.LogLevel.ALL_LEVELS = {
    M.LogLevel.TRACE,
    M.LogLevel.DEBUG,
    M.LogLevel.INFO,
    M.LogLevel.WARN,
    M.LogLevel.ERROR
}

M.LogLevel.LEVEL_MAP = {
    ["TRACE"] = M.LogLevel.TRACE,
    ["DEBUG"] = M.LogLevel.DEBUG,
    ["INFO"] = M.LogLevel.INFO,
    ["WARN"] = M.LogLevel.WARN,
    ["ERROR"] = M.LogLevel.ERROR,
    [0] = M.LogLevel.TRACE,
    [1] = M.LogLevel.DEBUG,
    [2] = M.LogLevel.INFO,
    [3] = M.LogLevel.WARN,
    [4] = M.LogLevel.ERROR
}

-- Converts string or number to log level object
-- @param level_str string|number: Level identifier
-- @return table: Log level object, defaults to INFO if invalid
function M.LogLevel.from_string(level_str)
    if not level_str then
        return M.LogLevel.INFO
    end
    if type(level_str) ~= "string" then
        return M.LogLevel.INFO
    end
    return M.LogLevel.LEVEL_MAP[string.upper(level_str)] or M.LogLevel.INFO
end

-- LogEntry class for structured log entries
M.LogEntry = {}

-- Creates new log entry with timestamp, level, category, message, and metadata
-- @param level string: Log level name
-- @param category string: Log category
-- @param message string: Log message
-- @param data table: Optional metadata
-- @return table: Log entry instance
function M.LogEntry.new(level, category, message, data)
    local timestamp = os.time()

    local message_str = tostring(message or "")
    local category_str = tostring(category or "System")

    local time_string = os.date("%H:%M:%S", timestamp)
    if data and data.extracted_timestamp then
        time_string = data.extracted_timestamp
    end

    local normalized_level = M.LogLevel.from_string(level)

    local valid_data = data
    if valid_data ~= nil and type(valid_data) ~= "table" then
        valid_data = { raw = valid_data }
    end

    local instance = {
        timestamp = timestamp,
        time_string = time_string,
        level = normalized_level,
        category = category_str,
        message = message_str,
        data = valid_data or {},
        message_lower = message_str:lower(),
        category_lower = category_str:lower()
    }

    setmetatable(instance, { __index = M.LogEntry })
    return instance
end

-- Gets display text for log entry with prefix
-- Caches result for performance
-- @return string: Formatted display text with prefix and message
function M.LogEntry:get_display_text()
    if not self.cached_display_text then
        local prefix = self:get_prefix()
        self.cached_display_text = prefix .. self.message
    end
    return self.cached_display_text
end

-- Gets processed display text with configurable components and truncation
-- Caches results with cache key based on display options
-- @param show_timestamp boolean: Include timestamp
-- @param show_level boolean: Include level prefix
-- @param show_category boolean: Include category
-- @param max_chars number: Optional maximum character limit
-- @return string: Formatted and truncated display text
function M.LogEntry:get_processed_display_text(show_timestamp, show_level, show_category, max_chars)
    if not self.processed_text_cache then
        self.processed_text_cache = {}
        self.processed_text_cache_size = 0
    end

    local Constants = M.Constants
    max_chars = max_chars or Constants.Display.MAX_MESSAGE_CHARS

    local cache_key = (show_timestamp and "T" or "F") .. "|" ..
                     (show_level and "L" or "F") .. "|" ..
                     (show_category and "C" or "F") .. "|" ..
                     max_chars

    if self.processed_text_cache[cache_key] then
        return self.processed_text_cache[cache_key]
    end

    if self.processed_text_cache_size >= Constants.Caching.PROCESSED_TEXT_CACHE_SIZE then
        self.processed_text_cache = {}
        self.processed_text_cache_size = 0
    end

    local parts = {}

    if show_timestamp then
        table.insert(parts, "[" .. self.time_string .. "] ")
    end

    if show_level then
        table.insert(parts, self.level.prefix .. " ")
    end

    if show_category then
        table.insert(parts, "[" .. self.category .. "]: ")
    end

    table.insert(parts, self.message)

    local text = table.concat(parts)
    text = BetterConsole.TextUtils.truncate(
        text,
        max_chars,
        Constants.Display.MAX_DISPLAY_LINES,
        Constants.Display.CHARS_PER_LINE
    )

    self.processed_text_cache[cache_key] = text
    self.processed_text_cache_size = self.processed_text_cache_size + 1
    return text
end

-- Gets log entry prefix with timestamp, level, and category
-- @return string: Formatted prefix string
function M.LogEntry:get_prefix()
    local prefix = string.format("[%s] %s [%s]: ",
                                self.time_string,
                                self.level.prefix,
                                self.category)
    return prefix
end

-- Gets color for log entry based on level
-- @return table: RGBA color array
function M.LogEntry:get_color()
    return self.level.color
end

BetterConsole.Models = M
Core.Models = M
end

do
local M = {}
local Constants = BetterConsole.Models.Constants

-- Truncates text by character count with truncation message
-- @param text string: Text to truncate
-- @param max_chars number: Optional maximum characters
-- @return string: Truncated text or original if within limit
function M.truncate_by_chars(text, max_chars)
    local limit = max_chars or Constants.Display.MAX_MESSAGE_CHARS
    if not text or #text <= limit then
        return text
    end
    return string.sub(text, 1, limit)
        .. "\n... [truncated - "
        .. (#text - limit)
        .. " more chars]"
end

-- Truncates text by line count estimate based on character width
-- @param text string: Text to truncate
-- @param max_lines number: Optional maximum lines
-- @param chars_per_line number: Optional characters per line
-- @return string: Truncated text or original if within limit
function M.truncate_by_lines(text, max_lines, chars_per_line)
    local maximum_lines = max_lines or Constants.Display.MAX_DISPLAY_LINES
    local line_width = chars_per_line or Constants.Display.CHARS_PER_LINE

    if not text then
        return ""
    end

    local truncate_at = maximum_lines * line_width
    if truncate_at < #text then
        return string.sub(text, 1, truncate_at) .. "\n... [truncated - too many lines]"
    end

    return text
end

-- Truncates text by both character count and line count
-- @param text string: Text to truncate
-- @param max_chars number: Maximum characters
-- @param max_lines number: Maximum lines
-- @param chars_per_line number: Characters per line
-- @return string: Truncated text
function M.truncate(text, max_chars, max_lines, chars_per_line)
    local truncated = M.truncate_by_chars(text, max_chars)
    return M.truncate_by_lines(truncated, max_lines, chars_per_line)
end

BetterConsole.TextUtils = M
Core.TextUtils = M
end

do
local M = {}

local LRU = BetterConsole.LRU
local Models = BetterConsole.Models

-- Performs optimized plain text search with optional case sensitivity
-- @param text string: Text to search within
-- @param pattern string: Pattern to find
-- @param case_sensitive boolean: Whether search is case-sensitive
-- @return number|nil: Start position of match or nil if not found
function M.optimized_find(text, pattern, case_sensitive)
    if not text or not pattern or #pattern == 0 then
        return nil
    end

    local search_text = case_sensitive and text or string.lower(text)
    local search_pattern = case_sensitive and pattern or string.lower(pattern)

    return string.find(search_text, search_pattern, 1, true)
end

-- Creates LRU cache for storing highlight segments to improve performance
-- @param max_size number: Optional maximum cache size
-- @return table: Cache object with get, put, and clear methods
function M.create_highlight_cache(max_size)
    local cache = {
        lru = LRU.new(max_size or Models.Constants.Performance.LRU_CACHE_SIZE)
    }

    function cache:get(text, search_text)
        local cache_key = M.create_cache_key(text, search_text)
        return self.lru:get(cache_key)
    end

    function cache:put(text, search_text, segments)
        local cache_key = M.create_cache_key(text, search_text)
        self.lru:put(cache_key, segments)
    end

    function cache:clear()
        self.lru:clear()
    end

    return cache
end

-- Creates cache key from text and search pattern for highlight caching
-- Truncates long text to keep key size manageable
-- @param text string: Original text
-- @param search_text string: Search pattern
-- @return string: Cache key string
function M.create_cache_key(text, search_text)
    local Constants = Models.Constants
    local text_part = (#text > Constants.Caching.HIGHLIGHT_CACHE_KEY_MAX)
        and (string.sub(text, 1, Constants.Caching.HIGHLIGHT_CACHE_KEY_TRUNCATE) .. "#" .. tostring(#text))
        or text

    return text_part .. "|" .. string.lower(search_text)
end

-- Creates text segments with highlight flags for rendering
-- Splits text into segments marking which parts match the search
-- @param text string: Text to segment
-- @param search_text string: Search pattern to highlight
-- @return table: Array of segments with text and highlight flag
function M.create_highlight_segments(text, search_text)
    if not search_text or search_text == "" then
        return {{ text = text, highlight = false }}
    end

    local search_pattern = string.lower(search_text)
    local text_to_search = string.lower(text)
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

-- Gets highlight segments from cache or creates new ones
-- @param cache table: Highlight cache object
-- @param text string: Text to segment
-- @param search_text string: Search pattern
-- @return table: Array of highlight segments
function M.get_cached_highlight_segments(cache, text, search_text)
    if not cache then
        return M.create_highlight_segments(text, search_text)
    end

    local cached = cache:get(text, search_text)
    if cached then
        return cached
    end

    local segments = M.create_highlight_segments(text, search_text)
    cache:put(text, search_text, segments)
    return segments
end

-- Renders text segments with highlighted portions using GUI
-- @param segments table: Array of segments with text and highlight flags
-- @param GUI table: GUI context for rendering
function M.render_text_segments(segments, GUI)
    if not GUI or not segments then
        return
    end

    GUI:PushStyleVar(GUI.StyleVar_ItemSpacing, { 0, -2 })
    GUI:PushStyleVar(GUI.StyleVar_FramePadding, { 0, 0 })

    for i, segment in ipairs(segments) do
        if i > 1 then
            GUI:SameLine(0, 0)
        end

        if segment.highlight then
            local color = Models.Constants.Colors.ORANGE_HIGHLIGHT
            GUI:PushStyleColor(GUI.Col_Text, color[1], color[2], color[3], color[4])
            GUI:Text(segment.text)
            GUI:PopStyleColor()
        else
            GUI:Text(segment.text)
        end
    end

    GUI:PopStyleVar(2)
end

-- Renders text with search highlights using cached segments
-- @param text string: Text to render
-- @param search_text string: Search pattern to highlight
-- @param cache table: Highlight cache object
-- @param GUI table: GUI context for rendering
function M.render_highlighted_text(text, search_text, cache, GUI)
    if not search_text or search_text == "" then
        GUI:TextWrapped(text)
        return
    end

    local segments = M.get_cached_highlight_segments(cache, text, search_text)
    M.render_text_segments(segments, GUI)
end

-- Creates a coroutine that filters entries in time-budgeted slices
-- Each resume returns (results, is_complete); results is the live accumulator,
-- so it must not be retained across searches. Aborts if window.search_version
-- advances past the version the coroutine was bound to.
-- @param window table: ConsoleWindow instance owning the search
-- @param entries table: Entry collection exposing iterate()
-- @param search_text string: Search term, already stored in window.filters.search
-- @param version number: Search version this coroutine is bound to
-- @return thread: Coroutine yielding (results, is_complete)
function M.create_search_coroutine(window, entries, search_text, version)
    return coroutine.create(function()
        local results = {}

        if type(entries) ~= "table" or type(entries.iterate) ~= "function" then
            return results, true
        end

        local Constants = Models.Constants
        local FilterEvaluator = BetterConsole.FilterEvaluator
        local max_results = Constants.Performance.MAX_DISPLAY_RESULTS
        local max_time_ms = Constants.Performance.MAX_COROUTINE_TIME_MS
        local ms_per_second = Constants.Time.MS_PER_SECOND
        local search_config = { case_sensitive = window.search.case_sensitive }

        FilterEvaluator.ensure_derived_maps(window.filters)
        window:clear_selection()

        local slice_start = os.clock() * ms_per_second

        for _, entry in entries:iterate() do
            if window.search_version ~= version then
                return results, true
            end

            if entry and FilterEvaluator.evaluate_entry(entry, window.filters, search_config) then
                results[#results + 1] = entry
                window.partial_result_count = #results
                if #results >= max_results then
                    break
                end
            end

            if (os.clock() * ms_per_second) - slice_start > max_time_ms then
                coroutine.yield(results, false)
                slice_start = os.clock() * ms_per_second
            end
        end

        if window.selected_entry_for_metadata then
            local still_shown = false
            for _, entry in ipairs(results) do
                if entry == window.selected_entry_for_metadata then
                    still_shown = true
                    break
                end
            end
            if not still_shown then
                window.selected_entry_for_metadata = nil
            end
        end

        return results, true
    end)
end

BetterConsole.Search = M
Core.Search = M
end

do
local M = {}

local Search = BetterConsole.Search

-- Checks if any flags in map are enabled
-- @param map table: Map of boolean flags
-- @return boolean: True if any flag is true
local function has_enabled_flags(map)
    if not map then
        return false
    end

    for _, value in pairs(map) do
        if value then
            return true
        end
    end

    return false
end

-- Maps filter states to include and exclude flag maps
-- @param states table: State map with values 0 (cleared), 1 (included), 2 (excluded)
-- @param include_target table: Target map for included items
-- @param exclude_target table: Target map for excluded items
local function map_state_flags(states, include_target, exclude_target)
    for key in pairs(include_target) do
        include_target[key] = nil
    end

    for key in pairs(exclude_target) do
        exclude_target[key] = nil
    end

    if not states then
        return
    end

    for name, state in pairs(states) do
        if state == 1 then
            include_target[name] = true
        elseif state == 2 then
            exclude_target[name] = true
        end
    end
end

-- Resolves text for search comparison with case sensitivity handling
-- @param value string: Original text value
-- @param lower_cached string: Cached lowercase version
-- @param case_sensitive boolean: Whether search is case-sensitive
-- @return string: Text to use for comparison
local function resolve_text(value, lower_cached, case_sensitive)
    if case_sensitive then
        return value or ""
    end

    if lower_cached then
        return lower_cached
    end

    return string.lower(value or "")
end

-- Evaluates whether log entry passes all filter criteria
-- @param entry table: LogEntry instance
-- @param filters table: Filter configuration with levels, categories, and search
-- @param search_config table: Search configuration with case_sensitive flag
-- @return boolean: True if entry passes all filters
function M.evaluate_entry(entry, filters, search_config)
    if not entry or not filters then
        return false
    end

    local level = entry.level
    local level_name = level and level.name
    local category = entry.category

    local exclude_levels = filters.exclude_levels
    if level_name and exclude_levels and exclude_levels[level_name] then
        return false
    end

    local exclude_categories = filters.exclude_categories
    if category and exclude_categories and exclude_categories[category] then
        return false
    end

    local include_levels = filters.levels
    if level_name and include_levels and has_enabled_flags(include_levels) and not include_levels[level_name] then
        return false
    end

    local include_categories = filters.categories
    if category and include_categories and has_enabled_flags(include_categories) and not include_categories[category] then
        return false
    end

    local search_value = filters.search
    if not search_value or search_value == "" then
        return true
    end

    local case_sensitive = search_config and search_config.case_sensitive
    local pattern = case_sensitive and search_value or string.lower(search_value)

    local message_text = resolve_text(entry.message, entry.message_lower, case_sensitive)
    if Search.optimized_find(message_text, pattern, case_sensitive) then
        return true
    end

    local category_text = resolve_text(category, entry.category_lower, case_sensitive)
    return Search.optimized_find(category_text, pattern, case_sensitive) ~= nil
end

-- Ensures filter object has all derived maps initialized
-- Converts state maps to include/exclude flag maps
-- @param filters table: Filter configuration object to update
function M.ensure_derived_maps(filters)
    if not filters then
        return
    end

    filters.level_states = filters.level_states or {}
    filters.category_states = filters.category_states or {}

    filters.levels = filters.levels or {}
    filters.exclude_levels = filters.exclude_levels or {}
    filters.categories = filters.categories or {}
    filters.exclude_categories = filters.exclude_categories or {}

    map_state_flags(filters.level_states, filters.levels, filters.exclude_levels)
    map_state_flags(filters.category_states, filters.categories, filters.exclude_categories)
end

BetterConsole.FilterEvaluator = M
Core.FilterEvaluator = M
end

do
local M = {}

local Search = BetterConsole.Search
local Constants = BetterConsole.Models.Constants
local TimeConstants = Constants.Time

-- Fallback plain text find function
-- @param text string: Text to search
-- @param pattern string: Pattern to find
-- @param case_sensitive boolean: Whether search is case-sensitive
-- @return number|nil: Start position or nil
local function plain_find(text, pattern, case_sensitive)
    return string.find(text, pattern, 1, true)
end

-- Resolves which find function to use for search
-- @param optimized_find function: Optional optimized find function
-- @return function: Find function to use
local function resolve_finder(optimized_find)
    if optimized_find then
        return optimized_find
    end

    if Search and Search.optimized_find then
        return Search.optimized_find
    end

    return plain_find
end

-- Builds search context from filters for optimization
-- @param filters table: Filter configuration
-- @param search_config table: Search configuration with case_sensitive flag
-- @return table|nil: Search context with pattern and case_sensitive, or nil if no search
local function build_search_context(filters, search_config)
    if not filters then
        return nil
    end

    local search_value = filters.search
    if type(search_value) ~= "string" or search_value == "" then
        return nil
    end

    local case_sensitive = search_config and search_config.case_sensitive
    local pattern = case_sensitive and search_value or string.lower(search_value)

    return {
        pattern = pattern,
        case_sensitive = case_sensitive
    }
end

-- Resolves entry text for search with case handling
-- @param value string: Original text value
-- @param cached_lower string: Cached lowercase version
-- @param case_sensitive boolean: Whether search is case-sensitive
-- @return string: Text to use for search
local function resolve_entry_text(value, cached_lower, case_sensitive)
    if case_sensitive then
        return value or ""
    end

    if cached_lower then
        return cached_lower
    end

    return string.lower(value or "")
end

-- Checks if entry matches search criteria
-- @param entry table: LogEntry instance
-- @param search_context table: Search context with pattern and case_sensitive
-- @param optimized_find function: Optional optimized find function
-- @return boolean: True if entry matches search
local function entry_matches_search(entry, search_context, optimized_find)
    if not search_context then
        return true
    end

    local finder = resolve_finder(optimized_find)
    local case_sensitive = search_context.case_sensitive
    local pattern = search_context.pattern

    local message_text = resolve_entry_text(entry.message, entry.message_lower, case_sensitive)
    if finder(message_text, pattern, case_sensitive) then
        return true
    end

    local category_text = resolve_entry_text(entry.category, entry.category_lower, case_sensitive)
    return finder(category_text, pattern, case_sensitive) ~= nil
end

-- Determines if entry should be included based on search filters
-- @param entry table: LogEntry instance
-- @param filters table: Filter configuration
-- @param search_config table: Search configuration
-- @param optimized_find function: Optional optimized find function
-- @param search_context table: Optional pre-built search context
-- @return boolean: True if entry should be included
function M.should_include_entry(entry, filters, search_config, optimized_find, search_context)
    if not entry then
        return false
    end

    local context = search_context or build_search_context(filters, search_config)
    return entry_matches_search(entry, context, optimized_find)
end

-- Applies search filters to all entries and returns matching results
-- @param all_entries table: Entry collection with iterate() method
-- @param filters table: Filter configuration
-- @param search_config table: Search configuration
-- @param optimized_find function: Optional optimized find function
-- @param max_results number: Optional maximum results to return
-- @return table: Array of matching entries
function M.apply_filtering(all_entries, filters, search_config, optimized_find, max_results)
    if not all_entries or type(all_entries.iterate) ~= "function" then
        return {}
    end

    local results = {}
    local context = build_search_context(filters, search_config)
    local limit = max_results or math.huge

    for _, entry in all_entries:iterate() do
        if M.should_include_entry(entry, filters, search_config, optimized_find, context) then
            results[#results + 1] = entry
            if #results >= limit then
                break
            end
        end
    end

    return results
end

-- Incrementally filters new entries and adds matches to current display
-- @param new_entries table: Array of new entries to filter
-- @param current_display_entries table: Current display entries array to append to
-- @param filters table: Filter configuration
-- @param search_config table: Search configuration
-- @param optimized_find function: Optional optimized find function
-- @param max_results number: Optional maximum total results
-- @return number: Count of entries added
function M.apply_incremental_filtering(new_entries, current_display_entries, filters, search_config, optimized_find, max_results)
    if not new_entries or #new_entries == 0 then
        return 0
    end

    local context = build_search_context(filters, search_config)
    local limit = max_results or math.huge
    local added_count = 0

    for _, entry in ipairs(new_entries) do
        if #current_display_entries >= limit then
            break
        end

        if M.should_include_entry(entry, filters, search_config, optimized_find, context) then
            current_display_entries[#current_display_entries + 1] = entry
            added_count = added_count + 1
        end
    end

    return added_count
end

-- Initializes state for chunked filtering operation
-- @param all_entries table: Entry collection to filter
-- @return table: Chunk state object for tracking progress
function M.init_chunked_filtering(all_entries)
    return {
        is_processing = true,
        current_index = 1,
        temp_results = {},
        all_entries = all_entries,
        start_time = os.clock() * TimeConstants.MS_PER_SECOND,
        total_processed = 0
    }
end

-- Processes one chunk of entries for filtering with time budget
-- @param chunk_state table: Chunk state from init_chunked_filtering
-- @param filters table: Filter configuration
-- @param search_config table: Search configuration
-- @param optimized_find function: Optional optimized find function
-- @param constants table: Performance constants with chunk size and time limits
-- @return boolean: True if more chunks remain, false if complete
function M.process_chunk(chunk_state, filters, search_config, optimized_find, constants)
    if not chunk_state or not constants then
        return false
    end

    local entries = chunk_state.all_entries
    if not entries or type(entries.iterate) ~= "function" then
        return false
    end

    local start_time = os.clock() * TimeConstants.MS_PER_SECOND
    local chunk_size = constants.FILTER_CHUNK_SIZE or math.huge
    local max_time_ms = constants.FILTER_MAX_TIME_MS or math.huge
    local min_results = constants.FILTER_MIN_RESULTS or 0
    local max_display_results = constants.MAX_DISPLAY_RESULTS or math.huge

    local context = build_search_context(filters, search_config)
    local processed_this_frame = 0
    local iterator = entries:iterate()
    local total_entries = entries:get_entry_count()
    local current_index = 0

    for _, entry in iterator do
        current_index = current_index + 1

        if current_index >= chunk_state.current_index then
            if entry_matches_search(entry, context, optimized_find) then
                chunk_state.temp_results[#chunk_state.temp_results + 1] = entry
            end

            processed_this_frame = processed_this_frame + 1
            chunk_state.total_processed = chunk_state.total_processed + 1

            local elapsed_time = os.clock() * TimeConstants.MS_PER_SECOND - start_time
            local reached_chunk_limit = processed_this_frame >= chunk_size
            local reached_time_budget = elapsed_time > max_time_ms
            local reached_min_results = context and #chunk_state.temp_results >= min_results
            local reached_max_results = #chunk_state.temp_results >= max_display_results

            if reached_chunk_limit or reached_time_budget or reached_min_results or reached_max_results then
                chunk_state.current_index = current_index + 1

                if current_index >= total_entries or reached_max_results then
                    return false
                end

                return true
            end
        end
    end

    return false
end

BetterConsole.Filters = M
Core.Filters = M
end

do
local M = {}

M.State = {
    CLEAN = 0,
    ENTRIES_DIRTY = 1,
    FILTERS_DIRTY = 2,
    CATEGORIES_DIRTY = 3,
    FULL_REFRESH = 4
}

local State = M.State
local STATE_NAMES = {
    [State.CLEAN] = "CLEAN",
    [State.ENTRIES_DIRTY] = "ENTRIES_DIRTY",
    [State.FILTERS_DIRTY] = "FILTERS_DIRTY",
    [State.CATEGORIES_DIRTY] = "CATEGORIES_DIRTY",
    [State.FULL_REFRESH] = "FULL_REFRESH"
}

-- Promotes current state to target if target is higher priority
-- @param self table: StateManager instance
-- @param target_state number: Target state constant
local function promote_state(self, target_state)
    if self.current_state < target_state then
        self.current_state = target_state
    end
end

-- Creates new StateManager instance
-- @return table: StateManager instance with clean state
function M.new()
    local instance = {
        current_state = State.CLEAN,
        _has_new_entries = false,
        categories_need_update = false,
        filters_dirty = false
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Marks entries as dirty indicating new entries added
function M:mark_entries_dirty()
    promote_state(self, State.ENTRIES_DIRTY)
    self._has_new_entries = true
end

-- Marks filters as dirty indicating filter criteria changed
function M:mark_filters_dirty()
    promote_state(self, State.FILTERS_DIRTY)
    self.filters_dirty = true
end

-- Marks categories as dirty indicating category list changed
function M:mark_categories_dirty()
    promote_state(self, State.CATEGORIES_DIRTY)
    self.categories_need_update = true
end

-- Marks state for full UI refresh
function M:mark_full_refresh()
    self.current_state = State.FULL_REFRESH
end

-- Checks if any update is needed
-- @return boolean: True if state is not clean
function M:needs_update()
    return self.current_state ~= State.CLEAN or self._has_new_entries
end

-- Checks if full refresh is needed
-- @return boolean: True if full refresh required
function M:needs_full_refresh()
    return self.current_state == State.FULL_REFRESH
end

-- Checks if entries refresh is needed
-- @return boolean: True if entries need refresh
function M:needs_entries_refresh()
    return self.current_state == State.ENTRIES_DIRTY or self._has_new_entries
end

-- Checks if filters refresh is needed
-- @return boolean: True if filters need refresh
function M:needs_filters_refresh()
    return self.current_state >= State.FILTERS_DIRTY or self.filters_dirty
end

-- Checks if categories need update
-- @return boolean: True if categories need update
function M:needs_categories_update()
    return self.categories_need_update
end

-- Checks if new entries flag is set
-- @return boolean: True if has new entries
function M:has_new_entries()
    return self._has_new_entries
end

-- Clears all dirty flags and resets to clean state
function M:clear_dirty()
    self.current_state = State.CLEAN
    self._has_new_entries = false
end

-- Clears only new entries flag
function M:clear_new_entries()
    self._has_new_entries = false
end

-- Clears categories dirty flag
function M:clear_categories_dirty()
    self.categories_need_update = false
end

-- Clears filters dirty flag
function M:clear_filters_dirty()
    self.filters_dirty = false
end

-- Clears full refresh state
function M:clear_full_refresh()
    if self.current_state == State.FULL_REFRESH then
        self.current_state = State.CLEAN
    end
end

-- Gets human-readable state name
-- @return string: State name
function M:get_state_string()
    return STATE_NAMES[self.current_state] or "UNKNOWN"
end

BetterConsole.StateManager = M
Core.StateManager = M
end

do
local M = {}

local Models = BetterConsole.Models
local Constants = Models.Constants
local AntiSpamConstants = Constants.AntiSpam
local DEFAULT_CATEGORY = Constants.Categories.SYSTEM
local TimeConstants = Constants.Time
local HASH_MULTIPLIER = 31
local HASH_MODULO = 2147483647
local CLEANUP_INTERVAL_MS = 1000
local PATTERN_REDUCTION_RATIO = 0.8
local HISTORY_REBASE_THRESHOLD = 128

-- Gets current time in milliseconds
-- @return number: Current time in milliseconds
local function now_ms()
    local clock = BetterConsole.Clock
    if clock and clock.now_ms then
        return clock.now_ms()
    end
    return os.clock() * TimeConstants.MS_PER_SECOND
end

-- Normalizes message by replacing numbers and timestamps with placeholders
-- @param message_str string: Message to normalize
-- @return string: Normalized message pattern
local function normalize_message(message_str)
    local normalized = string.gsub(message_str, "%d+", "#")
    normalized = string.gsub(normalized, "%[%d+:%d+:%d+%]", "[##:##:##]")
    normalized = string.gsub(normalized, "0x%x+", "0x##")
    normalized = string.gsub(normalized, "%d+%.%d+", "#.#")
    return normalized
end

-- Creates new message history tracking object
-- @return table: History object with circular buffer for timestamps
local function create_history()
    return {
        timestamps = {},
        start_index = 1,
        end_index = 0,
        count = 0,
        last_time = 0
    }
end

-- Resets history to empty state
-- @param history table: History object to reset
local function reset_history(history)
    history.timestamps = {}
    history.start_index = 1
    history.end_index = 0
    history.count = 0
    history.last_time = 0
end

-- Rebases history buffer to reduce memory fragmentation
-- @param history table: History object to rebase
local function rebase_history(history)
    if history.count == 0 then
        reset_history(history)
        return
    end

    if history.start_index <= HISTORY_REBASE_THRESHOLD then
        return
    end

    local timestamps = history.timestamps
    local new_table = {}
    local new_index = 1

    for idx = history.start_index, history.end_index do
        local ts = timestamps[idx]
        if ts then
            new_table[new_index] = ts
            new_index = new_index + 1
        end
    end

    history.timestamps = new_table
    history.start_index = 1
    history.end_index = new_index - 1
end

-- Removes timestamps older than cutoff time from history
-- @param history table: History object to prune
-- @param cutoff_time number: Cutoff time in milliseconds
local function prune_history_before(history, cutoff_time)
    local timestamps = history.timestamps
    local start = history.start_index
    local finish = history.end_index

    while start <= finish do
        local timestamp = timestamps[start]
        if not timestamp or timestamp > cutoff_time then
            break
        end

        timestamps[start] = nil
        start = start + 1
        history.count = history.count - 1
    end

    if history.count <= 0 then
        reset_history(history)
        return
    end

    history.start_index = start

    while history.end_index >= history.start_index and timestamps[history.end_index] == nil do
        history.end_index = history.end_index - 1
    end

    history.last_time = timestamps[history.end_index] or history.last_time
    rebase_history(history)
end

-- Appends timestamp to history buffer
-- @param history table: History object
-- @param timestamp number: Timestamp to append in milliseconds
local function append_timestamp(history, timestamp)
    history.end_index = history.end_index + 1
    history.timestamps[history.end_index] = timestamp
    history.count = history.count + 1
    history.last_time = timestamp
end

-- Counts number of entries in a map
-- @param map table: Map to count
-- @return number: Count of entries
local function count_entries(map)
    local count = 0
    for _ in pairs(map) do
        count = count + 1
    end
    return count
end

-- Creates new SpamBlocker instance
-- @return table: SpamBlocker instance with empty state
function M.new()
    local instance = {
        enabled = true,
        message_patterns = {},
        blocked_patterns = {},
        total_blocked = 0,
        last_cleanup = now_ms()
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Generates hash for message pattern identification
-- @param message string: Message to hash
-- @param category string: Optional category
-- @return string: Hash string for pattern matching
function M:generate_message_hash(message, category)
    if not message then
        return ""
    end

    local normalized = normalize_message(tostring(message))
    local hash_input = (category or DEFAULT_CATEGORY) .. "|" .. normalized
    local hash = 0

    for index = 1, #hash_input do
        hash = (hash * HASH_MULTIPLIER + string.byte(hash_input, index)) % HASH_MODULO
    end

    return tostring(hash)
end

function M:cleanup_expired_patterns()
    local current_time = now_ms()

    if current_time - self.last_cleanup < CLEANUP_INTERVAL_MS then
        return
    end

    local expire_time = current_time - AntiSpamConstants.BLOCK_EXPIRE_MS
    local pattern_count = 0
    local sorted_patterns = {}

    for hash, history in pairs(self.message_patterns) do
        prune_history_before(history, expire_time)

        if history.count <= 0 then
            self.message_patterns[hash] = nil
            self.blocked_patterns[hash] = nil
        else
            pattern_count = pattern_count + 1
            table.insert(sorted_patterns, {
                hash = hash,
                last_time = history.last_time or 0
            })
        end
    end

    local max_tracked = AntiSpamConstants.MAX_TRACKED_PATTERNS
    if pattern_count > max_tracked then
        table.sort(sorted_patterns, function(a, b)
            return a.last_time < b.last_time
        end)

        local retention_target = math.floor(max_tracked * PATTERN_REDUCTION_RATIO)
        local to_remove = math.max(0, pattern_count - retention_target)

        for index = 1, to_remove do
            local target = sorted_patterns[index]
            if not target then
                break
            end
            local hash = target.hash
            self.message_patterns[hash] = nil
            self.blocked_patterns[hash] = nil
        end
    end

    self.last_cleanup = current_time
end

-- Determines if message should be blocked as spam
-- @param level string: Log level
-- @param category string: Log category
-- @param message string: Message content
-- @return boolean, table, boolean: Should block, blocked info, is first block
function M:should_block_message(level, category, message)
    if not self.enabled then
        return false, nil, false
    end

    self:cleanup_expired_patterns()

    local hash = self:generate_message_hash(message, category)
    local current_time = now_ms()

    local cutoff_time = current_time - AntiSpamConstants.TIME_WINDOW_MS
    local message_history = self.message_patterns[hash]
    if not message_history then
        message_history = create_history()
        self.message_patterns[hash] = message_history
    end

    prune_history_before(message_history, cutoff_time)
    append_timestamp(message_history, current_time)

    if message_history.count < AntiSpamConstants.SPAM_THRESHOLD then
        return false, nil, false
    end

    local blocked_info = self.blocked_patterns[hash]
    local is_first_block = false

    if not blocked_info then
        blocked_info = {
            count = 0,
            first_block_time = current_time,
            sample_message = message,
            category = category,
            level = level,
            notification_shown = false
        }
        self.blocked_patterns[hash] = blocked_info
        is_first_block = true
    end

    blocked_info.count = blocked_info.count + 1
    self.total_blocked = self.total_blocked + 1

    return true, blocked_info, is_first_block
end

-- Gets spam blocker statistics
-- @return table: Stats with total_blocked, active_patterns, and enabled flag
function M:get_stats()
    return {
        total_blocked = self.total_blocked,
        active_patterns = count_entries(self.blocked_patterns),
        enabled = self.enabled
    }
end

-- Sets spam blocking enabled state
-- @param enabled boolean: Whether spam blocking is enabled
function M:set_enabled(enabled)
    self.enabled = enabled

    if not enabled then
        self:reset()
    end
end

-- Resets all spam tracking state
function M:reset()
    self.message_patterns = {}
    self.blocked_patterns = {}
    self.total_blocked = 0
    self.last_cleanup = now_ms()
end

-- Gets map of currently blocked patterns
-- @return table: Map of blocked pattern info
function M:get_blocked_patterns()
    return self.blocked_patterns
end

BetterConsole.SpamBlocker = M
Core.SpamBlocker = M
end
-- SelectionManager module for managing multi-selection state
do
local M = {}

-- Updates selection state for an entry
-- @param self table: SelectionManager instance
-- @param index number: Entry index
-- @param should_select boolean: Whether entry should be selected
local function update_selection(self, index, should_select)
    if not index then
        return
    end

    local currently_selected = self.selected_entries[index] == true
    if should_select == currently_selected then
        return
    end

    if should_select then
        self.selected_entries[index] = true
        self.selected_count = self.selected_count + 1
        self.last_selected_index = index
        return
    end

    self.selected_entries[index] = nil
    if self.selected_count > 0 then
        self.selected_count = self.selected_count - 1
    end
end

-- Creates new SelectionManager instance
-- @return table: SelectionManager with empty selection
function M.new()
    local instance = {
        selected_entries = {},
        last_selected_index = nil,
        selected_count = 0
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Clears all selections
function M:clear()
    self.selected_entries = {}
    self.last_selected_index = nil
    self.selected_count = 0
end

-- Toggles selection state for an entry
-- @param index number: Entry index to toggle
function M:toggle(index)
    update_selection(self, index, not self.selected_entries[index])
end

-- Selects an entry
-- @param index number: Entry index to select
function M:select(index)
    update_selection(self, index, true)
end

-- Selects range of entries
-- @param start_index number: Start index
-- @param end_index number: End index
function M:select_range(start_index, end_index)
    if type(start_index) ~= "number" or type(end_index) ~= "number" then
        return
    end

    local min_index = math.min(start_index, end_index)
    local max_index = math.max(start_index, end_index)

    for index = min_index, max_index do
        update_selection(self, index, true)
    end

    self.last_selected_index = end_index
end

-- Selects all entries from display
-- @param display_entries table: Array of display entries
function M:select_all(display_entries)
    self.selected_entries = {}
    self.selected_count = 0
    self.last_selected_index = nil

    if not display_entries then
        return
    end

    for index = 1, #display_entries do
        update_selection(self, index, true)
    end
end

-- Gets array of selected entries
-- @param display_entries table: Array of display entries
-- @return table: Array of selected entries in order
function M:get_selected(display_entries)
    display_entries = display_entries or {}
    local indices = {}
    for index, _ in pairs(self.selected_entries) do
        table.insert(indices, index)
    end

    table.sort(indices)

    local entries = {}
    for _, index in ipairs(indices) do
        local entry = display_entries[index]
        if entry then
            table.insert(entries, entry)
        end
    end

    return entries
end

-- Checks if entry is selected
-- @param index number: Entry index
-- @return boolean: True if selected
function M:is_selected(index)
    return self.selected_entries[index] == true
end

-- Gets count of selected entries
-- @return number: Count of selected entries
function M:get_count()
    return self.selected_count
end

-- Gets index of last selected entry
-- @return number|nil: Last selected index or nil
function M:get_last_index()
    return self.last_selected_index
end

BetterConsole.SelectionManager = M
Core.SelectionManager = M
end

-- RepositoryInterface module defining repository contract and factory
do
local M = {}

local Models = BetterConsole.Models
local DEFAULT_REPOSITORY_CAPACITY = Models.Constants.Performance.MAX_ENTRIES

-- Repository interface defining required methods
M.IRepository = {}

-- Adds entry to repository
-- @param entry table: LogEntry to add
function M.IRepository:add(entry)
    error("IRepository:add() must be implemented by concrete repository")
end

-- Gets entry at index
-- @param index number: Entry index
function M.IRepository:get(index)
    error("IRepository:get() must be implemented by concrete repository")
end

-- Gets all entries
-- @return table: All entries
function M.IRepository:get_all()
    error("IRepository:get_all() must be implemented by concrete repository")
end

-- Queries entries with filter
-- @param filter function: Filter function
function M.IRepository:query(filter)
    error("IRepository:query() must be implemented by concrete repository")
end

-- Gets new entries since total count
-- @param from_total number: Previous total count
-- @return table: New entries
function M.IRepository:get_new_entries(from_total)
    error("IRepository:get_new_entries() must be implemented by concrete repository")
end

-- Clears all entries
function M.IRepository:clear()
    error("IRepository:clear() must be implemented by concrete repository")
end

-- Gets entry count
-- @return number: Entry count
function M.IRepository:count()
    error("IRepository:count() must be implemented by concrete repository")
end

-- Gets total entries added lifetime
-- @return number: Total added
function M.IRepository:get_total_added()
    error("IRepository:get_total_added() must be implemented by concrete repository")
end

-- Factory function to create repository instances
-- @param repository_type string: Type of repository ("memory" or "file")
-- @param config table: Configuration with capacity and optional file_path
-- @return table: Repository instance
function M.create_repository(repository_type, config)
    config = config or {}
    local capacity = config.capacity or DEFAULT_REPOSITORY_CAPACITY

    if repository_type == "memory" then
        return BetterConsole.MemoryRepository.new(capacity)
    elseif repository_type == "file" then
        if BetterConsole.FileRepository then
            return BetterConsole.FileRepository.new(config.file_path, capacity)
        else
            error("FileRepository not available")
        end
    else
        error("Unknown repository type: " .. tostring(repository_type))
    end
end

BetterConsole.RepositoryInterface = M
Core.RepositoryInterface = M
end

do
local M = {}

local RepositoryInterface = BetterConsole.RepositoryInterface
local Models = BetterConsole.Models
local Validators = nil

-- Lazy-loads Validators module
-- @return table: Validators module instance
local function get_validators()
    if not Validators then
        Validators = BetterConsole.Validators
    end
    return Validators
end

-- Creates new Store instance with repository
-- @param repository_type string: Type of repository ("memory" or "file")
-- @param config table: Configuration with capacity and optional file_path
-- @return table: Store instance
function M.new(repository_type, config)
    repository_type = repository_type or "memory"
    config = config or {}

    local capacity = config.capacity or Models.Constants.Performance.MAX_ENTRIES
    config.capacity = capacity

    local instance = {
        repository = RepositoryInterface.create_repository(repository_type, config),
        repository_type = repository_type,
        entries = {},
        entries_dirty = true
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Adds and validates log entry
-- @param level string: Log level
-- @param category string: Log category
-- @param message string: Log message
-- @param data table: Optional metadata
-- @return table|nil, string: Log entry or nil and error message
function M:add_entry(level, category, message, data)
    local validators = get_validators()

    local ok, result = validators.validate_log_entry(level, category, message, data)
    if not ok then
        if d then
            d("[BetterConsole] Validation error: " .. tostring(result))
        end
        return nil, result
    end

    local validated = result
    local entry = Models.LogEntry.new(
        validated.level,
        validated.category,
        validated.message,
        validated.data
    )

    local success = self.repository:add(entry)
    if success then
        self.entries_dirty = true
        return entry
    end

    return nil, "Failed to persist log entry"
end

-- Flushes pending writes to storage
-- @param force boolean: Whether to force flush
function M:flush_pending(force)
    if not self.repository then
        return
    end

    if self.repository.maybe_flush then
        self.repository:maybe_flush(force)
    elseif self.repository.flush_pending_writes then
        self.repository:flush_pending_writes(force)
    end
end

-- Gets all entries with caching
-- @return table: Array of all entries
function M:get_entries()
    if self.entries_dirty then
        self.entries = self.repository:get_all()
        self.entries_dirty = false
    end
    return self.entries
end

-- Creates lazy iterator for entries
-- @return table: Entry iterator
function M:create_lazy_entry_iterator()
    return self.repository:get_all()
end

-- Gets entry count
-- @return number: Total entry count
function M:get_entry_count()
    return self.repository:count()
end

-- Gets total entries added lifetime
-- @return number: Total added
function M:get_total_added()
    return self.repository:get_total_added()
end

-- Gets new entries since total count
-- @param from_total number: Previous total count
-- @return table: Array of new entries
function M:get_new_entries(from_total)
    return self.repository:get_new_entries(from_total)
end

-- Clears all entries from store
-- @return boolean: Success flag
function M:clear_entries()
    local success = self.repository:clear()
    if success then
        self.entries = {}
        self.entries_dirty = true
    end
    return success
end

-- Queries entries with custom filter
-- @param filter function: Filter function
-- @return table: Filtered entries
function M:query(filter)
    return self.repository:query(filter)
end

-- Gets repository type
-- @return string: Repository type ("memory" or "file")
function M:get_repository_type()
    return self.repository_type
end

BetterConsole.Store = M
Core.Store = M
end

return Core
