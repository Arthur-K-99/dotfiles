-- Keymaps that need no plugin. Plugin keys live in the plugin's own file
-- under lua/plugins/, where which-key reads their descriptions.
local map = vim.keymap.set

-- Clear the search highlight with Esc in normal mode.
map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })

-- Window navigation: <C-h/j/k/l> belong to vim-tmux-navigator (plugins/tmux.lua).
map("n", "<leader>w", "<cmd>write<CR>", { desc = "Write file" })
map("n", "<leader>q", "<cmd>confirm quit<CR>", { desc = "Quit window" })
map("n", "<leader>-", "<cmd>split<CR>", { desc = "Split below" })
map("n", "<leader>|", "<cmd>vsplit<CR>", { desc = "Split right" })

-- Buffers
map("n", "<S-h>", "<cmd>bprevious<CR>", { desc = "Previous buffer" })
map("n", "<S-l>", "<cmd>bnext<CR>", { desc = "Next buffer" })
map("n", "<leader>bd", "<cmd>bdelete<CR>", { desc = "Delete buffer" })

-- Keep the cursor centred while jumping through search results and pages.
map("n", "n", "nzzzv", { desc = "Next match" })
map("n", "N", "Nzzzv", { desc = "Previous match" })
map("n", "<C-d>", "<C-d>zz", { desc = "Half page down" })
map("n", "<C-u>", "<C-u>zz", { desc = "Half page up" })

-- Move lines in visual mode and keep the selection.
map("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
map("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })
map("v", "<", "<gv", { desc = "Indent left" })
map("v", ">", ">gv", { desc = "Indent right" })

-- Diagnostics. Neovim 0.11 binds ]d, [d and <C-w>d itself; these add the
-- location list and a float for the current line.
map("n", "<leader>xd", vim.diagnostic.setloclist, { desc = "Diagnostics to location list" })
map("n", "<leader>xl", vim.diagnostic.open_float, { desc = "Line diagnostics" })

-- Terminal: Esc leaves terminal mode.
map("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })
