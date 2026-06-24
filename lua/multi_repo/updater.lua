local Config = require("multi_repo.config")
local Git = require("multi_repo.git")
local Scanner = require("multi_repo.scanner")

local Updater = {}

local DEFAULT_CONCURRENCY = 2

---@alias MultiRepoUpdaterAction
---| "fetch"
---| "pull"

---@alias MultiRepoUpdaterResultStatus
---| "updated"
---| "up_to_date"
---| "fetched"
---| "skipped"
---| "failed"

---@class MultiRepoUpdaterOptions
---@field action MultiRepoUpdaterAction
---@field args string[]
---@field title string
---@field on_complete fun(summary: MultiRepoUpdaterSummary): nil

---@class MultiRepoUpdaterResult
---@field repository MultiRepoRepository
---@field status MultiRepoUpdaterResultStatus
---@field output string[]

---@class MultiRepoUpdaterSummary
---@field total integer
---@field updated integer
---@field up_to_date integer
---@field fetched integer
---@field skipped integer
---@field failed integer
---@field results MultiRepoUpdaterResult[]

-- Config

---@return table config
local function get_updater_config()
    local config = Config.get()

    return config.updater or {}
end

---@return integer concurrency
local function get_concurrency()
    local updater_config = get_updater_config()

    return updater_config.concurrency or DEFAULT_CONCURRENCY
end

---@return string[] args
local function get_fetch_args()
    local updater_config = get_updater_config()

    return updater_config.fetch_args or {
        "fetch",
        "--all",
        "--prune",
    }
end

---@return string[] args
local function get_pull_args()
    local updater_config = get_updater_config()

    return updater_config.pull_args or {
        "pull",
        "--ff-only",
    }
end

-- Scan

---@return string scan_root
local function get_scan_root()
    local cwd = vim.fn.getcwd()

    return Git.get_root(cwd) or cwd
end

---@return MultiRepoRepository[] repositories
local function get_repositories()
    return Scanner.scan(get_scan_root())
end

-- Output

---@param data string[]|nil
---@return string[] lines
local function normalize_job_output(data)
    local lines = {}

    for _, line in ipairs(data or {}) do
        if line ~= "" then
            table.insert(lines, line)
        end
    end

    return lines
end

---@param target string[]
---@param source string[]|nil
---@return nil
local function append_output(target, source)
    for _, line in ipairs(normalize_job_output(source)) do
        table.insert(target, line)
    end
end

---@param output string[]
---@param pattern string
---@return boolean has_match
local function output_has_match(output, pattern)
    for _, line in ipairs(output) do
        if line:match(pattern) then
            return true
        end
    end

    return false
end

-- Result classification

---@param exit_code integer
---@return MultiRepoUpdaterResultStatus status
local function classify_fetch_result(exit_code)
    if exit_code == 0 then
        return "fetched"
    end

    return "failed"
end

---@param exit_code integer
---@param output string[]
---@return MultiRepoUpdaterResultStatus status
local function classify_pull_result(exit_code, output)
    if exit_code == 0 then
        if output_has_match(output, "Already up to date") then
            return "up_to_date"
        end

        return "updated"
    end

    if output_has_match(output, "Not possible to fast%-forward")
        or output_has_match(output, "divergent branches")
        or output_has_match(output, "Need to specify how to reconcile")
    then
        return "skipped"
    end

    return "failed"
end

---@param action MultiRepoUpdaterAction
---@param exit_code integer
---@param output string[]
---@return MultiRepoUpdaterResultStatus status
local function classify_result(action, exit_code, output)
    if action == "fetch" then
        return classify_fetch_result(exit_code)
    end

    return classify_pull_result(exit_code, output)
end

-- Summary

---@param total integer
---@return MultiRepoUpdaterSummary summary
local function create_summary(total)
    return {
        total = total,
        updated = 0,
        up_to_date = 0,
        fetched = 0,
        skipped = 0,
        failed = 0,
        results = {},
    }
end

