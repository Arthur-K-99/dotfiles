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
o.completeopt = "menu,menuone,noinsert,fuzzy,popup"

-- Search
o.ignorecase = true
o.smartcase = true
o.inccommand = "split" -- live preview of :s substitutions

-- Clipboard. The system clipboard is set after startup so a provider check
-- (pbcopy, wl-copy, xsel, clip.exe) does not slow the start.
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
