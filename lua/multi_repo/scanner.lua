local Config = require("multi_repo.config")
local Git = require("multi_repo.git")

local Scanner = {}

---@alias MultiRepoRepositorySource
---| "directory"
---| "submodule"
---| "symlink"

---@class MultiRepoRepository
---@field name string
---@field path string
---@field real_path string
---@field git_root string
---@field display_path string
---@field source MultiRepoRepositorySource
---@field status MultiRepoGitStatus|nil

---@class MultiRepoScannerContext
---@field config MultiRepoScannerConfig
---@field root_path string
---@field include_paths string[]
---@field repositories MultiRepoRepository[]
---@field seen_git_roots table<string, boolean>
---@field visited_real_paths table<string, boolean>

-- Path helpers

---@param parent_path string
---@param child_path string
---@return string path
local function join_path(parent_path, child_path)
    return parent_path .. "/" .. child_path
end

---@param path string|nil
---@return string normalized_path
local function normalize_path(path)
    return Git.normalize_path(path)
end

---@param path string
---@return string resolved_path
local function resolve_path(path)
    return normalize_path(vim.fn.resolve(path))
end

---@param path string
---@return boolean is_absolute
local function is_absolute_path(path)
    return path:sub(1, 1) == "/"
end

---@param left_path string
---@param right_path string
---@return boolean is_same
local function is_same_path(left_path, right_path)
    return normalize_path(left_path) == normalize_path(right_path)
end

