-- Autocommands that need no plugin.
local augroup = vim.api.nvim_create_augroup("dotfiles", { clear = true })

-- Briefly highlight yanked text.
vim.api.nvim_create_autocmd("TextYankPost", {
  group = augroup,
  callback = function()
    vim.hl.on_yank()
  end,
})

-- Return to the last cursor position when a file is reopened.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = augroup,
  callback = function(event)
    local mark = vim.api.nvim_buf_get_mark(event.buf, '"')
    local lines = vim.api.nvim_buf_line_count(event.buf)
    if mark[1] > 0 and mark[1] <= lines then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Resize splits when the terminal window changes size (tmux zoom, Ghostty).
vim.api.nvim_create_autocmd("VimResized", {
  group = augroup,
  callback = function()
    vim.cmd("wincmd =")
  end,
})

-- Two-space indentation for the file types that convention keeps narrow.
vim.api.nvim_create_autocmd("FileType", {
  group = augroup,
  pattern = { "lua", "json", "jsonc", "yaml", "toml", "markdown", "javascript", "typescript", "typescriptreact" },
  callback = function()
    vim.bo.shiftwidth = 2
    vim.bo.tabstop = 2
    vim.bo.softtabstop = 2
  end,
})

-- q closes help, quickfix and similar read-only windows.
vim.api.nvim_create_autocmd("FileType", {
  group = augroup,
  pattern = { "help", "qf", "checkhealth", "lspinfo", "man" },
  callback = function(event)
    vim.bo[event.buf].buflisted = false
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = event.buf, silent = true, desc = "Close window" })
  end,
})
