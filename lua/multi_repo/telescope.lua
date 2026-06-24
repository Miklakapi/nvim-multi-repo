local Config = require("multi_repo.config")
local Git = require("multi_repo.git")

local Telescope = {}

local STATUS_JOB_CONCURRENCY = 4
local REFRESH_DEBOUNCE_MS = 100

---@class MultiRepoTelescopeDisplayWidths
---@field path integer
---@field branch integer
---@field status integer
---@field sync integer

-- Config helpers

---@return MultiRepoTelescopeConfig
local function get_telescope_config()
    local config = Config.get()

    return config.telescope or {}
end

---@return table<string, MultiRepoStatusDefinition>
local function get_status_config()
    local telescope_config = get_telescope_config()

    return telescope_config.status or {}
end

---@return table<string, MultiRepoHighlightDefinition>
local function get_highlight_config()
    local telescope_config = get_telescope_config()

    return telescope_config.highlights or {}
end

---@param status_name string
---@return MultiRepoStatusDefinition status_definition
local function get_status_definition(status_name)
    local status_config = get_status_config()

    return status_config[status_name] or {
        label = status_name,
        highlight = "Normal",
    }
end

---@param highlight_config MultiRepoHighlightDefinition
---@return vim.api.keyset.highlight highlight_options
local function create_highlight_options(highlight_config)
    return {
        link = highlight_config.link,
        fg = highlight_config.fg,
        bg = highlight_config.bg,
        bold = highlight_config.bold,
        italic = highlight_config.italic,
        underline = highlight_config.underline,
    }
end

---@return nil
local function setup_highlights()
    local highlights = get_highlight_config()

    for highlight_name, highlight_config in pairs(highlights) do
        vim.api.nvim_set_hl(
            0,
            highlight_name,
            create_highlight_options(highlight_config)
        )
    end
end

-- Repository status display

---@param repository MultiRepoRepository
---@return string label
local function get_status_label(repository)
    local status = repository.status

    if not status then
        return ""
    end

    if status.is_dirty then
        return get_status_definition("dirty").label
    end

    return get_status_definition("clean").label
end

---@param repository MultiRepoRepository
---@return string highlight
local function get_status_highlight(repository)
    local status = repository.status

    if not status then
        return "Normal"
    end

    if status.is_dirty then
        return get_status_definition("dirty").highlight
    end

    return get_status_definition("clean").highlight
end

---@param repository MultiRepoRepository
---@return string label
local function get_branch_label(repository)
    local status = repository.status

    if not status then
        return ""
    end

    return status.branch or "detached"
end

---@param repository MultiRepoRepository
---@return string label
local function get_sync_label(repository)
    local status = repository.status
    local parts = {}

    if not status then
        return ""
    end

    if (status.ahead or 0) > 0 then
        table.insert(parts, "↑" .. status.ahead)
    end

    if (status.behind or 0) > 0 then
        table.insert(parts, "↓" .. status.behind)
    end

    return table.concat(parts, " ")
end

---@param repository MultiRepoRepository
---@return string ordinal
local function get_ordinal(repository)
    local status = repository.status

    return table.concat({
        repository.name or "",
        repository.display_path or "",
        repository.source or "",
        repository.path or "",
        status and status.branch or "",
        get_status_label(repository),
        get_sync_label(repository),
    }, " ")
end

-- Preview highlighting

---@param line string
---@return string|nil status_name
local function get_preview_status_name(line)
    local index_status = line:sub(1, 1)
    local worktree_status = line:sub(2, 2)
    local two_character_status = line:sub(1, 2)

    if two_character_status == "??" then
        return "untracked"
    end

    if index_status == "U"
        or worktree_status == "U"
        or two_character_status == "AA"
        or two_character_status == "DD"
    then
        return "conflict"
    end

    if index_status == "A" or worktree_status == "A" then
        return "added"
    end

    if index_status == "M" or worktree_status == "M" then
        return "modified"
    end

    if index_status == "D" or worktree_status == "D" then
        return "deleted"
    end

    if index_status == "R" or worktree_status == "R" then
        return "renamed"
    end

    if index_status == "C" or worktree_status == "C" then
        return "copied"
    end

    return nil
end

---@param buffer_id integer
---@param namespace_id integer
---@param line_index integer
---@param line string|nil
---@param highlight_group string
---@return nil
local function set_line_highlight(buffer_id, namespace_id, line_index, line, highlight_group)
    if not line or line == "" then
        return
    end

    vim.api.nvim_buf_set_extmark(buffer_id, namespace_id, line_index, 0, {
        end_row = line_index,
        end_col = #line,
        hl_group = highlight_group,
    })
end

