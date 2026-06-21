local Config = require("multi_repo.config")
local Git = require("multi_repo.git")

local Telescope = {}

local function get_telescope_config()
    local config = Config.get()

    return config.telescope or {}
end

local function get_status_config()
    local telescope_config = get_telescope_config()

    return telescope_config.status or {}
end

local function get_highlight_config()
    local telescope_config = get_telescope_config()

    return telescope_config.highlights or {}
end

local function get_status_definition(status_name)
    local status_config = get_status_config()

    return status_config[status_name] or {
        label = status_name,
        highlight = "Normal",
    }
end

local function setup_highlights()
    local highlights = get_highlight_config()

    for highlight_name, highlight_config in pairs(highlights) do
        vim.api.nvim_set_hl(0, highlight_name, highlight_config)
    end
end

local function get_status_label(repository)
    local status = repository.status or {}

    if status.is_dirty then
        return get_status_definition("dirty").label
    end

    return get_status_definition("clean").label
end

local function get_status_highlight(repository)
    local status = repository.status or {}

    if status.is_dirty then
        return get_status_definition("dirty").highlight
    end

    return get_status_definition("clean").highlight
end

local function get_sync_label(repository)
    local status = repository.status or {}
    local parts = {}

    if (status.ahead or 0) > 0 then
        table.insert(parts, "↑" .. status.ahead)
    end

    if (status.behind or 0) > 0 then
        table.insert(parts, "↓" .. status.behind)
    end

    return table.concat(parts, " ")
end

local function get_ordinal(repository)
    local status = repository.status or {}

    return table.concat({
        repository.name or "",
        repository.display_path or "",
        repository.source or "",
        status.branch or "",
        get_status_label(repository),
        get_sync_label(repository),
    }, " ")
end

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

local function create_display_maker()
    local entry_display = require("telescope.pickers.entry_display")

    local displayer = entry_display.create({
        separator = " ",
        items = {
            {
                width = 42,
            },
            {
                width = 22,
            },
            {
                width = 10,
            },
            {
                remaining = true,
            },
        },
    })

    return function(entry)
        local repository = entry.value
        local status = repository.status or {}
        local branch = status.branch or "detached"
        local sync = get_sync_label(repository)

        return displayer({
            repository.display_path or repository.name or "",
            {
                branch,
                "MultiRepoRepositoryBranch",
            },
            {
                get_status_label(repository),
                get_status_highlight(repository),
            },
            {
                sync,
                "MultiRepoRepositorySync",
            },
        })
    end
end

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

local function create_previewer()
    local previewers = require("telescope.previewers")

    return previewers.new_buffer_previewer({
        define_preview = function(self, entry)
            local repository = entry.value
            local lines = {}

            table.insert(lines, repository.display_path)
            table.insert(lines, string.rep("=", #repository.display_path))
            table.insert(lines, "")

            for _, line in ipairs(Git.get_preview(repository.git_root)) do
                table.insert(lines, line)
            end

            vim.bo[self.state.bufnr].filetype = "multi_repo_git_preview"
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

            highlight_preview(self.state.bufnr, lines)
        end,
    })
end

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

function Telescope.open(repositories)
    setup_highlights()

    local pickers = require("telescope.pickers")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local telescope_config = get_telescope_config()

    pickers.new({}, {
        prompt_title = "nvim-multi-repo",
        results_title = "Repositories",
        preview_title = "Git Preview",

        layout_strategy = telescope_config.layout_strategy or "horizontal",
        layout_config = telescope_config.layout_config or {
            width = 0.9,
            height = 0.75,
            preview_width = 0.55,
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
    }):find()
end

return Telescope
