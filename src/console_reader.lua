--[[
    BetterConsole Console Reader Module

    Polls GetConsoleLines() to capture messages that bypass intercepts.
    Works alongside the intercept system for hybrid message capture.

    Features:
    - Startup backfill: Captures messages logged before BetterConsole initialized
    - Periodic polling: Catches messages from native code
    - Hash-based deduplication: Avoids duplicates between intercept and poll paths
    - Native console sync: ClearConsole() integration

    Dependencies:
    - BetterConsole.Intercept for parsing functions
    - GetConsoleLines() and ClearConsole() Minion APIs
]]

local ConsoleReader = {}

local BetterConsole = rawget(_G, "BetterConsole")
if type(BetterConsole) ~= "table" then
    BetterConsole = {}
end

local M = {}

-- Configuration constants
local POLL_INTERVAL_MS = 150
local HASH_EXPIRY_MS = 5000
local MAX_TRACKED_HASHES = 10000
local MS_PER_SECOND = 1000
local MAX_LINES_PER_POLL = 100
local CLEANUP_INTERVAL_MS = 1000
local FNV_OFFSET_BASIS = 2166136261
local FNV_PRIME = 16777619
local HASH_MODULO = 2147483647

-- Module state
local state = {
    poll_interval_ms = POLL_INTERVAL_MS,
    last_poll_time = 0,
    last_cleanup_time = 0,
    seen_line_hashes = {},
    hash_timestamps = {},
    hash_count = 0,
    last_known_line_count = 0,
    backfill_completed = false,
    is_enabled = true,
    console_instance = nil,

    extract_timestamp = nil,
    extract_category = nil,
    detect_log_level = nil,
}

-- Default category when extraction fails
local DEFAULT_CATEGORY = "Minion"
local DEFAULT_LOG_LEVEL = "INFO"

-- ============================================================================
-- Time Utilities
-- ============================================================================

local function now_ms()
    return os.clock() * MS_PER_SECOND
end

-- ============================================================================
-- Hash Computation
-- ============================================================================

--- Computes a fast hash of a string using FNV-1a algorithm
-- @param str string The string to hash
-- @return string Hash as string for use as table key
local function compute_hash(str)
    if not str or str == "" then
        return "0"
    end

    local hash = FNV_OFFSET_BASIS
    for i = 1, #str do
        local byte = string.byte(str, i)
        hash = hash * FNV_PRIME
        hash = hash % HASH_MODULO
        hash = hash + byte
        hash = hash % HASH_MODULO
    end

    return tostring(hash)
end

--- Normalizes hash components for consistent deduping
-- @param value any Value to normalize
-- @return string Normalized string
local function normalize_hash_field(value)
    if value == nil then
        return ""
    end

    local str = tostring(value)
    str = string.gsub(str, "^%s+", "")
    str = string.gsub(str, "%s+$", "")
    return str
end

--- Computes hash for a normalized log entry
-- @param level string Log level
-- @param category string Log category
-- @param message string Log message
-- @return string Hash as string for use as table key
local function compute_entry_hash(level, category, message)
    local level_str = normalize_hash_field(level)
    if level_str ~= "" then
        level_str = string.upper(level_str)
    end
    local category_str = normalize_hash_field(category)
    local message_str = normalize_hash_field(message)
    return compute_hash(level_str .. "|" .. category_str .. "|" .. message_str)
end

-- ============================================================================
-- Hash Table Management
-- ============================================================================

--- Registers a hash as seen
-- @param hash string The hash to register
-- @param timestamp number The timestamp when first seen
local function register_hash(hash, timestamp)
    if state.seen_line_hashes[hash] then
        return
    end

    state.seen_line_hashes[hash] = timestamp
    state.hash_count = state.hash_count + 1
end

--- Checks if a hash has been seen recently
-- @param hash string The hash to check
-- @return boolean True if hash exists and is not expired
local function is_hash_seen(hash)
    return state.seen_line_hashes[hash] ~= nil
end

