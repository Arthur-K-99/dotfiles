-- which-key shows the keys that continue a prefix after 'timeoutlen'. The
-- groups name the <leader> prefixes used across lua/plugins/.
return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  opts = {
    preset = "helix",
    spec = {
      { "<leader>b", group = "buffer" },
      { "<leader>f", group = "find" },
      { "<leader>g", group = "git" },
      { "<leader>s", group = "search" },
      { "<leader>x", group = "diagnostics" },
      { "g", group = "goto" },
      { "gr", group = "lsp" },
      { "[", group = "previous" },
      { "]", group = "next" },
      { "z", group = "fold" },
    },
  },
  keys = {
    {
      "<leader>?",
      function()
        require("which-key").show({ global = false })
      end,
      desc = "Buffer keymaps",
    },
  },
}
