-- Language servers. Neovim 0.11 configures and starts servers itself
-- (vim.lsp.config / vim.lsp.enable); nvim-lspconfig contributes the per-server
-- defaults under lsp/, Mason installs the servers listed in
-- lua/dotfiles/tools.lua (through the bootstrap) and puts them on PATH, and
-- mason-lspconfig enables every installed server. Completion is Neovim's own
-- (vim.lsp.completion), triggered as you type.
return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    opts = { ui = { border = "rounded" } },
  },
  {
    "neovim/nvim-lspconfig",
    lazy = false,
    dependencies = { "mason-org/mason.nvim", "mason-org/mason-lspconfig.nvim" },
    config = function()
      -- PowerShell Editor Services is a bundle Mason unpacks, which the server
      -- definition needs to know, and it runs on pwsh, which Linux machines may lack.
      vim.lsp.config("powershell_es", {
        bundle_path = vim.fn.stdpath("data") .. "/mason/packages/powershell-editor-services",
      })
      require("mason-lspconfig").setup({
        ensure_installed = {},
        automatic_enable = { exclude = { "powershell_es" } },
      })
      if vim.fn.executable("pwsh") == 1 then
        vim.lsp.enable("powershell_es")
      end

      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("dotfiles_lsp", { clear = true }),
        callback = function(event)
          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if not client then
            return
          end
          if client:supports_method("textDocument/completion") then
            vim.lsp.completion.enable(true, client.id, event.buf, { autotrigger = true })
          end
          -- Neovim 0.11 maps grn (rename), gra (code action), grr (references),
          -- gri (implementation), grt (type definition), gO (symbols), K (hover)
          -- and <C-s> (signature help) itself; these add the rest.
          local function map(lhs, rhs, desc, mode)
            vim.keymap.set(mode or "n", lhs, rhs, { buffer = event.buf, desc = desc })
          end
          map("gd", "<cmd>FzfLua lsp_definitions<CR>", "Goto definition")
          map("gD", vim.lsp.buf.declaration, "Goto declaration")
          map("grr", "<cmd>FzfLua lsp_references<CR>", "References")
          map("gri", "<cmd>FzfLua lsp_implementations<CR>", "Implementations")
          map("grt", "<cmd>FzfLua lsp_typedefs<CR>", "Type definition")
          map("<leader>cf", function()
            vim.lsp.buf.format({ async = true })
          end, "Format buffer", { "n", "v" })
          if client:supports_method("textDocument/inlayHint") then
            map("<leader>ch", function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = event.buf }), { bufnr = event.buf })
            end, "Toggle inlay hints")
          end
        end,
      })
    end,
  },
}
