-- Catppuccin, the one theme of this repository. Like Ghostty and yazi, the
-- light half is always Latte and the dark half is the flavor recorded in
-- config/catppuccin/flavor; scripts/theme.sh rewrites the `dark` line.
-- Neovim 0.10+ asks the terminal for its background color and sets
-- 'background' from the answer, which "auto" follows.
return {
  "catppuccin/nvim",
  name = "catppuccin",
  lazy = false,
  priority = 1000, -- load before every other plugin so they inherit the highlights
  opts = {
    flavour = "auto",
    background = { light = "latte", dark = "macchiato" },
    -- The plugins under lua/plugins/ are detected and themed (auto_integrations).
    lsp_styles = { underlines = { errors = { "undercurl" }, warnings = { "undercurl" } } },
  },
  config = function(_, opts)
    require("catppuccin").setup(opts)
    vim.cmd.colorscheme("catppuccin")
  end,
}