--- Removes expired hashes from the tracking table
-- @param current_time number Current timestamp in milliseconds
local function cleanup_expired_hashes(current_time)
    local expiry_threshold = current_time - HASH_EXPIRY_MS
    local to_remove = {}

    for hash, timestamp in pairs(state.seen_line_hashes) do
        if timestamp < expiry_threshold then
            to_remove[#to_remove + 1] = hash
        end
    end

    for _, hash in ipairs(to_remove) do
        state.seen_line_hashes[hash] = nil
        state.hash_count = state.hash_count - 1
    end

    if state.hash_count > MAX_TRACKED_HASHES then
        evict_oldest_hashes(MAX_TRACKED_HASHES * 0.8)
    end
end

--- Evicts oldest hashes until count is below target
-- @param target_count number Target number of hashes to keep
local function evict_oldest_hashes(target_count)
    local sorted = {}
    for hash, timestamp in pairs(state.seen_line_hashes) do
        sorted[#sorted + 1] = { hash = hash, timestamp = timestamp }
    end

    table.sort(sorted, function(a, b)
        return a.timestamp < b.timestamp
    end)

    local remove_count = state.hash_count - target_count
    for i = 1, remove_count do
        if sorted[i] then
            state.seen_line_hashes[sorted[i].hash] = nil
            state.hash_count = state.hash_count - 1
        end
    end
end

-- ============================================================================
-- Parsing Functions
-- ============================================================================

--- Ensures parsing functions are loaded from Intercept module
local function ensure_parsing_functions()
    if state.extract_timestamp then
        return true
    end

    local Intercept = BetterConsole.Intercept
    if not Intercept then
        return false
    end

    state.extract_timestamp = Intercept.extract_timestamp
    state.extract_category = Intercept.extract_category
    state.detect_log_level = Intercept.detect_log_level

    return state.extract_timestamp ~= nil
end

--- Default timestamp extraction (fallback if Intercept not available)
-- @param message string The message to parse
-- @return string|nil, string Extracted timestamp and remaining message
local function default_extract_timestamp(message)
    if not message or message == "" then
        return nil, message
    end

    local timestamp, remaining = string.match(message, "^%[([%d:%.%-%s]+)%]%s*(.*)$")
    if timestamp then
        return timestamp, remaining
    end

    return nil, message
end

--- Default category extraction (fallback if Intercept not available)
-- @param message string The message to parse
-- @return string, string Category and cleaned message
local function default_extract_category(message)
    if not message or message == "" then
        return DEFAULT_CATEGORY, message
    end

    local category, remaining = string.match(message, "^%[([^%]]+)%]%s*[:%-]?%s*(.*)$")
    if category then
        return category, remaining
    end

    category, remaining = string.match(message, "^([%w_%-]+):%s*(.*)$")
    if category then
        return category, remaining
    end

    return DEFAULT_CATEGORY, message
end

--- Default log level detection (fallback if Intercept not available)
-- @param message string The message to check
-- @return string Detected log level
local function default_detect_log_level(message)
    if not message then
        return DEFAULT_LOG_LEVEL
    end

    local upper = string.upper(string.sub(message, 1, 100))

    if string.find(upper, "ERROR", 1, true) or string.find(upper, "FATAL", 1, true) then
        return "ERROR"
    elseif string.find(upper, "WARN", 1, true) then
        return "WARN"
    elseif string.find(upper, "DEBUG", 1, true) then
        return "DEBUG"
    end

    return DEFAULT_LOG_LEVEL
end

--- Normalizes native console message payload
-- Strips "D ="/"I ="/"E =" prefixes and surrounding quotes
-- @param message string Raw message payload
-- @return string Cleaned message
local function normalize_native_message(message)
    if not message or message == "" then
        return message
    end

    local cleaned = message
    cleaned = string.gsub(cleaned, "^%s*[%a]%s*=%s*", "")
    cleaned = string.gsub(cleaned, "^\"(.*)\"$", "%1")
    cleaned = string.gsub(cleaned, "^%s+", "")
    cleaned = string.gsub(cleaned, "%s+$", "")
    return cleaned
end

--- Normalizes time strings to HH:MM:SS when possible
-- @param time_string string Time string to normalize
-- @return string|nil Normalized time string
local function normalize_time_string(time_string)
    if not time_string or time_string == "" then
        return time_string
    end

    local hour, minute, second = string.match(time_string, "^(%d+):(%d+):(%d+)$")
    if hour and minute and second then
        return string.format("%02d:%02d:%02d", tonumber(hour), tonumber(minute), tonumber(second))
    end

    return time_string
end

--- Strips thread/time prefix before native message payload
-- @param message string Message after level prefix
-- @return string Cleaned message
local function strip_native_prefix(message)
    if not message or message == "" then
        return message
    end

    local trimmed = string.gsub(message, "^%s+", "")

    if string.sub(trimmed, 1, 1) == "[" then
        local close = string.find(trimmed, "]", 2, true)
        if close then
            local gt = string.find(trimmed, ">", close + 1, true)
            if gt then
                local between = string.sub(trimmed, close + 1, gt - 1)
                if string.match(between, "^%s*[%d:%.]+%s*$") then
                    local remainder = string.sub(trimmed, gt + 1)
                    remainder = string.gsub(remainder, "^%s+", "")
                    return remainder
                end
            end
        end
    end

    local time_prefix = string.match(trimmed, "^%d+:%d+:%d+")
    if time_prefix then
        local stripped = string.match(trimmed, "^%d+:%d+:%d+%s*>%s*(.*)$")
        if stripped then
            return stripped
        end
    end

    return trimmed
end

--- Parses the native console line format
-- Format: "YYYY-MM-DD HH:MM:SS [LEVEL] [##] MM:SS:mmm> D = "message""
-- @param line string Raw console line from GetConsoleLines()
-- @return string|nil, string|nil, string Timestamp, level, and message content
local function parse_native_console_format(line)
    if not line or line == "" then
        return nil, nil, line
    end

    local bare_message = string.match(line, "^%d+:%d+:%d+:%d+%s*>%s*(.*)$")
    if bare_message then
        return nil, nil, normalize_native_message(bare_message)
    end

    bare_message = string.match(line, "^%d+:%d+:%d+%s*>%s*(.*)$")
    if bare_message then
        return nil, nil, normalize_native_message(bare_message)
    end

    local timestamp = nil
    local remainder = line

    local date_part, time_part, rest = string.match(line,
        "^(%d%d%d%d%-%d%d%-%d%d)%s+(%d+:%d+:%d+)%s+(.*)$")
    if date_part and time_part and rest then
        timestamp = normalize_time_string(time_part)
        remainder = rest
    else
        local bracket_time, rest_bracket = string.match(line, "^%[(%d+:%d+:%d+)%]%s+(.*)$")
        if bracket_time and rest_bracket then
            timestamp = normalize_time_string(bracket_time)
            remainder = rest_bracket
        else
            local time_only, rest_time = string.match(line, "^(%d+:%d+:%d+)%s+(.*)$")
            if time_only and rest_time then
                timestamp = normalize_time_string(time_only)
                remainder = rest_time
            end
        end
    end

    local level, message = string.match(remainder, "^%[([A-Za-z]+)%]%s+(.*)$")
    if not level or not message then
        return nil, nil, line
    end

    message = strip_native_prefix(message)
    message = normalize_native_message(message)

    return timestamp, string.upper(level), message
end

--- Parses a console line into structured entry data
-- @param line string Raw console line
-- @return table|nil Parsed entry data or nil if invalid
local function parse_line(line)
    if not line or line == "" then
        return nil
    end

    local metadata = { source = "poll" }

    local native_timestamp, native_level, message = parse_native_console_format(line)

    if native_timestamp then
        metadata.extracted_timestamp = native_timestamp
    end

    local extract_cat = state.extract_category or default_extract_category
    local detect_level = state.detect_log_level or default_detect_log_level

    local level = native_level or detect_level(message)

    local category, cleaned_message = extract_cat(message)

    return {
        level = level,
        category = category,
        message = cleaned_message,
        metadata = metadata
    }
end

-- ============================================================================
-- Console Line Access
-- ============================================================================

--- Gets console lines from native API
-- @return table|nil Array of lines or nil if API unavailable
local function get_console_lines()
    local GetConsoleLines = rawget(_G, "GetConsoleLines")
    if not GetConsoleLines then
        return nil
    end

    local raw_output = GetConsoleLines()
    if not raw_output or raw_output == "" then
        return {}
    end

    local lines = {}
    for line in raw_output:gmatch("[^\r\n]+") do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end

    return lines
end

-- ============================================================================
-- Entry Processing
-- ============================================================================

--- Adds a parsed entry to the console
-- @param parsed table Parsed entry data from parse_line
-- @param extra_metadata table|nil Additional metadata to merge
local function add_entry_from_parsed(parsed, extra_metadata)
    if not parsed or not state.console_instance then
        return
    end

    local metadata = parsed.metadata or {}

    if extra_metadata then
        for k, v in pairs(extra_metadata) do
            metadata[k] = v
        end
    end

    state.console_instance:add_entry(
        parsed.level,
        parsed.category,
        parsed.message,
        metadata
    )
end

--- Processes new console lines from polling
local function process_console_lines()
    local lines = get_console_lines()
    if not lines then
        return
    end

    local current_count = #lines
    local current_time = now_ms()

    if current_count < state.last_known_line_count then
        if state.console_instance and state.console_instance.add_entry then
            state.console_instance:add_entry("DEBUG", "ConsoleReader",
                "Native console was cleared externally")
        end
        state.seen_line_hashes = {}
        state.hash_count = 0
        state.last_known_line_count = 0
    end

    local start_index = state.last_known_line_count + 1
    local end_index = math.min(current_count, start_index + MAX_LINES_PER_POLL - 1)

    local added_count = 0
    for i = start_index, end_index do
        local line = lines[i]
        if line then
            local parsed = parse_line(line)
            if parsed then
                local hash = compute_entry_hash(parsed.level, parsed.category, parsed.message)
                if not is_hash_seen(hash) then
                    add_entry_from_parsed(parsed)
                    added_count = added_count + 1
                end
            end
        end
    end

    state.last_known_line_count = end_index
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Initializes the ConsoleReader module
-- @param console table The console instance to add entries to
function M.initialize(console)
    state.console_instance = console
    state.last_poll_time = now_ms()
    state.last_cleanup_time = now_ms()

    ensure_parsing_functions()

    M.perform_backfill()
end

--- Performs startup backfill of existing console lines
-- Captures messages logged before BetterConsole initialized
function M.perform_backfill()
    if state.backfill_completed or not state.console_instance then
        return
    end

    local lines = get_console_lines()
    if not lines or #lines == 0 then
        state.backfill_completed = true
        return
    end

    local current_time = now_ms()

    for _, line in ipairs(lines) do
        local parsed = parse_line(line)
        if parsed then
            local hash = compute_entry_hash(parsed.level, parsed.category, parsed.message)
            if not is_hash_seen(hash) then
                add_entry_from_parsed(parsed, { backfilled = true })
            end
        end
    end

    state.last_known_line_count = #lines
    state.backfill_completed = true

    state.console_instance:add_entry("DEBUG", "ConsoleReader",
        string.format("Backfilled %d pre-existing console lines", #lines))
end

--- Polls for new console lines (throttled)
-- Called from onDraw, internally manages timing
function M.poll()
    if not state.is_enabled or not state.console_instance then
        return
    end

    if not rawget(_G, "GetConsoleLines") then
        return
    end

    local current_time = now_ms()

    if (current_time - state.last_poll_time) < state.poll_interval_ms then
        return
    end

    state.last_poll_time = current_time

    if (current_time - state.last_cleanup_time) >= CLEANUP_INTERVAL_MS then
        cleanup_expired_hashes(current_time)
        state.last_cleanup_time = current_time
    end

    process_console_lines()
end

--- Registers an intercepted line's hash for deduplication
-- Called by Intercept module to pre-register hashes
-- @param message string The message that was intercepted
function M.register_intercepted_line(message)
    if not message or message == "" then
        return
    end

    ensure_parsing_functions()
    local extract_cat = state.extract_category or default_extract_category
    local detect_level = state.detect_log_level or default_detect_log_level
    local level = detect_level(message)
    local category, cleaned_message = extract_cat(message)
    local hash = compute_entry_hash(level, category, cleaned_message)
    register_hash(hash, now_ms())
end

--- Registers an intercepted entry for deduplication
-- @param level string Log level
-- @param category string Log category
-- @param message string Log message
function M.register_intercepted_entry(level, category, message)
    if not message or message == "" then
        return
    end

    local hash = compute_entry_hash(level, category, message)
    register_hash(hash, now_ms())
end

--- Clears the native console and resets tracking state
function M.clear_native_console()
    local ClearConsole = rawget(_G, "ClearConsole")
    if ClearConsole then
        ClearConsole()
    end

    state.seen_line_hashes = {}
    state.hash_count = 0
    state.last_known_line_count = 0
end

--- Enables or disables polling
-- @param enabled boolean Whether to enable polling
function M.set_enabled(enabled)
    state.is_enabled = enabled and true or false
end

--- Gets whether polling is enabled
-- @return boolean True if polling is enabled
function M.is_enabled()
    return state.is_enabled
end

--- Gets statistics about the ConsoleReader
-- @return table Statistics table
function M.get_stats()
    return {
        enabled = state.is_enabled,
        backfill_completed = state.backfill_completed,
        tracked_hashes = state.hash_count,
        last_known_line_count = state.last_known_line_count,
        poll_interval_ms = state.poll_interval_ms,
    }
end

--- Resets all state (for testing or reload)
function M.reset()
    state.seen_line_hashes = {}
    state.hash_count = 0
    state.last_known_line_count = 0
    state.backfill_completed = false
    state.last_poll_time = 0
    state.last_cleanup_time = 0
end

-- Export module
BetterConsole.ConsoleReader = M
ConsoleReader.M = M

return ConsoleReader
