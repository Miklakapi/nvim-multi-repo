local Config = require("multi_repo.config")
local Git = require("multi_repo.git")
local Scanner = require("multi_repo.scanner")
local Telescope = require("multi_repo.telescope")
local Updater = require("multi_repo.updater")

local MultiRepo = {}

local function open_picker()
    local cwd = vim.fn.getcwd()
    local scan_root = Git.get_root(cwd) or cwd
    local repositories = Scanner.scan(scan_root)

    if #repositories == 0 then
        vim.notify("No repositories found", vim.log.levels.WARN)
        return
    end

    Telescope.open(repositories)
end

function MultiRepo.setup(user_config)
    Config.setup(user_config)

    vim.api.nvim_create_user_command("MultiRepo", function()
        open_picker()
    end, {})

    vim.api.nvim_create_user_command("MultiRepoFetch", function()
        Updater.fetch()
    end, {})

    vim.api.nvim_create_user_command("MultiRepoPull", function()
        Updater.pull()
    end, {})
end

return MultiRepo
