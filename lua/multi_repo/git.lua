local Git = {}

-- Path helpers

local function normalize_path(path)
    local fallback_path = path or vim.fn.getcwd()
    local absolute_path = vim.fn.fnamemodify(fallback_path, ":p")
    local normalized_path = absolute_path:gsub("/$", "")

    return normalized_path
end

-- Command execution

local function run_git_command(path, arguments, options)
    local normalized_path = normalize_path(path)
    local command = {
        "git",
        "-C",
        normalized_path,
    }

    for _, argument in ipairs(arguments or {}) do
        table.insert(command, argument)
    end

    local result = vim.fn.systemlist(command)

    if vim.v.shell_error ~= 0 then
        if options and options.allow_error then
            return nil
        end

        vim.notify(
            "Git command failed: " .. table.concat(command, " "),
            vim.log.levels.ERROR
        )

        return nil
    end

    return result
end

-- Branch status parsing

local function strip_branch_tracking_info(branch_part)
    return branch_part
        :gsub("%s*%[.*%]$", "")
        :gsub("%.%.%..*$", "")
        :gsub("%s+$", "")
end

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

local function is_conflict_status(index_status, worktree_status, combined_status)
    return index_status == "U"
        or worktree_status == "U"
        or combined_status == "AA"
        or combined_status == "DD"
end

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

local function increment_status_count(status, key, should_increment)
    if should_increment then
        status[key] = status[key] + 1
    end
end

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

local function finalize_status(status)
    status.is_dirty = status.changed_count > 0
        or status.staged_count > 0
        or status.untracked_count > 0
        or status.conflict_count > 0

    return status
end

-- Git command wrappers

local function get_status_lines(path)
    return run_git_command(path, {
        "status",
        "--short",
        "--branch",
    }, {
        allow_error = true,
    })
end

local function get_log_lines(path, limit)
    return run_git_command(path, {
        "log",
        "--oneline",
        "--decorate",
        "-n",
        tostring(limit or 8),
    }, {
        allow_error = true,
    })
end

-- Status application

local function apply_branch_status(status, line)
    local branch_status = parse_branch_status(line)

    status.branch = branch_status.branch
    status.ahead = branch_status.ahead
    status.behind = branch_status.behind
end

local function apply_file_status(status, line)
    local file_status = parse_file_status(line)

    update_status_counts(status, file_status)
end

-- Preview formatting

local function build_preview_lines(status_lines, log_lines)
    local lines = {}

    table.insert(lines, "Status")
    table.insert(lines, "------")

    if #status_lines == 0 then
        table.insert(lines, "No status available")
    else
        for _, line in ipairs(status_lines) do
            table.insert(lines, line)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Recent commits")
    table.insert(lines, "--------------")

    if #log_lines == 0 then
        table.insert(lines, "No commits available")
    else
        for _, line in ipairs(log_lines) do
            table.insert(lines, line)
        end
    end

    return lines
end

-- Public API

--- Normalizes a path to an absolute path without a trailing slash.
---
--- When `path` is nil, the current working directory is used.
---
--- @param path string|nil Path to normalize.
--- @return string normalized_path Absolute path without a trailing slash.
function Git.normalize_path(path)
    return normalize_path(path)
end

--- Returns the root directory of the Git repository containing `path`.
---
--- Returns nil when `path` is not inside a Git repository or when Git cannot
--- resolve the repository root.
---
--- @param path string|nil Path inside a Git repository. Defaults to the current working directory.
--- @return string|nil git_root Absolute normalized Git root path.
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

--- Returns whether `path` is inside a Git repository.
---
--- @param path string|nil Path to check. Defaults to the current working directory.
--- @return boolean is_repository True when Git can resolve a repository root.
function Git.is_repository(path)
    return Git.get_root(path) ~= nil
end

--- Returns parsed repository status information.
---
--- The status is based on `git status --short --branch`.
---
--- Returned table fields:
--- - `branch`: current branch name, `"detached"`, or nil
--- - `is_dirty`: whether the repository has staged, changed, untracked, or conflicted files
--- - `changed_count`: number of changed files in the working tree
--- - `staged_count`: number of staged files
--- - `untracked_count`: number of untracked files
--- - `conflict_count`: number of conflicted files
--- - `added_count`: number of added files
--- - `modified_count`: number of modified files
--- - `deleted_count`: number of deleted files
--- - `renamed_count`: number of renamed files
--- - `copied_count`: number of copied files
--- - `ahead`: number of commits ahead of upstream
--- - `behind`: number of commits behind upstream
---
--- @param path string|nil Path inside a Git repository. Defaults to the current working directory.
--- @return table status Parsed repository status.
function Git.get_status(path)
    local result = get_status_lines(path)
    local status = create_empty_status()

    if not result then
        return status
    end

    for _, line in ipairs(result) do
        if line:match("^##") then
            apply_branch_status(status, line)
        else
            apply_file_status(status, line)
        end
    end

    return finalize_status(status)
end

--- Builds preview lines for a Git repository.
---
--- The preview contains raw `git status --short --branch` output and recent
--- commits from `git log --oneline --decorate`.
---
--- Options:
--- - `commit_limit`: maximum number of commits shown in the preview. Defaults to 8.
---
--- @param path string|nil Path inside a Git repository. Defaults to the current working directory.
--- @param options table|nil Preview options.
--- @return string[] lines Preview lines.
function Git.get_preview(path, options)
    options = options or {}

    local status_lines = get_status_lines(path) or {}
    local log_lines = get_log_lines(path, options.commit_limit or 8) or {}

    return build_preview_lines(status_lines, log_lines)
end

return Git
