-- fzf-lua: files, text, buffers, help and LSP results through the fzf
-- binary the repository installs on every platform, with fd and ripgrep as
-- the file and text sources and bat for previews, all installed too.
return {
  "ibhagwan/fzf-lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = "FzfLua",
  event = "VeryLazy", -- so vim.ui.select (code actions, more) goes through fzf from the start
  opts = {
    "default-title",
    winopts = { height = 0.85, width = 0.85, preview = { layout = "flex", flip_columns = 140 } },
    keymap = {
      builtin = { ["<C-d>"] = "preview-page-down", ["<C-u>"] = "preview-page-up" },
      fzf = { ["ctrl-q"] = "select-all+accept" }, -- send every result to the quickfix list
    },
    files = { cwd_prompt = false },
  },
  config = function(_, opts)
    local fzf = require("fzf-lua")
    fzf.setup(opts)
    fzf.register_ui_select()
  end,
  keys = {
    { "<leader><space>", "<cmd>FzfLua files<CR>", desc = "Find files" },
    { "<leader>ff", "<cmd>FzfLua files<CR>", desc = "Find files" },
    { "<leader>fr", "<cmd>FzfLua oldfiles<CR>", desc = "Recent files" },
    { "<leader>fb", "<cmd>FzfLua buffers<CR>", desc = "Buffers" },
    { "<leader>fg", "<cmd>FzfLua git_files<CR>", desc = "Git files" },
    { "<leader>fh", "<cmd>FzfLua helptags<CR>", desc = "Help" },
    { "<leader>fk", "<cmd>FzfLua keymaps<CR>", desc = "Keymaps" },
    { "<leader>fc", "<cmd>FzfLua commands<CR>", desc = "Commands" },
    { "<leader>f.", "<cmd>FzfLua resume<CR>", desc = "Resume last picker" },
    { "<leader>/", "<cmd>FzfLua live_grep<CR>", desc = "Grep" },
    { "<leader>sg", "<cmd>FzfLua live_grep<CR>", desc = "Grep" },
    { "<leader>sw", "<cmd>FzfLua grep_cword<CR>", desc = "Grep word under cursor" },
    { "<leader>sw", "<cmd>FzfLua grep_visual<CR>", desc = "Grep selection", mode = "v" },
    { "<leader>sb", "<cmd>FzfLua lgrep_curbuf<CR>", desc = "Grep current buffer" },
    { "<leader>ss", "<cmd>FzfLua lsp_document_symbols<CR>", desc = "Document symbols" },
    { "<leader>sS", "<cmd>FzfLua lsp_live_workspace_symbols<CR>", desc = "Workspace symbols" },
    { "<leader>xx", "<cmd>FzfLua diagnostics_document<CR>", desc = "Document diagnostics" },
    { "<leader>xX", "<cmd>FzfLua diagnostics_workspace<CR>", desc = "Workspace diagnostics" },
    { "<leader>gc", "<cmd>FzfLua git_commits<CR>", desc = "Commits" },
    { "<leader>gC", "<cmd>FzfLua git_bcommits<CR>", desc = "Buffer commits" },
    { "<leader>gg", "<cmd>FzfLua git_status<CR>", desc = "Git status" },
  },
}
