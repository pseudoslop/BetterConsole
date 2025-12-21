local Integration = {}

local Models = BetterConsole and BetterConsole.Models
local Constants = Models and Models.Constants
local CategoryConstants = Constants and Constants.Categories
local FiltersConstants = Constants and Constants.Filters
local FilterStates = FiltersConstants and FiltersConstants.States
local Notifications = Constants and Constants.Notifications
local GeneralConstants = Constants and Constants.General

do
local M = {}

local INITIAL_COUNT = 0
local SEARCH_VERSION_INCREMENT = 1
local GC_DELAY_SECONDS = 2
local DEFAULT_CATEGORY = (CategoryConstants and CategoryConstants.ALL) or "All"
local CATEGORY_INDEX_ALL = (GeneralConstants and GeneralConstants.FIRST_INDEX) or 1
local DEFAULT_FILTER_STATE = (FilterStates and FilterStates.CLEARED) or 0
local DEFAULT_QUICK_FILTER = 1
local SHORT_NOTIFICATION_DURATION = (Notifications and Notifications.CLIPBOARD_DURATION) or 2
local DEFAULT_NOTIFICATION_DURATION = (Notifications and Notifications.DEFAULT_DURATION) or 3
local HISTORY_FIRST_INDEX = (GeneralConstants and GeneralConstants.FIRST_INDEX) or 1

local Command = {}
Command.__index = Command

function Command:execute(context)
    error("Command:execute() must be implemented by concrete command classes")
end

M.ClearEntriesCommand = {}
setmetatable(M.ClearEntriesCommand, { __index = Command })

function M.ClearEntriesCommand:execute(context)
    context.data_store:clear_entries()

    local ConsoleReader = BetterConsole.ConsoleReader
    if ConsoleReader and ConsoleReader.clear_native_console then
        ConsoleReader.clear_native_console()
    end

    context.display_entries = {}
    context.last_entry_count = INITIAL_COUNT
    context.last_total_added = INITIAL_COUNT
    context.last_processed_count = INITIAL_COUNT
    context.state_manager:mark_full_refresh()

    BetterConsole.VirtualScroll.mark_dirty(context.virtual_scroll)

    context.state_manager:mark_categories_dirty()
    context.cached_categories = { DEFAULT_CATEGORY }
    context.category_set = { [DEFAULT_CATEGORY] = true }
    context.category_to_index = { [DEFAULT_CATEGORY] = CATEGORY_INDEX_ALL }

    if context.search_coroutine then
        context.search_version = context.search_version + SEARCH_VERSION_INCREMENT
        context.search_coroutine = nil
        context.search_in_progress = false
    end

    if context.selection_manager and context.selection_manager.clear then
        context.selection_manager:clear()
    end
    context.selected_entry_for_metadata = nil

    context.pending_gc_time = os.clock() + GC_DELAY_SECONDS

    context:add_entry("INFO", "Console", "Console cleared")
    return true
end

M.ClearFiltersCommand = {}
setmetatable(M.ClearFiltersCommand, { __index = Command })

function M.ClearFiltersCommand:execute(context)
    context.filters.levels = {
        TRACE = true,
        DEBUG = true,
        INFO = true,
        WARN = true,
        ERROR = true
    }
    context.filters.level_states = {
        TRACE = DEFAULT_FILTER_STATE,
        DEBUG = DEFAULT_FILTER_STATE,
        INFO = DEFAULT_FILTER_STATE,
        WARN = DEFAULT_FILTER_STATE,
        ERROR = DEFAULT_FILTER_STATE
    }
    context.filters.categories = {}
    context.filters.category_states = {}
    context.filters.search = ""
    context.filters.exclude_categories = {}
    context.filters.exclude_levels = {}

    context.search.text = ""
    context.search.pending_text = ""
    context.search.last_input_time = INITIAL_COUNT

    context.current_quick_filter = DEFAULT_QUICK_FILTER

    if context.search_coroutine then
        context.search_version = context.search_version + SEARCH_VERSION_INCREMENT
        context.search_coroutine = nil
        context.search_in_progress = false
    end

    context.state_manager:mark_full_refresh()
    context.state_manager:mark_filters_dirty()
    BetterConsole.Prefs.save_user_prefs(context)

    context:show_status_notification("All filters cleared", DEFAULT_NOTIFICATION_DURATION)
    return true
