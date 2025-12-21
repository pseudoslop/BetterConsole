local Infrastructure = {}

local Models = BetterConsole and BetterConsole.Models
local Constants = Models and Models.Constants
local TimeConstants = Constants and Constants.Time
local CategoryConstants = Constants and Constants.Categories

do
local M = {}

local INITIAL_HEAD = 1
local INITIAL_TAIL = 0
local INITIAL_COUNT = 0

-- Creates new ring buffer instance with fixed capacity
-- @param capacity number: Maximum number of items buffer can hold
-- @return table: RingBuffer instance
function M.new(capacity)
    local instance = {
        capacity = capacity,
        buffer = {},
        head = INITIAL_HEAD,
        tail = INITIAL_TAIL,
        count = INITIAL_COUNT,
        total_added = INITIAL_COUNT
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Adds item to buffer, overwriting oldest item when at capacity
-- @param item any: Item to add to buffer
function M:push(item)
    self.tail = self.tail % self.capacity + 1
    self.buffer[self.tail] = item
    self.total_added = self.total_added + 1

    if self.count < self.capacity then
        self.count = self.count + 1
    else
        self.head = self.head % self.capacity + 1
    end
end

-- Clears all items from buffer and resets state
function M:clear()
    for i = 1, self.capacity do
        self.buffer[i] = nil
    end
    self.head = INITIAL_HEAD
    self.tail = INITIAL_TAIL
    self.count = INITIAL_COUNT
    self.total_added = INITIAL_COUNT
end

BetterConsole.RingBuffer = M
    Infrastructure.RingBuffer = M
end

-- LRU module providing Least Recently Used cache with doubly-linked list
do
local M = {}

local DEFAULT_MAX_SIZE = 100
local INITIAL_SIZE = 0

-- Creates new LRU cache instance
-- @param max_size number: Maximum number of items cache can hold (default 100)
-- @return table: LRU cache instance
function M.new(max_size)
    local instance = {
        max_size = max_size or DEFAULT_MAX_SIZE,
        size = INITIAL_SIZE,
        cache = {},
        head = nil,
        tail = nil
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Creates doubly-linked list node for cache entry
-- @param key any: Cache key
-- @param value any: Cache value
-- @return table: Node with key, value, prev, and next pointers
function M:create_node(key, value)
    return {
        key = key,
        value = value,
        prev = nil,
        next = nil
    }
end

-- Adds node to head of list marking it as most recently used
-- @param node table: Node to add to head
function M:add_to_head(node)
    node.prev = nil
    node.next = self.head

    if self.head then
        self.head.prev = node
    end

    self.head = node

    if not self.tail then
        self.tail = node
    end
end

-- Removes node from list without deleting it
-- @param node table: Node to remove from list
function M:remove_node(node)
    if node.prev then
        node.prev.next = node.next
    else
        self.head = node.next
    end

    if node.next then
        node.next.prev = node.prev
    else
        self.tail = node.prev
    end
end

-- Moves existing node to head marking it as most recently used
-- @param node table: Node to move to head
function M:move_to_head(node)
    self:remove_node(node)
    self:add_to_head(node)
end

-- Removes and returns least recently used node from tail
-- @return table|nil: Removed node or nil if cache empty
function M:remove_tail()
    local last_node = self.tail
    if last_node then
        self:remove_node(last_node)
        return last_node
    end
    return nil
end

-- Retrieves value from cache and marks it as most recently used
-- @param key any: Key to retrieve
-- @return any|nil: Cached value or nil if not found
function M:get(key)
    local node = self.cache[key]
    if not node then
        return nil
    end

    self:move_to_head(node)
    return node.value
end

-- Adds or updates cache entry, evicting least recently used if at capacity
-- @param key any: Key to store
-- @param value any: Value to store
function M:put(key, value)
    local node = self.cache[key]

    if node then
        node.value = value
        self:move_to_head(node)
        return
    end

    local new_node = self:create_node(key, value)

    if self.size >= self.max_size then
        local tail = self:remove_tail()
        if tail then
            self.cache[tail.key] = nil
            self.size = self.size - 1
        end
    end

    self.cache[key] = new_node
    self:add_to_head(new_node)
    self.size = self.size + 1
end

BetterConsole.LRU = M
    Infrastructure.LRU = M
end

do
local M = {}

local INITIAL_TASK_ID = 1
local INITIAL_TASK_COUNT = 0
local DEFAULT_CHUNK_SIZE = 1000
local DEFAULT_MAX_TIME_MS = 5
local DEFAULT_BATCH_SIZE = 100
local MS_PER_SECOND = (TimeConstants and TimeConstants.MS_PER_SECOND) or 1000
local INITIAL_INDEX = 1
local INITIAL_TIME = 0
local INITIAL_PROCESSED = 0

-- Creates new scheduler instance for managing coroutine-based tasks
-- @return table: Scheduler instance
function M.new()
    local instance = {
        tasks = {},
        next_task_id = INITIAL_TASK_ID,
        task_count = INITIAL_TASK_COUNT
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Adds coroutine task to scheduler
-- @param task thread: Coroutine to schedule
-- @return number: Task ID for tracking
function M:add_task(task)
    local task_id = self.next_task_id
    self.next_task_id = self.next_task_id + 1

    self.tasks[task_id] = {
        coroutine = task,
        id = task_id,
        status = "pending"
    }

    self.task_count = self.task_count + 1

    return task_id
end

-- Removes task from scheduler
-- @param task_id number: ID of task to remove
function M:remove_task(task_id)
    if self.tasks[task_id] then
        self.tasks[task_id] = nil
        self.task_count = self.task_count - 1
    end
end

-- Marks task as complete and removes it from scheduler
-- @param self table: Scheduler instance
-- @param task_id number: Task ID
-- @param task table: Task data
-- @param status_info table: Completion status information
-- @return table: Status info
local function complete_task(self, task_id, task, status_info)
    task.status = status_info.status
    self.tasks[task_id] = nil
    self.task_count = self.task_count - 1
    return status_info
end

-- Handles completed coroutine task that has finished execution
-- @param self table: Scheduler instance
-- @param task_id number: Task ID
-- @param task table: Task data
-- @return table: Completion status
local function handle_dead_task(self, task_id, task)
    return complete_task(self, task_id, task, {
        id = task_id,
        status = "completed"
    })
end

-- Resumes suspended coroutine task and handles completion or errors
-- @param self table: Scheduler instance
-- @param task_id number: Task ID
-- @param task table: Task data
-- @return table|nil: Completion status or nil if still running
local function handle_suspended_task(self, task_id, task)
    local success, result, is_complete = coroutine.resume(task.coroutine)

    if not success then
        return complete_task(self, task_id, task, {
            id = task_id,
            status = "error",
            error = result
        })
    end

    if is_complete then
        return complete_task(self, task_id, task, {
            id = task_id,
            status = "completed",
            result = result
        })
    end

    task.status = "running"
    return nil
end

-- Updates all scheduled tasks by resuming suspended coroutines
-- @return table: Array of completed task status information
function M:update()
    local completed_tasks = {}

    for task_id, task in pairs(self.tasks) do
        if task.coroutine then
            local status = coroutine.status(task.coroutine)
            local completion_info = nil

            if status == "dead" then
                completion_info = handle_dead_task(self, task_id, task)
            elseif status == "suspended" then
                completion_info = handle_suspended_task(self, task_id, task)
            end

            if completion_info then
                table.insert(completed_tasks, completion_info)
            end
        end
    end

    return completed_tasks
end

-- Gets number of currently scheduled tasks
-- @return number: Task count
function M:get_task_count()
    return self.task_count
end

-- Checks if task is currently scheduled
-- @param task_id number: Task ID to check
-- @return boolean: True if task is running
function M:is_task_running(task_id)
    return self.tasks[task_id] ~= nil
end

-- Clears all scheduled tasks
function M:clear_all()
    self.tasks = {}
    self.task_count = INITIAL_TASK_COUNT
end

-- Creates state object for chunked processing of data
-- @param data table: Data array or iterable object
-- @param chunk_size number: Items to process per chunk (default 1000)
-- @return table: Chunk state object
function M.create_chunk_state(data, chunk_size)
    return {
        data = data,
        chunk_size = chunk_size or DEFAULT_CHUNK_SIZE,
        current_index = INITIAL_INDEX,
        iterator = nil,
        total_items = nil,
        is_processing = false,
        results = {},
        start_time = INITIAL_TIME,
        total_processed = INITIAL_PROCESSED
    }
end

-- Initializes chunk state and begins processing
-- @param state table: Chunk state object
function M.start_chunking(state)
    state.is_processing = true
    state.current_index = INITIAL_INDEX
    state.iterator = nil
    state.total_items = nil
    state.results = {}
    state.start_time = os.clock() * MS_PER_SECOND
    state.total_processed = INITIAL_PROCESSED
end

-- Stops chunking and resets chunk state
-- @param state table: Chunk state object
function M.stop_chunking(state)
    state.is_processing = false
    state.current_index = INITIAL_INDEX
    state.iterator = nil
    state.total_items = nil
    state.results = {}
end

-- Checks if chunk processing should pause based on size or time limits
-- @param processed_count number: Items processed this frame
-- @param chunk_size number: Target chunk size
-- @param elapsed_time number: Time elapsed in milliseconds
-- @param max_time_ms number: Maximum time allowed per frame
-- @return boolean: True if should pause processing
local function should_continue_processing(processed_count, chunk_size, elapsed_time, max_time_ms)
    return processed_count >= chunk_size or elapsed_time > max_time_ms
end

-- Processes chunk of array data with time limiting
-- @param state table: Chunk state
-- @param process_fn function: Filter function returning boolean
-- @param start_time number: Processing start time in milliseconds
-- @param max_time_ms number: Maximum time per frame
-- @return boolean: True if more processing needed
local function process_array_chunk(state, process_fn, start_time, max_time_ms)
    local processed_this_frame = INITIAL_PROCESSED

    while state.current_index <= #state.data do
        local item = state.data[state.current_index]
        local should_include = process_fn(item, state.current_index)

        if should_include then
            table.insert(state.results, item)
        end

        processed_this_frame = processed_this_frame + 1
        state.total_processed = state.total_processed + 1
        state.current_index = state.current_index + 1

        local elapsed_time = os.clock() * MS_PER_SECOND - start_time
        if should_continue_processing(processed_this_frame, state.chunk_size, elapsed_time, max_time_ms) then
            return state.current_index <= #state.data
        end
    end

    return false
end

-- Ensures iterator is initialized for iterable data sources
-- @param state table: Chunk state
-- @return function|nil: Iterator function or nil if unavailable
local function ensure_iterator_initialized(state)
    if state.iterator then
        return state.iterator
    end

    if not (state.data and state.data.iterate) then
        return nil
    end

    state.iterator = state.data:iterate()

    if type(state.data.get_entry_count) == "function" then
        state.total_items = state.data:get_entry_count()
    else
        state.total_items = nil
    end

    if state.current_index < INITIAL_INDEX then
        state.current_index = INITIAL_INDEX
    end

    return state.iterator
end

-- Cleans up iterator after processing completes
-- @param state table: Chunk state
local function finalize_iterator(state)
    state.iterator = nil
    if state.total_items then
        state.current_index = state.total_items + INITIAL_INDEX
    end
end

-- Processes chunk using iterator with time limiting
-- @param state table: Chunk state
-- @param process_fn function: Filter function returning boolean
-- @param start_time number: Processing start time in milliseconds
-- @param max_time_ms number: Maximum time per frame
-- @return boolean: True if more processing needed
local function process_iterator_chunk(state, process_fn, start_time, max_time_ms)
    local iterator = ensure_iterator_initialized(state)
    if not iterator then
        return false
    end

    local processed_this_frame = INITIAL_PROCESSED

    while iterator do
        local raw_key, raw_value = iterator()

        if raw_key == nil and raw_value == nil then
            finalize_iterator(state)
            return false
        end

        local entry = raw_value
        local entry_index = state.current_index

        if raw_value == nil then
            entry = raw_key
        elseif raw_key ~= nil then
            entry_index = raw_key
            if entry_index < state.current_index then
                entry_index = state.current_index
            end
        end

        local should_include = process_fn(entry, entry_index)
        if should_include then
            table.insert(state.results, entry)
        end

        processed_this_frame = processed_this_frame + 1
        state.total_processed = state.total_processed + 1
        state.current_index = entry_index + 1

        local elapsed_time = os.clock() * MS_PER_SECOND - start_time
        if should_continue_processing(processed_this_frame, state.chunk_size, elapsed_time, max_time_ms) then
            return true
        end
    end

    finalize_iterator(state)
    return false
end

-- Processes next chunk of data with time limiting
-- @param state table: Chunk state
-- @param process_fn function: Filter function returning boolean
-- @param max_time_ms number: Maximum time per frame (default 5ms)
-- @return boolean: True if more chunks need processing
function M.process_chunk(state, process_fn, max_time_ms)
    if not state.is_processing then
        return false
    end

    max_time_ms = max_time_ms or DEFAULT_MAX_TIME_MS
    local start_time = os.clock() * MS_PER_SECOND

    if type(state.data) == "table" and #state.data > INITIAL_PROCESSED then
        return process_array_chunk(state, process_fn, start_time, max_time_ms)
    end

    if type(state.data) == "table" and type(state.data.iterate) == "function" then
        return process_iterator_chunk(state, process_fn, start_time, max_time_ms)
    end

    return false
end

-- Retrieves results accumulated from chunk processing
-- @param state table: Chunk state
-- @return table: Array of filtered results
function M.get_chunk_results(state)
    return state.results
end

-- Creates coroutine that processes items in batches
-- @param items table: Array of items to process
-- @param process_fn function: Processing function for each item
-- @param batch_size number: Items per batch (default 100)
-- @return thread: Coroutine that yields between batches
function M.create_batch_processor(items, process_fn, batch_size)
    batch_size = batch_size or DEFAULT_BATCH_SIZE

    return coroutine.create(function()
        local results = {}
        local count = INITIAL_PROCESSED

        for i, item in ipairs(items) do
            local result = process_fn(item, i)
            if result ~= nil then
                table.insert(results, result)
            end

            count = count + 1
            if count % batch_size == 0 then
                coroutine.yield(results, false)
            end
        end

        coroutine.yield(results, true)
    end)
end

-- Safely resumes coroutine with error handling
-- @param coro thread: Coroutine to resume
-- @return boolean, any, boolean: Success, result, is_complete
function M.safe_resume(coro)
    if not coro or coroutine.status(coro) == "dead" then
        return false, nil, true
    end

    local success, result, is_complete = coroutine.resume(coro)

    if not success then
        return false, result, true
    end

    return true, result, is_complete
end

BetterConsole.Scheduler = M
    Infrastructure.Scheduler = M
end

-- Metrics module providing performance tracking and statistics collection
do
local M = {}

local INITIAL_TIME = 0
local INITIAL_FRAME_COUNT = 0
local BYTES_PER_KB = 1024
local DEFAULT_MAX_ENTRIES = 50000
local DEFAULT_MIN_LEVEL = "TRACE"
local MS_PER_SECOND = (TimeConstants and TimeConstants.MS_PER_SECOND) or 1000

-- Creates new metrics tracker instance
-- @return table: Metrics instance
function M.new()
    local instance = {
        update_time = INITIAL_TIME,
        render_time = INITIAL_TIME,
        filter_time = INITIAL_TIME,
        last_update_start = INITIAL_TIME,
        last_render_start = INITIAL_TIME,
        frame_count = INITIAL_FRAME_COUNT
    }

    setmetatable(instance, { __index = M })
    return instance
end

-- Records start time for update phase timing
function M:start_update()
    self.last_update_start = os.clock() * MS_PER_SECOND
end

-- Records end time and calculates update phase duration
function M:end_update()
    if self.last_update_start <= INITIAL_TIME then
        return
    end

    self.update_time = (os.clock() * MS_PER_SECOND) - self.last_update_start
    self.last_update_start = INITIAL_TIME
end

-- Records start time for render phase timing
function M:start_render()
    self.last_render_start = os.clock() * MS_PER_SECOND
end

-- Records end time and calculates render phase duration
function M:end_render()
    if self.last_render_start <= INITIAL_TIME then
        return
    end

    self.render_time = (os.clock() * MS_PER_SECOND) - self.last_render_start
    self.last_render_start = INITIAL_TIME
    self.frame_count = self.frame_count + 1
end

-- Sets filter processing time in milliseconds
-- @param time number: Filter processing time
function M:set_filter_time(time)
    self.filter_time = time
end

-- Retrieves current performance metrics
-- @return table: Metrics with update_time_ms, render_time_ms, filter_time_ms, frame_count
function M:get_metrics()
    return {
        update_time_ms = self.update_time,
        render_time_ms = self.render_time,
        filter_time_ms = self.filter_time,
        frame_count = self.frame_count
    }
end

-- Resets all metrics to initial values
function M:reset()
    self.update_time = INITIAL_TIME
    self.render_time = INITIAL_TIME
    self.filter_time = INITIAL_TIME
    self.frame_count = INITIAL_FRAME_COUNT
end

-- Resolves memory count from parameter or collectgarbage
-- @param memory_kb number: Optional memory in KB
-- @return number: Memory usage in KB
local function resolve_memory_count(memory_kb)
    if memory_kb ~= nil then
        return memory_kb
    end
    return collectgarbage("count")
end

-- Collects console statistics including entry counts and memory usage
-- @param data_store table: Data store with get_entry_count method
-- @param display_entries table: Array of displayed entries
-- @param max_entries number: Maximum capacity (default 50000)
-- @param memory_bytes number: Optional memory usage in bytes
-- @return table: Console statistics
function M.get_console_stats(data_store, display_entries, max_entries, memory_bytes)
    local stats = {
        total_entries = INITIAL_TIME,
        displayed_entries = INITIAL_TIME,
        memory_usage = memory_bytes or (collectgarbage("count") * BYTES_PER_KB),
        capacity = max_entries or DEFAULT_MAX_ENTRIES,
        is_enabled = true,
        min_level = DEFAULT_MIN_LEVEL
    }

    if data_store and data_store.get_entry_count then
        stats.total_entries = data_store:get_entry_count()
    end

    if display_entries then
        stats.displayed_entries = #display_entries
    end

    return stats
end

-- Collects anti-spam statistics
-- @param anti_spam table: Anti-spam manager with get_stats method
-- @return table: Anti-spam statistics with total_blocked, active_patterns, enabled
function M.get_anti_spam_stats(anti_spam)
    if not (anti_spam and anti_spam.get_stats) then
        return {
            total_blocked = INITIAL_TIME,
            active_patterns = INITIAL_TIME,
            enabled = false
        }
    end

    return anti_spam:get_stats()
end

-- Formats status text with console and anti-spam statistics
-- @param stats table: Console statistics
-- @param anti_spam_stats table: Anti-spam statistics
-- @param update_time_ms number: Update time in milliseconds
-- @return string: Formatted status text
function M.format_status_text(stats, anti_spam_stats, update_time_ms)
    local parts = {
        string.format("Entries: %d", stats.total_entries or INITIAL_TIME),
        string.format("Filtered: %d", stats.displayed_entries or INITIAL_TIME),
        string.format("Memory: %.1fKB", (stats.memory_usage or INITIAL_TIME) / BYTES_PER_KB),
        string.format("Update: %.1fms", update_time_ms or INITIAL_TIME)
    }

    if anti_spam_stats and anti_spam_stats.total_blocked and anti_spam_stats.total_blocked > INITIAL_TIME then
        table.insert(parts, string.format("Blocked: %d", anti_spam_stats.total_blocked))
    end

    return table.concat(parts, " | ")
end

-- Gets memory usage in bytes
-- @param memory_kb number: Optional memory in KB
-- @return number: Memory usage in bytes
function M.get_memory_usage_bytes(memory_kb)
    local count = resolve_memory_count(memory_kb)
    return count * BYTES_PER_KB
end

-- Gets memory usage in kilobytes
-- @param memory_kb number: Optional memory in KB
-- @return number: Memory usage in KB
function M.get_memory_usage_kb(memory_kb)
    return resolve_memory_count(memory_kb)
end

-- Gets memory usage in megabytes
-- @param memory_kb number: Optional memory in KB
-- @return number: Memory usage in MB
function M.get_memory_usage_mb(memory_kb)
    local count = resolve_memory_count(memory_kb)
    return count / BYTES_PER_KB
end

-- Formats memory size with appropriate unit (B, KB, MB, GB)
-- @param bytes number: Memory size in bytes
-- @return string: Formatted memory string
function M.format_memory(bytes)
    if not bytes or bytes < INITIAL_TIME then
        return "0 B"
    end

    local KB = BYTES_PER_KB
    local MB = KB * BYTES_PER_KB
    local GB = MB * BYTES_PER_KB

    if bytes < KB then
        return string.format("%d B", bytes)
    elseif bytes < MB then
        return string.format("%.1f KB", bytes / KB)
    elseif bytes < GB then
        return string.format("%.1f MB", bytes / MB)
    else
        return string.format("%.2f GB", bytes / GB)
    end
end

-- Creates comprehensive metrics snapshot
-- @param data_store table: Data store with entry count
-- @param display_entries table: Displayed entries array
-- @param anti_spam table: Optional anti-spam manager
-- @return table: Snapshot with console, memory, and optional anti-spam metrics
function M.create_snapshot(data_store, display_entries, anti_spam)
    local memory_kb = resolve_memory_count()
    local memory_bytes = memory_kb * BYTES_PER_KB

    local snapshot = {
        console = M.get_console_stats(data_store, display_entries, nil, memory_bytes),
        memory = {
            bytes = memory_bytes,
            kilobytes = memory_kb,
            megabytes = memory_kb / BYTES_PER_KB,
            formatted = M.format_memory(memory_bytes)
        },
        timestamp = os.time()
    }

    if anti_spam then
        snapshot.anti_spam = M.get_anti_spam_stats(anti_spam)
    end

    return snapshot
end

BetterConsole.Metrics = M
    Infrastructure.Metrics = M
end

-- Strx module providing comprehensive string processing and formatting utilities
do
local M = {}

local known_categories = {}
local CATEGORY_CACHE_MAX_SIZE = 1000
local DEFAULT_CATEGORY = (CategoryConstants and CategoryConstants.MINION) or "Minion"
local DEFAULT_MAX_LENGTH = 2000
local MAX_METADATA_DEPTH = 5
local MAX_MULTILINE_PREVIEW_LINES = 10
local MAX_STRING_PREVIEW_CHARS = 100
local MAX_ARRAY_ITEMS_INLINE = 5
local MAX_ARRAY_ITEMS_DISPLAY = 15
local MAX_OBJECT_FIELDS_DISPLAY = 20
local MAX_OBJECT_FIELDS_INLINE = 3

-- Serializes table to string representation with circular reference detection
-- @param value table: Table to serialize
-- @param visited table: Visited tables tracker
-- @param depth number: Current recursion depth
-- @return string: Serialized table string
local function serialize_table(value, visited, depth)
    local Constants = BetterConsole.Models.Constants
    
    if visited[value] then
        return "[CIRCULAR REFERENCE]"
    end
    
    visited[value] = true
    
    local parts = { "{" }
    local count = 0
    
    for k, v in pairs(value) do
        if count > 0 then
            parts[#parts + 1] = ", "
        end
        
        if type(k) == "string" then
            parts[#parts + 1] = k .. "=" .. M.serialize_value(v, visited, depth + 1)
        else
            parts[#parts + 1] = "[" .. M.serialize_value(k, visited, depth + 1) .. "]="
                .. M.serialize_value(v, visited, depth + 1)
        end
        
        count = count + 1
        if count > Constants.Caching.METADATA_SERIALIZE_MAX_ITEMS then
            parts[#parts + 1] = ", ..."
            break
        end
    end
    
    parts[#parts + 1] = "}"
    visited[value] = nil
    
    return table.concat(parts)
end

-- Serializes any Lua value to string representation
-- @param value any: Value to serialize
-- @param visited table: Optional visited tables tracker
-- @param depth number: Optional current depth (default 0)
-- @return string: Serialized value string
function M.serialize_value(value, visited, depth)
    local Constants = BetterConsole.Models.Constants
    visited = visited or {}
    depth = depth or 0

    if depth > Constants.Caching.METADATA_SERIALIZE_MAX_DEPTH then
        return "[MAX DEPTH EXCEEDED]"
    end

    if value == nil then
        return "nil"
    elseif type(value) == "string" then
        return value
    elseif type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    elseif type(value) == "table" then
        return serialize_table(value, visited, depth)
    else
        return tostring(value)
    end
end

-- Truncates text to maximum character count
-- @param text string: Text to truncate
-- @param max_chars number: Maximum characters
-- @return string: Truncated text
function M.truncate_by_chars(text, max_chars)
    local utils = BetterConsole.TextUtils
    if utils and utils.truncate_by_chars then
        return utils.truncate_by_chars(text, max_chars)
    end
    return text
end

-- Truncates text to maximum line count
-- @param text string: Text to truncate
-- @param max_lines number: Maximum lines
-- @param chars_per_line number: Characters per line
-- @return string: Truncated text
function M.truncate_by_lines(text, max_lines, chars_per_line)
    local utils = BetterConsole.TextUtils
    if utils and utils.truncate_by_lines then
        return utils.truncate_by_lines(text, max_lines, chars_per_line)
    end
    return text
end

-- Truncates text by both character and line limits
-- @param text string: Text to truncate
-- @param max_chars number: Maximum characters
-- @param max_lines number: Maximum lines
-- @param chars_per_line number: Characters per line
-- @return string: Truncated text
function M.truncate(text, max_chars, max_lines, chars_per_line)
    local utils = BetterConsole.TextUtils
    if utils and utils.truncate then
        return utils.truncate(text, max_chars, max_lines, chars_per_line)
    end
    return text
end

-- Sanitizes text by redacting sensitive information and truncating
-- @param text string: Text to sanitize
-- @param max_length number: Maximum length (default 2000)
-- @return string: Sanitized text with redacted credentials and paths
function M.sanitize(text, max_length)
    if not text then
        return ""
    end

    local sanitized = text

    sanitized = string.gsub(
        sanitized,
        "([kK]ey%s*=%s*)[%w%+/=-]+",
        "%1[REDACTED]"
    )
    sanitized = string.gsub(
        sanitized,
        "([tT]oken%s*=%s*)[%w%+/=-]+",
        "%1[REDACTED]"
    )
    sanitized = string.gsub(
        sanitized,
        "([pP]assword%s*=%s*)[%w%+/=-]+",
        "%1[REDACTED]"
    )
    sanitized = string.gsub(
        sanitized,
        "([sS]ecret%s*=%s*)[%w%+/=-]+",
        "%1[REDACTED]"
    )

    sanitized = string.gsub(
        sanitized,
        "(C:\\\\Users\\[^\\]+\\)",
        "C:\\Users\\[USER]\\"
    )

    max_length = max_length or DEFAULT_MAX_LENGTH
    if #sanitized > max_length then
        sanitized = string.sub(sanitized, 1, max_length) .. "... [TRUNCATED]"
    end

    return sanitized
end

-- Checks if text is a log level indicator
-- @param text string: Text to check
-- @return boolean: True if text matches known log levels
function M.is_log_level_indicator(text)
    if not text then
        return false
    end

    local upper = string.upper(text)

    return upper == "ERROR" or upper == "ERR" or upper == "FATAL"
        or upper == "CRITICAL"
        or upper == "WARNING" or upper == "WARN" or upper == "WRN"
        or upper == "DEBUG" or upper == "DBG"
        or upper == "INFO"
end

-- Normalizes category name with caching
-- @param category string: Category name to normalize
-- @return string: Normalized category name
function M.normalize_category(category)
    if not category then
        return DEFAULT_CATEGORY
    end

    if known_categories[category] then
        return known_categories[category]
    end

    local normalized = string.gsub(category, "^%s*(.-)%s*$", "%1")

    if normalized ~= string.upper(normalized) then
        normalized =
            string.upper(string.sub(normalized, 1, 1))
            .. string.lower(string.sub(normalized, 2))
    end

    local cache_size = M.get_category_cache_size()
    if cache_size >= CATEGORY_CACHE_MAX_SIZE then
        known_categories = {}
    end

    known_categories[category] = normalized
    return normalized
end

-- Attempts to extract category from message using pattern
-- @param message string: Message to extract from
-- @param pattern string: Lua pattern to match
-- @param validator function: Optional validation function
-- @return string|nil, string|nil: Category and remaining message or nil
local function try_extract_pattern(message, pattern, validator)
    local category, remaining = string.match(message, pattern)
    if not category then
        return nil, nil
    end

    if validator and not validator(category) then
        return nil, nil
    end

    return category, remaining or ""
end

-- Extracts category from message using multiple format patterns
-- @param message string: Message to extract category from
-- @return string, string: Category and remaining message
function M.extract_category(message)
    if not message or message == "" then
        return DEFAULT_CATEGORY, message
    end

    local category, remaining = try_extract_pattern(message, "^%[([^%]]+)%]%s*(.*)$")
    if category then
        return M.normalize_category(category), remaining
    end

    category, remaining = try_extract_pattern(
        message,
        "^([%w_%-]+):%s*(.*)$",
        function(cat) return not M.is_log_level_indicator(cat) end
    )
    if category then
        return M.normalize_category(category), remaining
    end

    category, remaining = try_extract_pattern(message, "^([%w_%-]+)%s*%-%s*(.*)$")
    if category then
        return M.normalize_category(category), remaining
    end

    category, remaining = try_extract_pattern(message, "^<([^>]+)>%s*(.*)$")
    if category then
        return M.normalize_category(category), remaining
    end

    return DEFAULT_CATEGORY, message
end

-- Trims whitespace from start and end of text
-- @param text string: Text to trim
-- @return string: Trimmed text
function M.trim(text)
    if not text then
        return ""
    end
    return string.gsub(text, "^%s*(.-)%s*$", "%1")
end

-- Strips category prefix from text
-- @param text string: Text to process
-- @return string: Text without category prefix
function M.strip_category_prefix(text)
    if not text then
        return ""
    end
    return text:gsub("%__STRING_0__*%]: ", "")
end

-- Clears category normalization cache
function M.clear_category_cache()
    known_categories = {}
end

-- Gets number of cached category normalizations
-- @return number: Cache size
function M.get_category_cache_size()
    local count = 0
    for _ in pairs(known_categories) do
        count = count + 1
    end
    return count
end

-- Checks if number is an integer
-- @param n any: Value to check
-- @return boolean: True if integer
local function is_int(n)
    return type(n) == "number" and n % 1 == 0
end

-- Classifies table as array and returns max index
-- @param t table: Table to classify
-- @return boolean, number: Is array and max index
local function classify_array(t)
    local count, min_k, max_k = 0, math.huge, -math.huge
    for k, _ in pairs(t) do
        if not is_int(k) then
            return false, 0
        end
        count = count + 1
        if k < min_k then min_k = k end
        if k > max_k then max_k = k end
    end

    if count == 0 or min_k ~= 1 or max_k ~= count then
        return false, 0
    end

    return true, max_k
end

-- Formats multiline string with preview truncation
-- @param value string: Multiline string to format
-- @param indent string: Indentation prefix
-- @return string: Formatted multiline string
local function format_multiline_string(value, indent)
    local lines = {}
    for line in value:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end

    if #lines <= MAX_MULTILINE_PREVIEW_LINES then
        return "\n" .. indent .. "  " .. table.concat(lines, "\n" .. indent .. "  ")
    end

    local result = {}
    for i = 1, MAX_MULTILINE_PREVIEW_LINES do
        result[#result + 1] = lines[i]
    end
    result[#result + 1] = "... [" .. (#lines - MAX_MULTILINE_PREVIEW_LINES) .. " more lines]"
    return "\n" .. indent .. "  " .. table.concat(result, "\n" .. indent .. "  ")
end

-- Formats string value with truncation for long strings
-- @param value string: String to format
-- @param indent string: Indentation prefix
-- @return string: Formatted string
local function format_string_value(value, indent)
    if value:find("\n") then
        return format_multiline_string(value, indent)
    end

    if #value <= MAX_STRING_PREVIEW_CHARS then
        return value
    end

    return value:sub(1, MAX_STRING_PREVIEW_CHARS) .. "... [" .. (#value - MAX_STRING_PREVIEW_CHARS) .. " more chars]"
end

-- Formats array with inline or multiline layout
-- @param value table: Array to format
-- @param n number: Array length
-- @param indent string: Indentation prefix
-- @param visited table: Visited tables tracker
-- @param depth number: Current depth
-- @return string: Formatted array
local function format_array_value(value, n, indent, visited, depth)
    local items = {}
    for i = 1, n do
        if i > MAX_ARRAY_ITEMS_DISPLAY then
            items[#items + 1] = "... [" .. (n - MAX_ARRAY_ITEMS_DISPLAY) .. " more]"
            break
        end
        items[#items + 1] = M.format_metadata_value(value[i], indent .. "  ", visited, depth + 1)
    end

    visited[value] = nil

    if #items <= MAX_ARRAY_ITEMS_INLINE then
        return "[" .. table.concat(items, ", ") .. "]"
    end

    return "\n" .. indent .. "[\n"
        .. indent .. "  "
        .. table.concat(items, ",\n" .. indent .. "  ")
        .. "\n" .. indent .. "]"
end

-- Formats object with sorted keys and inline or multiline layout
-- @param value table: Object to format
-- @param indent string: Indentation prefix
-- @param visited table: Visited tables tracker
-- @param depth number: Current depth
-- @return string: Formatted object
local function format_object_value(value, indent, visited, depth)
    local keys = {}
    for k, _ in pairs(value) do
        keys[#keys + 1] = k
    end

    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "number" then return a < b end
            return tostring(a) < tostring(b)
        end
        return ta == "number"
    end)

    local items = {}
    local count = 0
    for _, k in ipairs(keys) do
        count = count + 1
        if count > MAX_OBJECT_FIELDS_DISPLAY then
            items[#items + 1] = "... [" .. (count - MAX_OBJECT_FIELDS_DISPLAY) .. " more fields]"
            break
        end
        local key = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
        local formatted = M.format_metadata_value(value[k], indent .. "  ", visited, depth + 1)
        items[#items + 1] = key .. ": " .. formatted
    end

    visited[value] = nil

    if #items == 0 then
        return "{}"
    end

    if #items <= MAX_OBJECT_FIELDS_INLINE and depth > 0 then
        return "{ " .. table.concat(items, ", ") .. " }"
    end

    return "\n" .. indent .. "{\n"
        .. indent .. "  "
        .. table.concat(items, ",\n" .. indent .. "  ")
        .. "\n" .. indent .. "}"
end

-- Formats metadata value with intelligent layout and type handling
-- @param value any: Value to format
-- @param indent string: Optional indentation prefix
-- @param visited table: Optional visited tables tracker
-- @param depth number: Optional current depth
-- @return string: Formatted value string
function M.format_metadata_value(value, indent, visited, depth)
    indent = indent or ""
    visited = visited or {}
    depth = depth or 0

    if depth > MAX_METADATA_DEPTH then
        return "[MAX DEPTH]"
    end

    if value == nil then
        return "nil"
    end

    if type(value) == "string" then
        return format_string_value(value, indent)
    end

    if type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    end

    if type(value) == "table" then
        if visited[value] then
            return "[CIRCULAR]"
        end
        visited[value] = true

        local is_array, n = classify_array(value)
        if is_array then
            return format_array_value(value, n, indent, visited, depth)
        end

        return format_object_value(value, indent, visited, depth)
    end

    return tostring(value)
end

BetterConsole.Strx = M
    Infrastructure.Strx = M
end

return Infrastructure