---@param path string
---@param parent_path string
---@return boolean is_inside
local function is_path_inside(path, parent_path)
    local normalized_path = normalize_path(path)
    local normalized_parent_path = normalize_path(parent_path)

    return normalized_path:sub(1, #normalized_parent_path + 1) == normalized_parent_path .. "/"
end

---@param path string
---@param parent_path string
---@return boolean is_same_or_inside
local function is_same_or_inside_path(path, parent_path)
    return is_same_path(path, parent_path) or is_path_inside(path, parent_path)
end

---@param path string
---@param root_path string
---@return string relative_path
local function get_relative_path(path, root_path)
    local normalized_path = normalize_path(path)
    local normalized_root_path = normalize_path(root_path)

    if normalized_path == normalized_root_path then
        return "."
    end

    if is_path_inside(normalized_path, normalized_root_path) then
        local relative_path = normalized_path:gsub(
            "^" .. vim.pesc(normalized_root_path) .. "/",
            ""
        )

        return relative_path
    end

    return normalized_path
end

---@param path string
---@param root_path string
---@return integer depth
local function get_path_depth(path, root_path)
    local relative_path = get_relative_path(path, root_path)

    if relative_path == "." then
        return 0
    end

    if is_absolute_path(relative_path) then
        return 0
    end

    local depth = 0

    for _ in relative_path:gmatch("[^/]+") do
        depth = depth + 1
    end

    return depth
end

-- Filesystem helpers

---@param path string
---@return string[] entries
local function safe_read_dir(path)
    local success, entries = pcall(vim.fn.readdir, path)

    if not success or type(entries) ~= "table" then
        return {}
    end

    return entries
end

---@param path string
---@return boolean is_directory
local function is_directory(path)
    return vim.fn.isdirectory(path) == 1
end

---@param path string
---@return boolean is_file
local function is_file(path)
    return vim.fn.filereadable(path) == 1
end

---@param path string
---@return boolean is_symlink
local function is_symlink(path)
    return vim.fn.getftype(path) == "link"
end

-- Git repository detection

---@param path string
---@return boolean is_git_directory
local function is_git_directory(path)
    return is_directory(join_path(path, ".git"))
end

---@param path string
---@return boolean is_git_file
local function is_git_file(path)
    return is_file(join_path(path, ".git"))
end

---@param path string
---@return boolean is_git_repository
local function is_git_repository(path)
    return is_git_directory(path) or is_git_file(path)
end

-- Include / ignore rules

---@param root_path string
---@param config MultiRepoScannerConfig
---@return string[] include_paths
local function create_include_paths(root_path, config)
    local include_paths = {}

    for _, include_dir in ipairs(config.include_dirs or {}) do
        local include_path

        if is_absolute_path(include_dir) then
            include_path = normalize_path(include_dir)
        else
            include_path = normalize_path(join_path(root_path, include_dir))
        end

        table.insert(include_paths, include_path)
    end

    return include_paths
end

---@param path string
---@param include_paths string[]
---@return boolean is_included
local function is_included_path(path, include_paths)
    for _, include_path in ipairs(include_paths) do
        if is_same_or_inside_path(path, include_path) then
            return true
        end
    end

    return false
end

---@param path string
---@param include_paths string[]
---@return boolean contains_included
local function contains_included_path(path, include_paths)
    for _, include_path in ipairs(include_paths) do
        if is_same_or_inside_path(include_path, path) then
            return true
        end
    end

    return false
end

---@param entry_name string
---@param entry_path string
---@param root_path string
---@param config MultiRepoScannerConfig
---@return boolean is_ignored
local function is_ignored_path(entry_name, entry_path, root_path, config)
    local relative_path = get_relative_path(entry_path, root_path)

    for _, ignored_dir in ipairs(config.ignored_dirs or {}) do
        if entry_name == ignored_dir or relative_path == ignored_dir then
            return true
        end
    end

    return false
end

---@param path string
---@param root_path string
---@param config MultiRepoScannerConfig
---@param include_paths string[]
---@return boolean should_skip
local function should_skip_for_depth(path, root_path, config, include_paths)
    if is_included_path(path, include_paths) then
        return false
    end

    return get_path_depth(path, root_path) > config.max_depth
end

---@param path string
---@param config MultiRepoScannerConfig
---@param include_paths string[]
---@return boolean should_skip
local function should_skip_symlink(path, config, include_paths)
    if not is_symlink(path) then
        return false
    end

    if is_included_path(path, include_paths) then
        return false
    end

    return config.follow_symlinks == false
end

---@param entry_name string
---@param entry_path string
---@param root_path string
---@param config MultiRepoScannerConfig
---@param include_paths string[]
---@return boolean should_skip
local function should_skip_ignored_path(entry_name, entry_path, root_path, config, include_paths)
    if not is_ignored_path(entry_name, entry_path, root_path, config) then
        return false
    end

    if is_included_path(entry_path, include_paths) then
        return false
    end

    if contains_included_path(entry_path, include_paths) then
        return false
    end

    return true
end

-- Repository creation

---@param path string
---@return MultiRepoRepositorySource source
local function get_repository_source(path)
    if is_symlink(path) then
        return "symlink"
    end

    if is_git_file(path) then
        return "submodule"
    end

    return "directory"
end

---@param path string
---@param root_path string
---@return string display_path
local function get_display_path(path, root_path)
    local relative_path = get_relative_path(path, root_path)

    if relative_path ~= "." then
        return relative_path
    end

    return vim.fn.fnamemodify(root_path, ":t")
end

---@param path string
---@param root_path string
---@return MultiRepoRepository repository
local function create_repository(path, root_path)
    local normalized_path = normalize_path(path)
    local real_path = resolve_path(normalized_path)
    local display_path = get_display_path(normalized_path, root_path)

    return {
        name = vim.fn.fnamemodify(display_path, ":t"),
        path = normalized_path,
        real_path = real_path,
        git_root = normalized_path,
        display_path = display_path,
        source = get_repository_source(normalized_path),
        status = nil,
    }
end

---@param repositories MultiRepoRepository[]
---@param seen_git_roots table<string, boolean>
---@param path string
---@param root_path string
---@return nil
local function add_repository(repositories, seen_git_roots, path, root_path)
    local repository = create_repository(path, root_path)

    if seen_git_roots[repository.git_root] then
        return
    end

    seen_git_roots[repository.git_root] = true

    table.insert(repositories, repository)
end

-- Directory scanning

---@param path string
---@param visited_real_paths table<string, boolean>
---@return boolean should_visit
local function should_visit_directory(path, visited_real_paths)
    local real_path = resolve_path(path)

    if visited_real_paths[real_path] then
        return false
    end

    visited_real_paths[real_path] = true

    return true
end

---@param context MultiRepoScannerContext
---@param path string
---@return nil
local function scan_directory(context, path)
    local normalized_path = normalize_path(path)

    if should_skip_for_depth(
            normalized_path,
            context.root_path,
            context.config,
            context.include_paths
        ) then
        return
    end

    if should_skip_symlink(
            normalized_path,
            context.config,
            context.include_paths
        ) then
        return
    end

    if not should_visit_directory(normalized_path, context.visited_real_paths) then
        return
    end

    if is_git_repository(normalized_path) then
        add_repository(
            context.repositories,
            context.seen_git_roots,
            normalized_path,
            context.root_path
        )
    end

    for _, entry_name in ipairs(safe_read_dir(normalized_path)) do
        local entry_path = join_path(normalized_path, entry_name)

        if is_directory(entry_path)
            and not should_skip_ignored_path(
                entry_name,
                entry_path,
                context.root_path,
                context.config,
                context.include_paths
            )
        then
            scan_directory(context, entry_path)
        end
    end
end

---@param context MultiRepoScannerContext
---@return nil
local function scan_include_paths(context)
    for _, include_path in ipairs(context.include_paths) do
        if is_directory(include_path) then
            scan_directory(context, include_path)
        end
    end
end

---@param repositories MultiRepoRepository[]
---@return nil
local function sort_repositories(repositories)
    table.sort(repositories, function(left_repository, right_repository)
        return left_repository.display_path < right_repository.display_path
    end)
end

-- Public API

--- Scans a root path and returns discovered Git repositories.
---
--- The scanner supports nested repositories, Git submodules, symlinked
--- repositories, explicit include paths, ignored directories and max depth.
--- It only discovers repositories; Git status is intentionally loaded later.
---
---@param root_path string|nil Root path to scan. Defaults to the current working directory.
---@return MultiRepoRepository[] repositories Discovered repositories.
function Scanner.scan(root_path)
    local config = Config.get().scanner
    local normalized_root_path = normalize_path(root_path or vim.fn.getcwd())

    ---@type MultiRepoScannerContext
    local context = {
        config = config,
        root_path = normalized_root_path,
        include_paths = create_include_paths(normalized_root_path, config),

        repositories = {},
        seen_git_roots = {},
        visited_real_paths = {},
    }

    scan_directory(context, normalized_root_path)
    scan_include_paths(context)
    sort_repositories(context.repositories)

    return context.repositories
end

return Scanner