end

M.ExecuteCodeCommand = {}
setmetatable(M.ExecuteCodeCommand, { __index = Command })

local function create_sandbox()
    local sandbox = {
        assert = assert,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = pcall,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        unpack = unpack,
        xpcall = xpcall,

        math = {
            abs = math.abs,
            acos = math.acos,
            asin = math.asin,
            atan = math.atan,
            atan2 = math.atan2,
            ceil = math.ceil,
            cos = math.cos,
            cosh = math.cosh,
            deg = math.deg,
            exp = math.exp,
            floor = math.floor,
            fmod = math.fmod,
            frexp = math.frexp,
            huge = math.huge,
            ldexp = math.ldexp,
            log = math.log,
            log10 = math.log10,
            max = math.max,
            min = math.min,
            modf = math.modf,
            pi = math.pi,
            pow = math.pow,
            rad = math.rad,
            random = math.random,
            sin = math.sin,
            sinh = math.sinh,
            sqrt = math.sqrt,
            tan = math.tan,
            tanh = math.tanh
        },

        string = {
            byte = string.byte,
            char = string.char,
            find = string.find,
            format = string.format,
            gmatch = string.gmatch,
            gsub = string.gsub,
            len = string.len,
            lower = string.lower,
            match = string.match,
            rep = string.rep,
            reverse = string.reverse,
            sub = string.sub,
            upper = string.upper
        },

        table = {
            concat = table.concat,
            insert = table.insert,
            maxn = table.maxn,
            remove = table.remove,
            sort = table.sort
        },

        loadstring = nil,
        load = nil,
        loadfile = nil,
        dofile = nil,
        require = nil,
        getfenv = nil,
        setfenv = nil,
        rawget = nil,
        rawset = nil,
        rawequal = nil,

        io = nil,
        os = nil,
        debug = nil,

        _G = nil,
        package = nil
    }

    return sandbox
end

function M.ExecuteCodeCommand:execute(context)
    local command = context.command

    if not command or command == "" then
        return false, "No command to execute"
    end

    context:add_entry("INFO", "Console", "Code: " .. command)

    local sandbox = create_sandbox()
    local func
    local load_err

    if type(loadstring) == "function" then
        func, load_err = loadstring(command)
        if func and type(setfenv) == "function" then
            setfenv(func, sandbox)
        end
    elseif type(load) == "function" then
        func, load_err = load(command, "BetterConsoleCommand", "t", sandbox)
    end

    if not func then
        if load_err then
            context:add_entry("ERROR", "Console", "Syntax error: " .. tostring(load_err))
        else
            context:add_entry("ERROR", "Console", "Failed to compile command")
        end
        return false, load_err
    end

    local ErrorHandler = BetterConsole.ErrorHandler
    local ok, result = ErrorHandler.try_catch(func, "execute_code")
    if not ok then
        context:add_entry("ERROR", "Console", "Runtime error: " .. tostring(result))
        return false, result
    end

    if result ~= nil and result ~= true then
        context:add_entry("INFO", "Console", "Result: " .. tostring(result))
    elseif result == nil then
        context:add_entry("INFO", "Console", "Code executed successfully")
    end

    return true, result
end

M.ExportCommand = {}
setmetatable(M.ExportCommand, { __index = Command })

function M.ExportCommand:execute(context)
    local entries = context.entries or context.display_entries
    local success, message = context.export_manager:export_to_clipboard(entries)

    if not success then
        context:add_entry("ERROR", "Console", message or "Failed to export to clipboard")
        return false, message
    end

    context:show_status_notification(message or "Exported entries to clipboard", SHORT_NOTIFICATION_DURATION)
    return true, message
