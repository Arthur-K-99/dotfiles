-- Editor options. Neovim's own defaults already cover filetype detection,
-- syntax, true color, incsearch, smarttab and the mouse.
local o = vim.o

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Appearance
o.number = true
o.relativenumber = true
o.signcolumn = "yes" -- gitsigns and diagnostics never shift the text
o.cursorline = true
o.scrolloff = 8
o.sidescrolloff = 8
o.wrap = false
o.showmode = false -- the statusline shows the mode
o.list = true
vim.opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
vim.opt.fillchars = { eob = " " }
o.splitright = true
o.splitbelow = true
o.pumheight = 12
o.winborder = "rounded" -- hover, signature help, diagnostics and other floats

-- Editing
o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.softtabstop = 4
o.shiftround = true
o.breakindent = true
o.undofile = true
o.updatetime = 250
o.timeoutlen = 300
o.confirm = true -- ask instead of failing when a buffer has unsaved changes
o.foldlevel = 99 -- Tree-sitter folds (plugins/treesitter.lua) start open
o.foldlevelstart = 99
o.completeopt = "menu,menuone,noinsert,fuzzy,popup"

-- Search
o.ignorecase = true
o.smartcase = true
o.inccommand = "split" -- live preview of :s substitutions

-- Clipboard. The system clipboard is set after startup so a provider check
-- (pbcopy, wl-copy, xsel) does not slow the start. WSL without a display has
-- no provider of its own, so clip.exe and PowerShell serve there, as they do
-- for tmux-yank (the recipe from :help clipboard-wsl).
if vim.fn.has("wsl") == 1 and vim.fn.executable("clip.exe") == 1 and not vim.env.WAYLAND_DISPLAY and not vim.env.DISPLAY then
  local paste = 'powershell.exe -NoLogo -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw).tostring().replace("`r", ""))'
  vim.g.clipboard = {
    name = "WslClipboard",
    copy = { ["+"] = "clip.exe", ["*"] = "clip.exe" },
    paste = { ["+"] = paste, ["*"] = paste },
    cache_enabled = 0,
  }
end
vim.schedule(function()
  o.clipboard = "unnamedplus"
end)

-- Diagnostics (Neovim 0.11+): a sign per severity and the message of the
-- current line beside it; `<leader>xd` lists everything.
vim.diagnostic.config({
  severity_sort = true,
  float = { border = "rounded", source = "if_many" },
  virtual_text = { current_line = true, spacing = 2 },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "",
      [vim.diagnostic.severity.WARN] = "",
      [vim.diagnostic.severity.INFO] = "",
      [vim.diagnostic.severity.HINT] = "",
    },
  },
})
