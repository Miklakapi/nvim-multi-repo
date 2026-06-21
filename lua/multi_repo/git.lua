local Git = {}

local function normalize_path(path)
    return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

local function run_git_command(path, arguments, options)
    local normalized_path = normalize_path(path or vim.fn.getcwd())
    local command = {
        "git",
        "-C",
        normalized_path,
    }

    for _, argument in ipairs(arguments) do
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

local function parse_branch_name(branch_part)
    if branch_part == "" then
        return nil
    end

    if branch_part:match("^HEAD") then
        return "detached"
    end

    local branch_name = branch_part:match("^([^%.%s%[]+)")

    if not branch_name or branch_name == "" then
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

local function parse_file_status(line)
    local index_status = line:sub(1, 1)
    local worktree_status = line:sub(2, 2)
    local combined_status = line:sub(1, 2)

    local is_untracked = combined_status == "??"
    local is_conflicted = index_status == "U"
        or worktree_status == "U"
        or combined_status == "AA"
        or combined_status == "DD"

    return {
        index_status = index_status,
        worktree_status = worktree_status,
        combined_status = combined_status,

        is_staged = not is_untracked and index_status ~= " " and index_status ~= "?",
        is_changed = not is_untracked and worktree_status ~= " " and worktree_status ~= "?",
        is_untracked = is_untracked,
        is_conflicted = is_conflicted,

        is_added = index_status == "A" or worktree_status == "A",
        is_modified = index_status == "M" or worktree_status == "M",
        is_deleted = index_status == "D" or worktree_status == "D",
        is_renamed = index_status == "R" or worktree_status == "R",
        is_copied = index_status == "C" or worktree_status == "C",
    }
end

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

local function update_status_counts(status, file_status)
    if file_status.is_staged then
        status.staged_count = status.staged_count + 1
    end

    if file_status.is_changed then
        status.changed_count = status.changed_count + 1
    end

    if file_status.is_untracked then
        status.untracked_count = status.untracked_count + 1
    end

    if file_status.is_conflicted then
        status.conflict_count = status.conflict_count + 1
    end

    if file_status.is_added then
        status.added_count = status.added_count + 1
    end

    if file_status.is_modified then
        status.modified_count = status.modified_count + 1
    end

    if file_status.is_deleted then
        status.deleted_count = status.deleted_count + 1
    end

    if file_status.is_renamed then
        status.renamed_count = status.renamed_count + 1
    end

    if file_status.is_copied then
        status.copied_count = status.copied_count + 1
    end
end

local function finalize_status(status)
    status.is_dirty = status.changed_count > 0
        or status.staged_count > 0
        or status.untracked_count > 0
        or status.conflict_count > 0

    return status
end

local function get_status_lines(path)
    return run_git_command(path, {
        "status",
        "--short",
        "--branch",
    }, {
        allow_error = true,
    })
end

local function get_log_lines(path)
    return run_git_command(path, {
        "log",
        "--oneline",
        "--decorate",
        "-n",
        "8",
    }, {
        allow_error = true,
    })
end

function Git.normalize_path(path)
    return normalize_path(path)
end

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

function Git.is_repository(path)
    return Git.get_root(path) ~= nil
end

function Git.get_status(path)
    local result = get_status_lines(path)
    local status = create_empty_status()

    if not result then
        return status
    end

    for _, line in ipairs(result) do
        if line:match("^##") then
            local branch_status = parse_branch_status(line)

            status.branch = branch_status.branch
            status.ahead = branch_status.ahead
            status.behind = branch_status.behind
        else
            local file_status = parse_file_status(line)

            update_status_counts(status, file_status)
        end
    end

    return finalize_status(status)
end

function Git.get_preview(path)
    local status_result = get_status_lines(path) or {}
    local log_result = get_log_lines(path) or {}
    local lines = {}

    table.insert(lines, "Status")
    table.insert(lines, "------")

    if #status_result == 0 then
        table.insert(lines, "No status available")
    else
        for _, line in ipairs(status_result) do
            table.insert(lines, line)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Recent commits")
    table.insert(lines, "--------------")

    if #log_result == 0 then
        table.insert(lines, "No commits available")
    else
        for _, line in ipairs(log_result) do
            table.insert(lines, line)
        end
    end

    return lines
end

return Git
