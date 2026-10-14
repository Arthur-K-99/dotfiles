-- lazy.nvim bootstrap and setup. The first start clones lazy.nvim itself;
-- the plugins come from lazy-lock.json through
-- require("dotfiles.bootstrap").plugins(), which the bootstrap scripts run
-- headless. Missing plugins are never fetched while Neovim starts, so a start
-- is deterministic and the doctor's headless load cannot trigger a clone.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local repo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", repo, lazypath })
  if vim.v.shell_error ~= 0 then
    io.stderr:write("Failed to clone lazy.nvim into " .. lazypath .. ":\n" .. out .. "\n")
    -- Only a human can read the message; in a headless bootstrap the exit
    -- status reports the failure, and waiting for a key would hang.
    if #vim.api.nvim_list_uis() > 0 then
      vim.api.nvim_echo({ { "Failed to clone lazy.nvim:\n", "ErrorMsg" }, { out, "WarningMsg" } }, true, {})
      vim.fn.getchar()
    end
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- The bootstrap's own headless runs (nvim --headless -c 'lua
-- require("dotfiles.bootstrap")...') start before the plugins they install
-- exist, and lazy.nvim reports every plugin that loads at startup as "not
-- installed" first. Those runs check the plugins themselves, so the message
-- is dropped there; any other start still shows it.
local bootstrapping = #vim.api.nvim_list_uis() == 0
  and vim.iter(vim.v.argv):any(function(arg)
    return arg:find("dotfiles.bootstrap", 1, true) ~= nil
  end)
local notify = vim.notify
if bootstrapping then
  vim.notify = function(msg, ...)
    if not (type(msg) == "string" and msg:match("^Plugin %S+ is not installed$")) then
      return notify(msg, ...)
    end
  end
end

require("lazy").setup({
  spec = { { import = "plugins" } },
  -- Plugins are installed by the bootstrap from the lockfile, never on start.
  install = { missing = false, colorscheme = { "catppuccin" } },
  -- No update checks or change notifications: updates are a deliberate
  -- `:Lazy update` followed by a commit of lazy-lock.json.
  checker = { enabled = false },
  change_detection = { notify = false },
  rocks = { enabled = false },
  ui = { border = "rounded" },
  -- Headless runs print each task's result, not git's progress meter.
  headless = { process = false, task = false },
  performance = {
    rtp = {
      -- Stock plugins this configuration replaces or never uses.
      disabled_plugins = { "gzip", "netrwPlugin", "tarPlugin", "tohtml", "tutor", "zipPlugin" },
    },
  },
})
vim.notify = notify
