local Config = {}

---@class MultiRepoStatusDefinition
---@field label string
---@field highlight string

---@class MultiRepoHighlightDefinition
---@field link string|nil
---@field fg string|nil
---@field bg string|nil
---@field bold boolean|nil
---@field italic boolean|nil
---@field underline boolean|nil

---@class MultiRepoScannerConfig
---@field max_depth integer
---@field follow_symlinks boolean
---@field ignored_dirs string[]
---@field include_dirs string[]

---@class MultiRepoUpdaterConfig
---@field concurrency integer
---@field fetch_args string[]
---@field pull_args string[]

---@class MultiRepoTelescopeLayoutConfig
---@field width number|integer|nil
---@field height number|integer|nil
---@field preview_width number|integer|nil

---@class MultiRepoTelescopeConfig
---@field layout_strategy string|nil
---@field layout_config MultiRepoTelescopeLayoutConfig|nil
---@field status table<string, MultiRepoStatusDefinition>|nil
---@field highlights table<string, MultiRepoHighlightDefinition>|nil

---@class MultiRepoConfig
---@field scanner MultiRepoScannerConfig
---@field updater MultiRepoUpdaterConfig
---@field on_select fun(repository: MultiRepoRepository)|nil
---@field telescope MultiRepoTelescopeConfig

---@type MultiRepoConfig
local default_config = {
    scanner = {
        max_depth = 4,
        follow_symlinks = true,

        ignored_dirs = {
            ".git",
            "node_modules",
            "vendor",
            "dist",
            "build",
            ".cache",
        },

        include_dirs = {},
    },

    updater = {
        concurrency = 2,

        fetch_args = {
            "fetch",
            "--all",
            "--prune",
        },

        pull_args = {
            "pull",
            "--ff-only",
        },
    },

    on_select = function(repository)
        vim.notify(
            "Selected repository: " .. repository.display_path,
            vim.log.levels.INFO
        )
    end,

    telescope = {
        layout_strategy = "horizontal",

        layout_config = {
            width = 0.9,
            height = 0.75,
            preview_width = 0.45,
        },

        status = {
            clean = {
                label = "clean",
                highlight = "MultiRepoStatusClean",
            },

            dirty = {
                label = "dirty",
                highlight = "MultiRepoStatusDirty",
            },

            staged = {
                label = "+",
                highlight = "MultiRepoStatusAdded",
            },

            changed = {
                label = "~",
                highlight = "MultiRepoStatusModified",
            },

            untracked = {
                label = "?",
                highlight = "MultiRepoStatusUntracked",
            },

            added = {
                label = "A",
                highlight = "MultiRepoStatusAdded",
            },

            modified = {
                label = "M",
                highlight = "MultiRepoStatusModified",
            },

            deleted = {
                label = "D",
                highlight = "MultiRepoStatusDeleted",
            },

            renamed = {
                label = "R",
                highlight = "MultiRepoStatusRenamed",
            },

            copied = {
                label = "C",
                highlight = "MultiRepoStatusCopied",
            },

            conflict = {
                label = "U",
                highlight = "MultiRepoStatusConflict",
            },
        },

        highlights = {
            MultiRepoStatusClean = {
                link = "DiagnosticOk",
            },

            MultiRepoStatusDirty = {
                link = "DiagnosticWarn",
            },

            MultiRepoStatusUntracked = {
                link = "DiagnosticHint",
            },

            MultiRepoStatusAdded = {
                link = "DiagnosticOk",
            },

            MultiRepoStatusModified = {
                link = "DiagnosticWarn",
            },

            MultiRepoStatusDeleted = {
                link = "DiagnosticError",
            },

            MultiRepoStatusRenamed = {
                link = "DiagnosticInfo",
            },

            MultiRepoStatusCopied = {
                link = "DiagnosticInfo",
            },

            MultiRepoStatusConflict = {
                link = "DiagnosticError",
            },

            MultiRepoPreviewTitle = {
                link = "Title",
            },

            MultiRepoPreviewMuted = {
                link = "Comment",
            },

            MultiRepoRepositoryBranch = {
                link = "Identifier",
            },

            MultiRepoRepositorySync = {
                link = "Comment",
            },
        },
    },
}

---@type MultiRepoConfig
local current_config = vim.deepcopy(default_config)

---@param user_config MultiRepoConfig|nil
---@return nil
function Config.setup(user_config)
    current_config = vim.tbl_deep_extend("force", default_config, user_config or {})
end

---@return MultiRepoConfig config
function Config.get()
    return current_config
end

return Config
