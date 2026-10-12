-- Tree-sitter highlighting, indentation and folding. The main branch of
-- nvim-treesitter only installs parsers (into stdpath("data")/site) and
-- keeps them current; the parsers themselves are listed in
-- lua/dotfiles/tools.lua and installed by the bootstrap, not at startup.
-- Compiling a parser needs the tree-sitter CLI and a C compiler.
return {
  "nvim-treesitter/nvim-treesitter",
  branch = "main",
  lazy = false,
  build = ":TSUpdate",
  config = function()
    require("nvim-treesitter").setup({})
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("dotfiles_treesitter", { clear = true }),
      callback = function(event)
        local lang = vim.treesitter.language.get_lang(vim.bo[event.buf].filetype)
        if not lang or not pcall(vim.treesitter.start, event.buf, lang) then
          return
        end
        vim.bo[event.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        vim.wo[0][0].foldmethod = "expr"
        vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
      end,
    })
  end,
}
