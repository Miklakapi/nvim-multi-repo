local Git = {}

local DEFAULT_COMMIT_LIMIT = 8

---@class MultiRepoGitCommandOptions
---@field allow_error boolean|nil

---@class MultiRepoGitPreviewOptions
---@field commit_limit integer|nil

---@class MultiRepoGitPreviewData
---@field status_lines string[]
---@field log_lines string[]

---@class MultiRepoBranchStatus
---@field branch string|nil
---@field ahead integer
---@field behind integer

---@class MultiRepoFileStatus
---@field index_status string
---@field worktree_status string
---@field combined_status string
---@field is_staged boolean
---@field is_changed boolean
---@field is_untracked boolean
---@field is_conflicted boolean
---@field is_added boolean
---@field is_modified boolean
---@field is_deleted boolean
---@field is_renamed boolean
---@field is_copied boolean

---@class MultiRepoGitStatus
---@field branch string|nil
---@field is_dirty boolean
---@field changed_count integer
---@field staged_count integer
---@field untracked_count integer
---@field conflict_count integer
---@field added_count integer
---@field modified_count integer
---@field deleted_count integer
---@field renamed_count integer
---@field copied_count integer
---@field ahead integer
---@field behind integer

---@alias MultiRepoGitStatusCountKey
---| "changed_count"
---| "staged_count"
---| "untracked_count"
---| "conflict_count"
---| "added_count"
---| "modified_count"
---| "deleted_count"
---| "renamed_count"
---| "copied_count"

-- Path helpers

---@param path string|nil
---@return string normalized_path
local function normalize_path(path)
    local fallback_path = path or vim.fn.getcwd()
    local absolute_path = vim.fn.fnamemodify(fallback_path, ":p")
    local normalized_path = absolute_path:gsub("/$", "")

    return normalized_path
end

-- Command execution

---@param path string|nil
---@param arguments string[]|nil
---@param options MultiRepoGitCommandOptions|nil
---@return string[]|nil result
local function run_git_command(path, arguments, options)
    local command = {
        "git",
        "-C",
        normalize_path(path),
    }

    for _, argument in ipairs(arguments or {}) do
        table.insert(command, argument)
    end

    local result = vim.fn.systemlist(command)

    if vim.v.shell_error == 0 then
        return result
    end

    if options and options.allow_error then
        return nil
    end

    vim.notify(
        "Git command failed: " .. table.concat(command, " "),
        vim.log.levels.ERROR
    )

    return nil
end

-- Branch status parsing

---@param branch_part string
---@return string branch_name
local function strip_branch_tracking_info(branch_part)
    local branch_name = branch_part
        :gsub("%s*%[.*%]$", "")
        :gsub("%.%.%..*$", "")
        :gsub("%s+$", "")

    return branch_name
end

---@param branch_part string|nil
---@return string|nil branch_name
local function parse_branch_name(branch_part)
    if not branch_part or branch_part == "" then
        return nil
    end

    if branch_part:match("^HEAD") then
        return "detached"
    end

    local branch_name = strip_branch_tracking_info(branch_part)

    if branch_name == "" then
        return nil
    end

    return branch_name
end

---@param line string
---@return MultiRepoBranchStatus branch_status
local function parse_branch_status(line)
    local branch_part = line:gsub("^##%s*", "")
    local ahead = branch_part:match("ahead%s+(%d+)")
    local behind = branch_part:match("behind%s+(%d+)")

    return {
        branch = parse_branch_name(branch_part),
        ahead = tonumber(ahead) or 0,
        behind = tonumber(behind) or 0,
    }
end

-- File status parsing

---@param index_status string
---@param worktree_status string
---@param combined_status string
---@return boolean is_conflicted
local function is_conflict_status(index_status, worktree_status, combined_status)
    return index_status == "U"
        or worktree_status == "U"
        or combined_status == "AA"
        or combined_status == "DD"
end

---@param line string
---@return MultiRepoFileStatus file_status
local function parse_file_status(line)
    local index_status = line:sub(1, 1)
    local worktree_status = line:sub(2, 2)
    local combined_status = line:sub(1, 2)
    local is_untracked = combined_status == "??"

    return {
        index_status = index_status,
        worktree_status = worktree_status,
        combined_status = combined_status,

        is_staged = not is_untracked and index_status ~= " " and index_status ~= "?",
        is_changed = not is_untracked and worktree_status ~= " " and worktree_status ~= "?",
        is_untracked = is_untracked,
        is_conflicted = is_conflict_status(index_status, worktree_status, combined_status),

        is_added = index_status == "A" or worktree_status == "A",
        is_modified = index_status == "M" or worktree_status == "M",
        is_deleted = index_status == "D" or worktree_status == "D",
        is_renamed = index_status == "R" or worktree_status == "R",
        is_copied = index_status == "C" or worktree_status == "C",
    }
