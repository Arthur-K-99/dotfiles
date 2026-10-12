-- What the bootstrap installs beyond the plugins: Tree-sitter parsers and
-- language servers. scripts/bootstrap_tools.sh and install.ps1 run
-- `require("dotfiles.bootstrap").install()` headless after the plugins are
-- in place; the doctors run `.check()`. Neovim itself bundles the parsers
-- for c, lua, markdown, markdown_inline, query, vim and vimdoc; jsonc files
-- use the json parser.
return {
  parsers = {
    "bash",
    "diff",
    "dockerfile",
    "git_config",
    "git_rebase",
    "gitcommit",
    "gitignore",
    "javascript",
    "json",
    "powershell",
    "python",
    "regex",
    "toml",
    "tsx",
    "typescript",
    "yaml",
  },
  -- nvim-lspconfig server name = Mason package name. Every server is a
  -- static binary from its GitHub release or an npm package, which Mason
  -- runs with the Node.js that mise installs, so the same list works on
  -- macOS, Linux and Windows.
  servers = {
    bashls = "bash-language-server",
    jsonls = "json-lsp",
    lua_ls = "lua-language-server",
    marksman = "marksman",
    powershell_es = "powershell-editor-services",
    pyright = "pyright",
    taplo = "taplo",
    ts_ls = "typescript-language-server",
    yamlls = "yaml-language-server",
  },
}
