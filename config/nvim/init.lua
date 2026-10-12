-- Neovim configuration, linked to ~/.config/nvim on Unix and
-- %LOCALAPPDATA%\nvim on Windows. Plugins are declared one file per concern
-- under lua/plugins/ and pinned by lazy-lock.json; scripts/bootstrap_tools.sh
-- (install.ps1 on Windows) installs exactly those versions, so nothing here
-- reaches the network at startup. After editing a plugin file, run
-- :Lazy install (new plugins) or :Lazy update (new versions) and commit the
-- lockfile.
require("dotfiles.options")
require("dotfiles.keymaps")
require("dotfiles.autocmds")
require("dotfiles.lazy")