end

M.SaveLogsCommand = {}
setmetatable(M.SaveLogsCommand, { __index = Command })

function M.SaveLogsCommand:execute(context)
    local filename = context.filename
    if not filename or filename == "" then
        filename = context.export_manager:generate_log_filename()
    end

    local entries = context.data_store:get_entries()
    local entries_list = {}

    if type(entries.iterate) == "function" then
        for i, entry in entries:iterate() do
            table.insert(entries_list, entry)
        end
    else
        entries_list = entries
    end

    local format = context.format or "text"
    local success, message = context.export_manager:export_to_file(entries_list, filename, format)

    if not success then
        context:add_entry("ERROR", "Console", message or "Failed to save logs to file")
        return false, message
    end

    context:add_entry("INFO", "Console", message or ("Saved logs to: " .. filename))
    return true, message
end

M.CommandHandler = {}
M.CommandHandler.__index = M.CommandHandler

local MAX_HISTORY_SIZE = 100

function M.new()
    local instance = {
        commands = {},
        history = {}
    }

    setmetatable(instance, M.CommandHandler)

    instance:register_command("clear", M.ClearEntriesCommand)
    instance:register_command("clear_filters", M.ClearFiltersCommand)
    instance:register_command("execute", M.ExecuteCodeCommand)
    instance:register_command("export", M.ExportCommand)
    instance:register_command("save_logs", M.SaveLogsCommand)

    return instance
end

function M.CommandHandler:register_command(name, command_class)
    if not name or name == "" then
        error("Command name cannot be empty")
    end

    if not command_class then
        error("Command class cannot be nil")
    end

    self.commands[name] = command_class
    return self
end

function M.CommandHandler:unregister_command(name)
    self.commands[name] = nil
    return self
end

function M.CommandHandler:has_command(name)
    return self.commands[name] ~= nil
end

function M.CommandHandler:execute(command_name, context)
    local command_class = self.commands[command_name]

    if not command_class then
        error("Unknown command: " .. tostring(command_name))
    end

    table.insert(self.history, {
        name = command_name,
        timestamp = os.clock(),
        context = context
    })

    if #self.history > MAX_HISTORY_SIZE then
        table.remove(self.history, HISTORY_FIRST_INDEX)
    end

    return command_class:execute(context)
end

function M.CommandHandler:get_history()
    return self.history
end

function M.CommandHandler:clear_history()
    self.history = {}
    return self
end

function M.CommandHandler:get_registered_commands()
    local command_names = {}
    for name, _ in pairs(self.commands) do
        table.insert(command_names, name)
    end
    table.sort(command_names)
    return command_names
end

BetterConsole.CommandHandler = M
    Integration.CommandHandler = M
end

do
local M = {}

local STRING_FIRST_CHAR = 1
local CHAR_ZERO = '0'
local CHAR_NINE = '9'
local DEFAULT_INTERCEPT_CATEGORY = (CategoryConstants and CategoryConstants.MINION) or "Minion"
local DEFAULT_LOG_LEVEL = "INFO"
local LOG_LEVEL_SEARCH_LENGTH = 100
local KEY_COUNT_INCREMENT = 1
local METADATA_KEY_THRESHOLD = 10
local ARRAY_ELEMENT_THRESHOLD = 3
local MAX_METADATA_KEYS = 10
local INITIAL_KEY_COUNT = 0

local serialize_value = BetterConsole.Strx.serialize_value
local normalize_category = BetterConsole.Strx.normalize_category
local ErrorHandler = BetterConsole.ErrorHandler

local original_d = _G.d
local original_error = _G.error
local original_stacktrace = _G.stacktrace
local original_ml_debug = _G.ml_debug
local original_ml_error = _G.ml_error
local original_ml_log = _G.ml_log
local original_table_print = table.print

local console_instance = nil

