-- Headless installation and verification of the plugins pinned in
-- lazy-lock.json and of what they need: Tree-sitter parsers and Mason
-- packages from lua/dotfiles/tools.lua.
--
--   nvim --headless -c 'lua require("dotfiles.bootstrap").plugins()'
--   nvim --headless -c 'lua require("dotfiles.bootstrap").install()'
--   nvim --headless -c 'lua require("dotfiles.bootstrap").update()'
--   nvim --headless -c 'lua require("dotfiles.bootstrap").check()'
--
-- plugins() clones missing plugins at their locked commits and moves drifted
-- ones back; install(), in a fresh process so the plugins are loaded, adds the
-- parsers and packages; update(), for scripts/update.sh, refreshes them.
-- Every function prints one line per item ("ok",
-- "missing", "stale" or "skipped", then "plugin", "parser" or "package", then
-- the name) and exits nonzero when something is missing, so
-- scripts/bootstrap_tools.sh, install.ps1 and the doctors can rely on the
-- status. None of them runs at an interactive start.
--
-- Compiling a parser needs the tree-sitter CLI and a C compiler. The package
-- lists install both on macOS and Linux; on Windows the compiler (Visual
-- Studio Build Tools, see docs/windows.md) is a manual step, and on a Linux whose
-- glibc is too old for the tree-sitter release the bootstrap leaves the CLI
-- out, so parsers count as skipped rather than missing there.
local M = {}
local tools = require("dotfiles.tools")

local function write(line)
  io.stdout:write(line, "\n")
end

-- The lockfile as lazy.nvim read it, before anything rewrites it.
local function locked()
  local lock = require("lazy.manage.lock")
  lock.load()
  return vim.deepcopy(lock.lock)
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

-- One line per pinned plugin: ok at the locked commit, missing, or stale at
-- another commit. Returns the number of plugins that are not ok.
local function report_plugins(snapshot)
  local plugins = require("lazy.core.config").plugins
  local git = require("lazy.manage.git")
  local names = vim.tbl_keys(snapshot)
  table.sort(names)
  local problems = 0
  for _, name in ipairs(names) do
    local plugin = plugins[name]
    local state = "missing"
    if plugin and plugin._.installed then
      local info = git.info(plugin.dir)
      state = (info and info.commit == snapshot[name].commit) and "ok" or "stale"
    end
    if state ~= "ok" then
      problems = problems + 1
    end
    write(state .. " plugin " .. name)
  end
  return problems
end

-- Install missing plugins at the commits lazy-lock.json pins and bring every
-- other plugin back to its pinned commit. lazy.nvim rewrites the lockfile
-- after each operation from what is installed, dropping plugins it has not
-- installed (a failed clone would unpin that plugin for the next run), so the
-- lock read at startup is put back before the restore and the file itself is
-- written back afterwards: this function never changes lazy-lock.json.
-- Without the lockfile option a plain install would clone branch heads and
-- pin those instead.
function M.plugins()
  -- Each pinned checkout would print git's detached-HEAD advice; lazy.nvim
  -- passes this environment to git. An entry is added after the user's own.
  local count = tonumber(vim.env.GIT_CONFIG_COUNT) or 0
  vim.env["GIT_CONFIG_KEY_" .. count] = "advice.detachedHead"
  vim.env["GIT_CONFIG_VALUE_" .. count] = "false"
  vim.env.GIT_CONFIG_COUNT = tostring(count + 1)
  local lockfile = require("lazy.core.config").options.lockfile
  local original = read_file(lockfile)
  local snapshot = locked()
  local manage = require("lazy.manage")
  local lock = require("lazy.manage.lock")
  manage.install({ wait = true, lockfile = true, show = false })
  lock.lock = vim.deepcopy(snapshot)
  lock._loaded = true
  manage.restore({ wait = true, show = false })
  if original and read_file(lockfile) ~= original then
    local handle = assert(io.open(lockfile, "wb"))
    handle:write(original)
    handle:close()
  end
  os.exit(report_plugins(snapshot) > 0 and 1 or 0)
end

local function parser_installed(lang)
  return #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".*", false) > 0
end

local function sorted_packages()
  local names = {}
  for _, name in pairs(tools.servers) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- Whether parsers can be compiled here. Only Windows is given the benefit of