---@param buffer_id integer
---@param namespace_id integer
---@param line string
---@param line_index integer
---@return nil
local function highlight_preview_status_line(buffer_id, namespace_id, line, line_index)
    if line:match("^##") then
        set_line_highlight(
            buffer_id,
            namespace_id,
            line_index,
            line,
            "MultiRepoPreviewMuted"
        )

        return
    end

    local status_name = get_preview_status_name(line)

    if not status_name then
        return
    end

    local status_definition = get_status_definition(status_name)

    set_line_highlight(
        buffer_id,
        namespace_id,
        line_index,
        line,
        status_definition.highlight
    )
end

---@param buffer_id integer
---@param lines string[]
---@return nil
local function highlight_preview(buffer_id, lines)
    local namespace_id = vim.api.nvim_create_namespace("multi_repo_preview")

    vim.api.nvim_buf_clear_namespace(buffer_id, namespace_id, 0, -1)

    for line_index, line in ipairs(lines) do
        local zero_based_line_index = line_index - 1

        if line == "Status" or line == "Recent commits" then
            set_line_highlight(
                buffer_id,
                namespace_id,
                zero_based_line_index,
                line,
                "MultiRepoPreviewTitle"
            )
        elseif line:match("^[-=]+$") then
            set_line_highlight(
                buffer_id,
                namespace_id,
                zero_based_line_index,
                line,
                "MultiRepoPreviewMuted"
            )
        else
            highlight_preview_status_line(
                buffer_id,
                namespace_id,
                line,
                zero_based_line_index
            )
        end
    end
end

-- Display layout

---@param value integer
---@param min_value integer
---@param max_value integer
---@return integer clamped_value
local function clamp(value, min_value, max_value)
    return math.max(min_value, math.min(value, max_value))
end

---@return integer picker_width
local function get_picker_width()
    local telescope_config = get_telescope_config()
    local layout_config = telescope_config.layout_config or {}
    local configured_width = layout_config.width or 0.9
    local columns = vim.o.columns

    if configured_width <= 1 then
        return math.floor(columns * configured_width)
    end

    return math.min(configured_width, columns)
end

---@return integer results_width
local function get_results_width()
    local telescope_config = get_telescope_config()
    local layout_config = telescope_config.layout_config or {}
    local picker_width = get_picker_width()
    local preview_width = layout_config.preview_width or 0.55

    if preview_width <= 1 then
        return math.floor(picker_width * (1 - preview_width))
    end

    return math.max(picker_width - preview_width, 20)
end

---@return MultiRepoTelescopeDisplayWidths display_widths
local function get_display_widths()
    local results_width = get_results_width()

    local branch_width = clamp(math.floor(results_width * 0.24), 8, 16)
    local status_width = clamp(math.floor(results_width * 0.15), 5, 10)
    local sync_width = clamp(math.floor(results_width * 0.12), 4, 8)

    local separator_width = 3
    local reserved_width = branch_width + status_width + sync_width + separator_width
    local path_width = math.max(results_width - reserved_width, 12)

    return {
        path = path_width,
        branch = branch_width,
        status = status_width,
        sync = sync_width,
    }
end