local METADATA_KEY_SET = {
    ["id"] = true, ["userid"] = true, ["user_id"] = true, ["timestamp"] = true, ["time"] = true,
    ["duration"] = true, ["source"] = true, ["action"] = true, ["status"] = true, ["code"] = true,
    ["error"] = true, ["warning"] = true, ["level"] = true, ["category"] = true, ["method"] = true,
    ["endpoint"] = true, ["file"] = true, ["line"] = true, ["function"] = true, ["module"] = true,
    ["component"] = true, ["session"] = true, ["request"] = true, ["response"] = true,
    ["count"] = true, ["size"] = true, ["length"] = true, ["retries"] = true, ["attempts"] = true,
    ["version"] = true, ["type"] = true, ["kind"] = true
}

local function extract_timestamp(message)
    if not message or message == "" then
        return nil, message
    end

    local first_char = string.sub(message, STRING_FIRST_CHAR, STRING_FIRST_CHAR)
    if first_char ~= '[' and (first_char < CHAR_ZERO or first_char > CHAR_NINE) then
        return nil, message
    end

    local timestamp, remaining = string.match(message, "^%[([%d:%.%-%s]+)%]%s*(.*)$")
    if timestamp and (string.match(timestamp, "%d%d:%d%d:%d%d") or string.match(timestamp, "%d%d%d%d%-%d%d%-%d%d")) then
        return timestamp, remaining
    end

    timestamp, remaining = string.match(message, "^([%d:%.]+)%s+(.+)$")
    if timestamp and string.match(timestamp, "^%d%d:%d%d:%d%d") then
        return timestamp, remaining
    end

    timestamp, remaining = string.match(message, "^([%d%-%s:%.]+)%s+(.+)$")
    if timestamp and string.match(timestamp, "%d%d%d%d%-%d%d%-%d%d%s+%d%d:%d%d:%d%d") then
        return timestamp, remaining
    end

    return nil, message
end

local function extract_category(message)
    if not message or message == "" then
        return DEFAULT_INTERCEPT_CATEGORY, message
    end

    local category, remaining = string.match(message, "^%[([^%]]+)%]%s*[:%-]?%s*(.*)$")
    if category then
        return normalize_category(category), remaining
    end

    category, remaining = string.match(message, "^([%w_%-]+):%s*(.*)$")
    if category and not BetterConsole.Strx.is_log_level_indicator(category) then
        return normalize_category(category), remaining
    end

    category, remaining = string.match(message, "^([%w_%-]+)%s*%-%s*(.*)$")
    if category then
        return normalize_category(category), remaining
    end

    category, remaining = string.match(message, "^<([^>]+)>%s*[:%-]?%s*(.*)$")
    if category then
        return normalize_category(category), remaining
    end

    return DEFAULT_INTERCEPT_CATEGORY, message
end

local LOG_LEVEL_PATTERN_CHECKS = {
    { "ERROR", { "ERROR", "ERR", "FATAL", "CRITICAL" } },
    { "WARN", { "WARNING", "WARN", "WRN" } },
    { "DEBUG", { "DEBUG", "DBG" } }
}

local function detect_log_level(message)
    if not message then
        return DEFAULT_LOG_LEVEL
    end

    local search_text = string.upper(string.sub(message, STRING_FIRST_CHAR, LOG_LEVEL_SEARCH_LENGTH))

    for _, level_data in ipairs(LOG_LEVEL_PATTERN_CHECKS) do
        local level, patterns = level_data[1], level_data[2]

        for _, pattern in ipairs(patterns) do
            if string.find(search_text, pattern, STRING_FIRST_CHAR, true) then
                return level
            end
        end
    end

    return DEFAULT_LOG_LEVEL
end

local function check_metadata_key(key)
    local lower_key = string.lower(key)

    if METADATA_KEY_SET[lower_key] then
        return true
    end

    for pattern in pairs(METADATA_KEY_SET) do
        if string.find(lower_key, pattern, STRING_FIRST_CHAR, true) then
            return true
        end
    end

    return false
end

