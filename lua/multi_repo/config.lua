local Config = {}

local default_config = {
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
            preview_width = 0.55,
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

local current_config = vim.deepcopy(default_config)

function Config.setup(user_config)
    current_config = vim.tbl_deep_extend("force", default_config, user_config or {})
end

function Config.get()
    return current_config
end

return Config