---@param summary MultiRepoUpdaterSummary
---@param result MultiRepoUpdaterResult
---@return nil
local function add_result_to_summary(summary, result)
    table.insert(summary.results, result)

    if result.status == "updated" then
        summary.updated = summary.updated + 1
    elseif result.status == "up_to_date" then
        summary.up_to_date = summary.up_to_date + 1
    elseif result.status == "fetched" then
        summary.fetched = summary.fetched + 1
    elseif result.status == "skipped" then
        summary.skipped = summary.skipped + 1
    elseif result.status == "failed" then
        summary.failed = summary.failed + 1
    end
end

---@param action MultiRepoUpdaterAction
---@param summary MultiRepoUpdaterSummary
---@return string message
local function create_summary_message(action, summary)
    if action == "fetch" then
        return table.concat({
            "MultiRepo fetch finished:",
            summary.fetched .. " fetched,",
            summary.failed .. " failed",
        }, " ")
    end

    return table.concat({
        "MultiRepo pull finished:",
        summary.updated .. " updated,",
        summary.up_to_date .. " up to date,",
        summary.skipped .. " skipped,",
        summary.failed .. " failed",
    }, " ")
end

-- Jobs

---@param repository MultiRepoRepository
---@param options MultiRepoUpdaterOptions
---@param on_complete fun(result: MultiRepoUpdaterResult): nil
---@return nil
local function run_repository_job(repository, options, on_complete)
    local output = {}

    local command = {
        "git",
        "-C",
        repository.git_root,
    }

    for _, argument in ipairs(options.args) do
        table.insert(command, argument)
    end

    local job_id = vim.fn.jobstart(command, {
        stdout_buffered = true,
        stderr_buffered = true,

        on_stdout = function(_, data)
            append_output(output, data)
        end,

        on_stderr = function(_, data)
            append_output(output, data)
        end,

        on_exit = function(_, exit_code)
            local status = classify_result(options.action, exit_code, output)

            vim.schedule(function()
                on_complete({
                    repository = repository,
                    status = status,
                    output = output,
                })
            end)
        end,
    })

    if job_id <= 0 then
        on_complete({
            repository = repository,
            status = "failed",
            output = {
                "Failed to start git job",
            },
        })
    end
end

---@param repositories MultiRepoRepository[]
---@param options MultiRepoUpdaterOptions
---@return nil
local function run_repository_queue(repositories, options)
    local summary = create_summary(#repositories)
    local concurrency = get_concurrency()
    local next_index = 1
    local running_jobs = 0

    local function finish_if_done()
        if next_index <= #repositories or running_jobs > 0 then
            return
        end

        vim.notify(create_summary_message(options.action, summary), vim.log.levels.INFO)
        options.on_complete(summary)
    end

    local function run_next_jobs()
        while running_jobs < concurrency and next_index <= #repositories do
            local repository = repositories[next_index]

            next_index = next_index + 1
            running_jobs = running_jobs + 1

            run_repository_job(repository, options, function(result)
                running_jobs = running_jobs - 1

                add_result_to_summary(summary, result)
                run_next_jobs()
                finish_if_done()
            end)
        end

        finish_if_done()
    end

    run_next_jobs()
end

-- Public API

---@param options MultiRepoUpdaterOptions
---@return nil
function Updater.run(options)
    local repositories = get_repositories()

    if #repositories == 0 then
        vim.notify("No repositories found", vim.log.levels.WARN)
        return
    end

    vim.notify(
        options.title .. " started for " .. #repositories .. " repositories",
        vim.log.levels.INFO
    )

    run_repository_queue(repositories, options)
end

---@return nil
function Updater.fetch()
    Updater.run({
        action = "fetch",
        args = get_fetch_args(),
        title = "MultiRepo fetch",
        on_complete = function() end,
    })
end

---@return nil
function Updater.pull()
    Updater.run({
        action = "pull",
        args = get_pull_args(),
        title = "MultiRepo pull",
        on_complete = function() end,
    })
end

return Updater
