-- Private environment module for BetterConsole
-- Handles path resolution and module directory structure for Windows
-- Provides Windows path utilities and module-relative file resolution
-- Note: FFXIV Minion is Windows-only, so paths are hardcoded for Windows

local BetterConsole = rawget(_G, "BetterConsole")
if type(BetterConsole) ~= "table" then
    BetterConsole = {}
end

local Private = type(BetterConsole.Private) == "table" and BetterConsole.Private or {}
BetterConsole.Private = Private

Private.module_name = "BetterConsole"

local path_separator = "\\"
local alt_separator = "/"

-- Normalizes path by converting forward slashes to backslashes and removing duplicates
-- @param path string: Path to normalize
-- @return string|nil: Normalized Windows path or nil if invalid
local function normalize_path(path)
    if type(path) ~= "string" then
        return nil
    end

    path = path:gsub(alt_separator, path_separator)
    path = path:gsub(path_separator .. "+", path_separator)
    return path
end

-- Ensures path ends with path separator for directory paths
-- @param path string: Path to process
-- @return string: Path with trailing separator
local function ensure_trailing_separator(path)
    if type(path) ~= "string" or path == "" then
        return path
    end

    if path:sub(-1) ~= path_separator then
        path = path .. path_separator
    end

    return path
end

-- Removes leading path separators from path
-- @param path string: Path to process
-- @return string: Path without leading separators
local function strip_leading_separator(path)
    if type(path) ~= "string" then
        return path
    end

    while path:sub(1, 1) == path_separator do
        path = path:sub(2)
    end

    return path
end

-- Resolve and normalize startup path from FFXIV Minion
local startup_path = normalize_path(type(GetStartupPath) == "function" and GetStartupPath() or "")
startup_path = ensure_trailing_separator(startup_path)

-- Resolve and normalize LuaMods path from FFXIV Minion
local lua_mods_path = normalize_path(type(GetLuaModsPath) == "function" and GetLuaModsPath() or "")
lua_mods_path = ensure_trailing_separator(lua_mods_path)

-- Export Windows path information
Private.separator = path_separator
Private.alt_separator = alt_separator
Private.startup_path = startup_path
Private.lua_mods_path = lua_mods_path

-- Determine module root directory based on available paths
local module_root = ""
if startup_path ~= "" then
    module_root = startup_path .. "LuaMods" .. path_separator .. Private.module_name .. path_separator
elseif lua_mods_path ~= "" then
    module_root = lua_mods_path .. Private.module_name .. path_separator
end

Private.module_root = module_root

-- Composes absolute path from base directory and relative path
-- @param base string: Base directory path
-- @param relative string: Relative path to append
-- @return string|nil: Composed path or nil if invalid
local function compose_path(base, relative)
    if type(base) ~= "string" or base == "" then
        return nil
    end

    base = ensure_trailing_separator(base)
    relative = normalize_path(relative)

    if not relative or relative == "" then
        return base
    end

    relative = strip_leading_separator(relative)
    return base .. relative
end

-- Resolves relative path from module root or LuaMods path
-- @param relative string: Relative path within module
-- @return string|nil: Absolute resolved path or nil
local function resolve_relative(relative)
    if relative == nil or relative == "" then
        return module_root ~= "" and module_root or nil
    end

    local normalized = normalize_path(relative)
    if not normalized or normalized == "" then
        return module_root ~= "" and module_root or nil
    end

    if module_root ~= "" then
        return compose_path(module_root, normalized)
    end

    if lua_mods_path ~= "" then
        local module_base = compose_path(lua_mods_path, Private.module_name)
        return compose_path(module_base, normalized)
    end

    return nil
end

-- Resolves folder path relative to module root with trailing separator
-- @param folder_name string: Folder name or relative path
-- @return string|nil: Absolute folder path with trailing separator or nil
function Private.resolve_folder(folder_name)
    local path = resolve_relative(folder_name)
    if not path then
        return nil
    end

    return ensure_trailing_separator(path)
end

-- Resolves file path relative to module root
-- @param file_name string: File name or relative path
-- @return string|nil: Absolute file path or nil
function Private.resolve_file(file_name)
    local path = resolve_relative(file_name)
    if not path then
        return nil
    end

    return normalize_path(path)
end

-- Ensures folder exists by creating it if necessary
-- @param folder_name string: Folder name or relative path
-- @return string|nil: Absolute folder path if exists/created or nil on failure
function Private.ensure_folder(folder_name)
    local path = Private.resolve_folder(folder_name)
    if not path then
        return nil
    end

    if FolderExists(path) then
        return path
    end

    if FolderCreate(path) then
        return path
    end

    return nil
end

-- Predefined paths for module directories and files
-- root: Module root directory
-- logs: Logs directory path
-- prefs: User preferences file path
Private.paths = {
    root = module_root,
    logs = Private.resolve_folder("logs"),
    prefs = Private.resolve_file("userPrefs.lua")
}

-- Export to global namespace
_G.BetterConsole = BetterConsole

return BetterConsole