local function is_metadata_table(tbl)
    if type(tbl) ~= "table" then
        return false
    end

    local has_array_elements = false
    local has_metadata_keys = false
    local key_count = INITIAL_KEY_COUNT

    for k, v in pairs(tbl) do
        key_count = key_count + KEY_COUNT_INCREMENT

        if type(k) == "number" then
            has_array_elements = true
        elseif type(k) == "string" then
            if not has_metadata_keys then
                has_metadata_keys = check_metadata_key(k)
            end
        end

        if has_metadata_keys and key_count <= METADATA_KEY_THRESHOLD then
            break
        end
    end

    if key_count == INITIAL_KEY_COUNT then
        return false
    end

    if has_array_elements and key_count > ARRAY_ELEMENT_THRESHOLD then
        return false
    end

    return has_metadata_keys or (not has_array_elements and key_count <= MAX_METADATA_KEYS)
end

local function build_message_from_args(args, end_idx)
    if end_idx == INITIAL_KEY_COUNT then
        return ""
    end

    if end_idx == STRING_FIRST_CHAR then
        return serialize_value(args[STRING_FIRST_CHAR])
    end

    local parts = {}
    for i = STRING_FIRST_CHAR, end_idx do
        table.insert(parts, serialize_value(args[i]))
    end

    return table.concat(parts, " ")
end

local function parse_intercepted_args(...)
    local arg_count = select('#', ...)

    if arg_count == INITIAL_KEY_COUNT then
        return "", nil
    end

    if arg_count == STRING_FIRST_CHAR then
        local arg = select(STRING_FIRST_CHAR, ...)
        return serialize_value(arg), nil
    end

    local args = { ... }
    local last_arg = args[arg_count]
    local metadata = nil
    local end_idx = arg_count

    if is_metadata_table(last_arg) then
        metadata = last_arg
        end_idx = arg_count - STRING_FIRST_CHAR
    end

    local message = build_message_from_args(args, end_idx)
    return message, metadata
end

local function intercepted_d(...)
    if original_d then
        original_d(...)
    end

    local message, metadata = parse_intercepted_args(...)

    local extracted_timestamp, message_after_timestamp = extract_timestamp(message)
    if extracted_timestamp then
        if not metadata then
            metadata = {}
        end
        metadata.extracted_timestamp = extracted_timestamp
        message = message_after_timestamp
    end

    local level = detect_log_level(message)
    local category, cleaned_message = extract_category(message)

    local ConsoleReader = BetterConsole.ConsoleReader
    if ConsoleReader and ConsoleReader.register_intercepted_entry then
        ConsoleReader.register_intercepted_entry(level, category, cleaned_message)
    elseif ConsoleReader and ConsoleReader.register_intercepted_line then
        ConsoleReader.register_intercepted_line(message)
    end

    if console_instance then
        console_instance.state_manager:mark_categories_dirty()
        console_instance:add_entry(level, category, cleaned_message, metadata)
    end
end

local function intercepted_error(message, level)
    local log_message = "Unknown error"
    if message ~= nil then
        log_message = tostring(message)
    end

    if console_instance then
        ErrorHandler.try_catch(function()
            console_instance.state_manager:mark_categories_dirty()
            console_instance:add_entry("ERROR", "System", log_message)
        end, "intercepted_error")
    end

    if original_error then
        original_error(message, level)
    end
end

local function intercepted_stacktrace()
    if console_instance then
        ErrorHandler.try_catch(function()
            console_instance.state_manager:mark_categories_dirty()
            console_instance:add_entry("DEBUG", "System", "[stacktrace() called - output sent to Minion console]")
        end, "intercepted_stacktrace")
    end

    if original_stacktrace then
        original_stacktrace()
    end
end

