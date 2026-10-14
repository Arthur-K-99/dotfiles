-- Runs require("dotfiles.bootstrap").missing() and install() with the real
-- can_compile(), against a PATH with and without a tree-sitter CLI, stand-ins
-- for mason-registry and nvim-treesitter, and no network:
--
--   nvim -l tests/nvim_bootstrap_missing.lua config/nvim
--
-- On macOS and Linux a missing parser counts as skipped exactly when the
-- tree-sitter CLI is not on PATH; an installed parser is ok either way.
local config = assert(arg[1], "usage: nvim -l tests/nvim_bootstrap_missing.lua <config/nvim>")
vim.opt.runtimepath:prepend(config)

if vim.fn.has("win32") == 1 then
  io.stdout:write("skipped: the Windows branch of can_compile() needs Windows paths\n")
  os.exit(0)
end

-- Names no Neovim bundles, so the result does not depend on the build.
package.loaded["dotfiles.tools"] = {
  parsers = { "dotfiles_test_built", "dotfiles_test_absent" },
  servers = { a = "pkg-a" },
}

local root = vim.fn.tempname()
local with_cli, without_cli, site = root .. "/with-cli", root .. "/without-cli", root .. "/site"
vim.fn.mkdir(with_cli, "p")
vim.fn.mkdir(without_cli, "p")
vim.fn.mkdir(site .. "/parser", "p")
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, with_cli .. "/tree-sitter")
vim.uv.fs_chmod(with_cli .. "/tree-sitter", tonumber("755", 8))
-- An installed parser is any parser/<lang>.* file on 'runtimepath'.
vim.fn.writefile({}, site .. "/parser/dotfiles_test_built.so")
vim.opt.runtimepath:append(site)

local installs
package.loaded["mason-registry"] = {
  refresh = function() end,
  is_installed = function()
    return true
  end,
}
package.loaded["nvim-treesitter"] = {
  install = function(langs)
    installs[#installs + 1] = table.concat(langs, " ")
    return {
      wait = function()
        return true
      end,
    }
  end,
}

local bootstrap = require("dotfiles.bootstrap")

-- Runs install() with PATH set to one directory; returns status and output.
local function install(path)
  installs = {}
  local saved_path = vim.env.PATH
  vim.env.PATH = path
  local output = {}
  local stdout, exit = io.stdout, os.exit
  io.stdout = {
    write = function(_, ...)
      output[#output + 1] = table.concat({ ... })
    end,
  }
  os.exit = function(code)
    error({ exit = code }, 0)
  end
  local ok, result = pcall(bootstrap.install)
  io.stdout, os.exit, vim.env.PATH = stdout, exit, saved_path
  if ok or type(result) ~= "table" then
    error("install() did not exit: " .. tostring(result))
  end
  return result.exit, table.concat(output)
end

local function missing(path)
  local saved_path = vim.env.PATH
  vim.env.PATH = path
  local result = bootstrap.missing()
  vim.env.PATH = saved_path
  return result
end

local function expect(condition, message, output)
  if not condition then
    error(message .. "\n" .. (output or ""), 0)
  end
end

local cases = 0
local function case(name, body)
  body()
  cases = cases + 1
  io.stdout:write("ok ", name, "\n")
end

case("without the tree-sitter CLI a missing parser is skipped", function()
  local result = missing(without_cli)
  expect(vim.deep_equal(result.skipped, { "dotfiles_test_absent" }), "skipped: " .. vim.inspect(result))
  expect(#result.parsers == 0, "nothing may count as missing: " .. vim.inspect(result))
  local status, output = install(without_cli)
  expect(status == 0, "skipped parsers must not fail install()", output)
  expect(#installs == 0, "nvim-treesitter must not be asked to install", output)
  expect(output:find("skipped parser dotfiles_test_absent (", 1, true), "the skip is reported", output)
  expect(output:find("ok parser dotfiles_test_built", 1, true), "the installed parser is ok", output)
end)

case("with the tree-sitter CLI a missing parser is missing", function()
  local result = missing(with_cli)
  expect(vim.deep_equal(result.parsers, { "dotfiles_test_absent" }), "missing: " .. vim.inspect(result))
  expect(#result.skipped == 0, "nothing may be skipped: " .. vim.inspect(result))
  local status, output = install(with_cli)
  expect(installs[1] == "dotfiles_test_absent", "only the missing parser is installed", output)
  -- The stand-in installs nothing, so the report still names it.
  expect(status == 1, "a parser still missing must fail install()", output)
  expect(output:find("missing parser dotfiles_test_absent", 1, true), "the report names it", output)
end)

io.stdout:write(cases, " parser skip cases pass.\n")