-- the doubt: the MSVC toolchain is found through the Visual Studio installer
-- even when cl.exe is not on PATH.
function M.can_compile()
  if vim.fn.executable("tree-sitter") == 0 then
    return false
  end
  if vim.fn.has("win32") == 0 then
    return true
  end
  for _, compiler in ipairs({ "cl", "gcc", "clang", "cc" }) do
    if vim.fn.executable(compiler) == 1 then
      return true
    end
  end
  local program_files = vim.env["ProgramFiles(x86)"] or vim.env.ProgramFiles
  return program_files ~= nil
    and vim.uv.fs_stat(program_files .. "\\Microsoft Visual Studio\\Installer\\vswhere.exe") ~= nil
end

-- Parsers and packages that are not installed, as sorted lists. Parsers that
-- cannot be built on this machine are listed under `skipped` instead.
function M.missing()
  local missing = { parsers = {}, packages = {}, skipped = {} }
  local skip_parsers = not M.can_compile()
  for _, lang in ipairs(tools.parsers) do
    if not parser_installed(lang) then
      local list = skip_parsers and missing.skipped or missing.parsers
      list[#list + 1] = lang
    end
  end
  local ok, registry = pcall(require, "mason-registry")
  for _, name in ipairs(sorted_packages()) do
    if not (ok and registry.is_installed(name)) then
      missing.packages[#missing.packages + 1] = name
    end
  end
  return missing
end

local function report(missing)
  for _, lang in ipairs(tools.parsers) do
    if vim.tbl_contains(missing.parsers, lang) then
      write("missing parser " .. lang)
    elseif vim.tbl_contains(missing.skipped, lang) then
      write("skipped parser " .. lang .. " (no C compiler or tree-sitter CLI; see docs/troubleshooting.md)")
    else
      write("ok parser " .. lang)
    end
  end
  for _, name in ipairs(sorted_packages()) do
    write((vim.tbl_contains(missing.packages, name) and "missing package " or "ok package ") .. name)
  end
  return #missing.parsers + #missing.packages
end

function M.check()
  local problems = report_plugins(locked())
  os.exit(problems + report(M.missing()) > 0 and 1 or 0)
end

function M.install()
  local missing = M.missing()
  if #missing.parsers > 0 then
    write("Installing parsers: " .. table.concat(missing.parsers, " "))
    require("nvim-treesitter").install(missing.parsers):wait(10 * 60 * 1000)
    write("")
  end
  if #missing.packages > 0 then
    local registry = require("mason-registry")
    registry.refresh()
    for _, name in ipairs(missing.packages) do
      write("Installing package: " .. name)
      local handle = registry.get_package(name):install()
      vim.wait(10 * 60 * 1000, function()
        return handle:is_closed()
      end, 200)
    end
  end
  os.exit(report(M.missing()) > 0 and 1 or 0)
end

-- Brings the installed parsers to the revisions the pinned nvim-treesitter
-- names (they move only when lazy-lock.json moves the plugin) and every
-- installed Mason package from tools.lua to the registry's latest version.
-- The plugins stay where lazy-lock.json pins them. Prints a line per update,
-- then the report, and exits nonzero when an update failed or an item is
-- missing.
function M.update()
  local failed = 0
  if M.can_compile() then
    write("Updating parsers...")
    if not require("nvim-treesitter").update():wait(10 * 60 * 1000) then
      write("failed parser update")
      failed = failed + 1
    end
  end
  local registry = require("mason-registry")
  registry.refresh()
  for _, name in ipairs(sorted_packages()) do
    local pkg = registry.get_package(name)
    if pkg:is_installed() then
      local installed, latest = pkg:get_installed_version(), pkg:get_latest_version()
      if installed ~= latest then
        write(("Updating package: %s %s -> %s"):format(name, installed or "(unknown)", latest))
        local handle = pkg:install()
        vim.wait(10 * 60 * 1000, function()
          return handle:is_closed()
        end, 200)
        if pkg:get_installed_version() ~= latest then
          write("failed package " .. name)
          failed = failed + 1
        end
      end
    end
  end
  os.exit(failed + report(M.missing()) > 0 and 1 or 0)
end

return M