local function intercepted_ml_debug(str)
    if original_ml_debug then
        original_ml_debug(str)
    end

    if console_instance and str ~= nil then
        ErrorHandler.try_catch(function()
            local message = tostring(str)

            local category, cleaned_message = extract_category(message)

            local ConsoleReader = BetterConsole.ConsoleReader
            if ConsoleReader and ConsoleReader.register_intercepted_entry then
                ConsoleReader.register_intercepted_entry("DEBUG", category, cleaned_message)
            elseif ConsoleReader and ConsoleReader.register_intercepted_line then
                ConsoleReader.register_intercepted_line(message)
            end

            console_instance.state_manager:mark_categories_dirty()
            console_instance:add_entry("DEBUG", category, cleaned_message)
        end, "intercepted_ml_debug")
    end
end

local function intercepted_ml_error(str)
    if console_instance and str ~= nil then
        ErrorHandler.try_catch(function()
            local message = tostring(str)

            local category, cleaned_message = extract_category(message)

            local ConsoleReader = BetterConsole.ConsoleReader
            if ConsoleReader and ConsoleReader.register_intercepted_entry then
                ConsoleReader.register_intercepted_entry("ERROR", category, cleaned_message)
            elseif ConsoleReader and ConsoleReader.register_intercepted_line then
                ConsoleReader.register_intercepted_line(message)
            end

            console_instance.state_manager:mark_categories_dirty()
            console_instance:add_entry("ERROR", category, cleaned_message)
        end, "intercepted_ml_error")
    end

    if original_ml_error then
        original_ml_error(str)
    end
end

local function intercepted_ml_log(str)
    if console_instance and str ~= nil then
        ErrorHandler.try_catch(function()
            local message = tostring(str)

            local category, cleaned_message = extract_category(message)

            local ConsoleReader = BetterConsole.ConsoleReader
            if ConsoleReader and ConsoleReader.register_intercepted_entry then
                ConsoleReader.register_intercepted_entry("INFO", category, cleaned_message)
            elseif ConsoleReader and ConsoleReader.register_intercepted_line then
                ConsoleReader.register_intercepted_line(message)
            end

            console_instance.state_manager:mark_categories_dirty()
            console_instance:add_entry("INFO", category, cleaned_message, { status_bar = true })
        end, "intercepted_ml_log")
    end

    if original_ml_log then
        original_ml_log(str)
    end
end

local function intercepted_table_print(arg)
    if original_table_print then
        original_table_print(arg)
    end

    if console_instance and type(arg) == "table" then
        ErrorHandler.try_catch(function()
            local message = serialize_value(arg)

            local ConsoleReader = BetterConsole.ConsoleReader
            if ConsoleReader and ConsoleReader.register_intercepted_entry then
                ConsoleReader.register_intercepted_entry("DEBUG", "Table", message)
            elseif ConsoleReader and ConsoleReader.register_intercepted_line then
                ConsoleReader.register_intercepted_line(message)
            end

            console_instance.state_manager:mark_categories_dirty()
            console_instance:add_entry("DEBUG", "Table", message)
        end, "intercepted_table_print")
    end
end

function M.initialize(console)
    console_instance = console

    if console_instance then
        console_instance.state_manager:mark_categories_dirty()
    end

    if original_d then
        _G.d = intercepted_d
        _G.print = _G.d
    end

    if original_error then
        _G.error = intercepted_error
    end

    if original_stacktrace then
        _G.stacktrace = intercepted_stacktrace
    end

    if original_ml_debug then
        _G.ml_debug = intercepted_ml_debug
    end

    if original_ml_error then
        _G.ml_error = intercepted_ml_error
    end

    if original_ml_log then
        _G.ml_log = intercepted_ml_log
    end

    if original_table_print then
        table.print = intercepted_table_print
    end

    if console_instance and console_instance.add_entry then
        console_instance:add_entry("INFO", "Console", "BetterConsole initialized - all intercepts enabled")
    end
end

-- Export parsing functions for ConsoleReader to reuse
M.extract_timestamp = extract_timestamp
M.extract_category = extract_category
M.detect_log_level = detect_log_level

BetterConsole.Intercept = M
    Integration.Intercept = M
end

return Integration