---@param path string|nil
---@param max_width integer
---@return string shortened_path
local function shorten_path_from_left(path, max_width)
    if not path or path == "" then
        return ""
    end

    if #path <= max_width then
        return path
    end

    if max_width <= 1 then
        return "…"
    end

    local shortened_path = path

    while #shortened_path > max_width do
        local next_separator_index = shortened_path:find("/")

        if not next_separator_index then
            break
        end

        shortened_path = shortened_path:sub(next_separator_index + 1)
    end

    shortened_path = "…/" .. shortened_path

    if #shortened_path <= max_width then
        return shortened_path
    end

    return "…" .. shortened_path:sub(#shortened_path - max_width + 2)
end

-- Preview

---@param repository MultiRepoRepository
---@param preview_data MultiRepoGitPreviewData
---@return string[] lines
local function build_preview_lines(repository, preview_data)
    local lines = {}

    table.insert(lines, repository.display_path)
    table.insert(lines, string.rep("=", #repository.display_path))
    table.insert(lines, "")

    table.insert(lines, "Status")
    table.insert(lines, "------")

    if #preview_data.status_lines == 0 then
        table.insert(lines, "No status available")
    else
        for _, line in ipairs(preview_data.status_lines) do
            table.insert(lines, line)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Recent commits")
    table.insert(lines, "--------------")

    if #preview_data.log_lines == 0 then
        table.insert(lines, "No commits available")
    else
        for _, line in ipairs(preview_data.log_lines) do
            table.insert(lines, line)
        end
    end

    return lines
end

---@return table previewer
local function create_previewer()
    local previewers = require("telescope.previewers")

    return previewers.new_buffer_previewer({
        define_preview = function(self, entry)
            local repository = entry.value
            local preview_data = Git.get_preview_data(repository.git_root)
            local lines = build_preview_lines(repository, preview_data)

            vim.bo[self.state.bufnr].filetype = "multi_repo_git_preview"
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

            highlight_preview(self.state.bufnr, lines)
        end,
    })
end

-- Finder

---@return fun(entry: table): string, table display_maker
local function create_display_maker()
    local entry_display = require("telescope.pickers.entry_display")
    local display_widths = get_display_widths()

    local displayer = entry_display.create({
        separator = " ",
        items = {
            {
                width = display_widths.path,
            },
            {
                width = display_widths.branch,
            },
            {
                width = display_widths.status,
            },
            {
                width = display_widths.sync,
            },
        },
    })

    return function(entry)
        local repository = entry.value
        local path = repository.display_path or repository.name or ""

        return displayer({
            shorten_path_from_left(path, display_widths.path),
            {
                get_branch_label(repository),
                "MultiRepoRepositoryBranch",
            },
            {
                get_status_label(repository),
                get_status_highlight(repository),
            },
            {
                get_sync_label(repository),
                "MultiRepoRepositorySync",
            },
        })
    end
end

---@param repositories MultiRepoRepository[]
---@return table finder
local function create_finder(repositories)
    local finders = require("telescope.finders")
    local make_display = create_display_maker()

    return finders.new_table({
        results = repositories,
        entry_maker = function(repository)
            return {
                value = repository,
                display = make_display,
                ordinal = get_ordinal(repository),
            }
        end,
    })
end

-- Async status loading

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

---@param repository MultiRepoRepository
---@param on_complete fun(status: MultiRepoGitStatus|nil): nil
---@return nil
local function load_repository_status(repository, on_complete)
    local output_lines = {}

    local job_id = vim.fn.jobstart({
        "git",
        "-C",
        repository.git_root,
        "status",
        "--short",
        "--branch",
    }, {
        stdout_buffered = true,
        stderr_buffered = true,

        on_stdout = function(_, data)
            output_lines = normalize_job_output(data)
        end,

        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.schedule(function()
                    on_complete(nil)
                end)

                return
            end

            local status = Git.parse_status_lines(output_lines)

            vim.schedule(function()
                on_complete(status)
            end)
        end,
    })

    if job_id <= 0 then
        on_complete(nil)
    end
end

---@param picker table
---@param repositories MultiRepoRepository[]
---@return fun(): nil schedule_refresh
local function create_refresh_scheduler(picker, repositories)
    local refresh_scheduled = false

    return function()
        if refresh_scheduled then
            return
        end

        refresh_scheduled = true

        vim.defer_fn(function()
            refresh_scheduled = false

            if not picker.prompt_bufnr or not vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
                return
            end

            pcall(function()
                picker:refresh(create_finder(repositories), {
                    reset_prompt = false,
                })
            end)
        end, REFRESH_DEBOUNCE_MS)
    end
end

---@param repositories MultiRepoRepository[]
---@param on_repository_update fun(): nil
---@return nil
local function load_repository_statuses(repositories, on_repository_update)
    local next_index = 1
    local running_jobs = 0

    local function run_next_jobs()
        while running_jobs < STATUS_JOB_CONCURRENCY and next_index <= #repositories do
            local repository = repositories[next_index]

            next_index = next_index + 1
            running_jobs = running_jobs + 1

            load_repository_status(repository, function(status)
                running_jobs = running_jobs - 1

                if status then
                    repository.status = status
                    on_repository_update()
                end

                run_next_jobs()
            end)
        end
    end

    run_next_jobs()
end

-- Actions

---@param prompt_buffer_number integer
---@return nil
local function select_repository(prompt_buffer_number)
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local config = Config.get()
    local selection = action_state.get_selected_entry()

    actions.close(prompt_buffer_number)

    if not selection or not selection.value then
        return
    end

    if type(config.on_select) == "function" then
        config.on_select(selection.value)
    end
end

-- Public API

---@param repositories MultiRepoRepository[]
---@return nil
function Telescope.open(repositories)
    setup_highlights()

    local pickers = require("telescope.pickers")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local telescope_config = get_telescope_config()

    local picker = pickers.new({}, {
        prompt_title = "nvim-multi-repo",
        results_title = "Repositories",
        preview_title = "Git Preview",

        layout_strategy = telescope_config.layout_strategy or "horizontal",
        layout_config = telescope_config.layout_config or {
            width = 0.9,
            height = 0.75,
            preview_width = 0.45,
        },

        finder = create_finder(repositories),
        sorter = conf.generic_sorter({}),
        previewer = create_previewer(),

        attach_mappings = function(prompt_buffer_number)
            actions.select_default:replace(function()
                select_repository(prompt_buffer_number)
            end)

            return true
        end,
    })

    picker:find()

    vim.schedule(function()
        local schedule_refresh = create_refresh_scheduler(picker, repositories)

        load_repository_statuses(repositories, schedule_refresh)
    end)
end

return Telescope