end

-- Status aggregation

---@return MultiRepoGitStatus status
local function create_empty_status()
    return {
        branch = nil,
        is_dirty = false,

        changed_count = 0,
        staged_count = 0,
        untracked_count = 0,
        conflict_count = 0,

        added_count = 0,
        modified_count = 0,
        deleted_count = 0,
        renamed_count = 0,
        copied_count = 0,

        ahead = 0,
        behind = 0,
    }
end

---@param status MultiRepoGitStatus
---@param key MultiRepoGitStatusCountKey
---@param should_increment boolean
---@return nil
local function increment_status_count(status, key, should_increment)
    if should_increment then
        status[key] = status[key] + 1
    end
end

---@param status MultiRepoGitStatus
---@param file_status MultiRepoFileStatus
---@return nil
local function update_status_counts(status, file_status)
    increment_status_count(status, "staged_count", file_status.is_staged)
    increment_status_count(status, "changed_count", file_status.is_changed)
    increment_status_count(status, "untracked_count", file_status.is_untracked)
    increment_status_count(status, "conflict_count", file_status.is_conflicted)

    increment_status_count(status, "added_count", file_status.is_added)
    increment_status_count(status, "modified_count", file_status.is_modified)
    increment_status_count(status, "deleted_count", file_status.is_deleted)
    increment_status_count(status, "renamed_count", file_status.is_renamed)
    increment_status_count(status, "copied_count", file_status.is_copied)
end

---@param status MultiRepoGitStatus
---@return MultiRepoGitStatus status
local function finalize_status(status)
    status.is_dirty = status.changed_count > 0
        or status.staged_count > 0
        or status.untracked_count > 0
        or status.conflict_count > 0

    return status
end

-- Git command wrappers

---@param path string|nil
---@return string[]|nil lines
local function get_status_lines(path)
    return run_git_command(path, {
        "status",
        "--short",
        "--branch",
    }, {
        allow_error = true,
    })
end

---@param path string|nil
---@param limit integer|nil
---@return string[]|nil lines
local function get_log_lines(path, limit)
    return run_git_command(path, {
        "log",
        "--oneline",
        "--decorate",
        "-n",
        tostring(limit or DEFAULT_COMMIT_LIMIT),
    }, {
        allow_error = true,
    })
end

-- Public API

--- Normalizes a path to an absolute path without a trailing slash.
---
--- When `path` is nil, the current working directory is used.
---
---@param path string|nil Path to normalize.
---@return string normalized_path Absolute path without a trailing slash.
function Git.normalize_path(path)
    return normalize_path(path)
end

--- Returns the root directory of the Git repository containing `path`.
---
--- Returns nil when `path` is not inside a Git repository or when Git cannot
--- resolve the repository root.
---
---@param path string|nil Path inside a Git repository. Defaults to the current working directory.
---@return string|nil git_root Absolute normalized Git root path.
function Git.get_root(path)
    local result = run_git_command(path, {
        "rev-parse",
        "--show-toplevel",
    }, {
        allow_error = true,
    })

    if not result or not result[1] or result[1] == "" then
        return nil
    end

    return normalize_path(result[1])
end

--- Parses raw `git status --short --branch` lines.
---
---@param lines string[]|nil Raw status lines.
---@return MultiRepoGitStatus status Parsed repository status.
function Git.parse_status_lines(lines)
    local status = create_empty_status()

    for _, line in ipairs(lines or {}) do
        if line:match("^##") then
            local branch_status = parse_branch_status(line)

            status.branch = branch_status.branch
            status.ahead = branch_status.ahead
            status.behind = branch_status.behind
        elseif line ~= "" then
            update_status_counts(status, parse_file_status(line))
        end
    end

    return finalize_status(status)
end

--- Returns parsed repository status information.
---
--- The status is based on `git status --short --branch`.
---
---@param path string|nil Path inside a Git repository. Defaults to the current working directory.
---@return MultiRepoGitStatus status Parsed repository status.
function Git.get_status(path)
    return Git.parse_status_lines(get_status_lines(path))
end

--- Returns raw Git preview data for a repository.
---
--- The returned data contains raw `git status --short --branch` output and
--- recent commits from `git log --oneline --decorate`.
---
--- Options:
--- - `commit_limit`: maximum number of commits returned. Defaults to 8.
---
---@param path string|nil Path inside a Git repository. Defaults to the current working directory.
---@param options MultiRepoGitPreviewOptions|nil Preview options.
---@return MultiRepoGitPreviewData preview_data Raw preview data.
function Git.get_preview_data(path, options)
    options = options or {}

    return {
        status_lines = get_status_lines(path) or {},
        log_lines = get_log_lines(path, options.commit_limit) or {},
    }
end

return Git
