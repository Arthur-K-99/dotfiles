-- The Neovim half of vim-tmux-navigator: Ctrl-h/j/k/l move between Neovim
-- splits and, at the edge of Neovim, on to the neighbouring tmux pane. The
-- tmux half is in config/tmux/tmux.conf. Outside tmux (Windows, a plain
-- terminal) the same keys fall back to Neovim's own window commands.
return {
  "christoomey/vim-tmux-navigator",
  cmd = {
    "TmuxNavigateLeft",
    "TmuxNavigateDown",
    "TmuxNavigateUp",
    "TmuxNavigateRight",
    "TmuxNavigatePrevious",
    "TmuxNavigatorProcessList", -- shows what the tmux half sees when a key does not cross over
  },
  init = function()
    vim.g.tmux_navigator_no_mappings = 1
  end,
  keys = {
    { "<C-h>", "<cmd>TmuxNavigateLeft<CR>", desc = "Window left", mode = { "n", "t" } },
    { "<C-j>", "<cmd>TmuxNavigateDown<CR>", desc = "Window down", mode = { "n", "t" } },
    { "<C-k>", "<cmd>TmuxNavigateUp<CR>", desc = "Window up", mode = { "n", "t" } },
    { "<C-l>", "<cmd>TmuxNavigateRight<CR>", desc = "Window right", mode = { "n", "t" } },
  },
}
