-- Runs require("dotfiles.bootstrap").update() against stand-ins for
-- mason-registry and nvim-treesitter, with no configuration and no network:
--
--   nvim -l tests/nvim_bootstrap_update.lua config/nvim
--
-- Each case sets up the registry and the parser update, then checks what
-- update() printed, installed and returned.
local config = assert(arg[1], "usage: nvim -l tests/nvim_bootstrap_update.lua <config/nvim>")
-- Neovim's require searches 'runtimepath' before package.path, and the
-- user's own configuration is on it: the one under test goes first.
vim.opt.runtimepath:prepend(config)

-- No parsers, so the report does not depend on what this Neovim bundles.
package.loaded["dotfiles.tools"] = {
  parsers = {},
  servers = { a = "pkg-a", b = "pkg-b", c = "pkg-c" },
}

local state

package.loaded["mason-registry"] = {
  refresh = function()
    state.refreshed = true
  end,
  is_installed = function(name)
    return state.packages[name].installed
  end,
  get_package = function(name)
    local pkg = state.packages[name]
    return {
      is_installed = function()
        return pkg.installed
      end,
      get_installed_version = function()
        return pkg.version
      end,
      get_latest_version = function()
        return pkg.latest
      end,
      install = function()
        state.installs[#state.installs + 1] = name
        if pkg.install_works ~= false then
          pkg.version = pkg.latest
        end
        return {
          is_closed = function()
            return true
          end,
        }
      end,
    }
  end,
}

package.loaded["nvim-treesitter"] = {
  update = function()
    state.parser_updates = state.parser_updates + 1
    return {
      wait = function()
        return state.parsers_ok
      end,
    }
  end,
}

local bootstrap = require("dotfiles.bootstrap")

local function current(version)
  return { installed = true, version = version, latest = version }
end

-- Runs update() and returns its exit status and output.
local function run(case)
  state = {
    packages = case.packages,
    installs = {},
    parser_updates = 0,
    parsers_ok = case.parsers_ok ~= false,
    refreshed = false,
  }
  bootstrap.can_compile = function()
    return case.compile ~= false
  end
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
  local ok, result = pcall(bootstrap.update)
  io.stdout, os.exit = stdout, exit
  if ok or type(result) ~= "table" then
    error("update() did not exit: " .. tostring(result))
  end
  return result.exit, table.concat(output)
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

case("current packages and parsers need nothing", function()
  local status, output = run({ packages = { ["pkg-a"] = current("1.0"), ["pkg-b"] = current("2.0"), ["pkg-c"] = current("3.0") } })
  expect(status == 0, "a current setup must pass", output)
  expect(state.refreshed, "the registry must be refreshed first", output)
  expect(#state.installs == 0, "nothing must be installed", output)
  expect(state.parser_updates == 1, "the parsers must be updated once", output)
  expect(not output:find("Updating package", 1, true), "no package update must be announced", output)
end)

case("a newer package version is installed", function()
  local packages = { ["pkg-a"] = current("1.0"), ["pkg-b"] = { installed = true, version = "2.0", latest = "2.1" }, ["pkg-c"] = current("3.0") }
  local status, output = run({ packages = packages })
  expect(status == 0, "an update that works must pass", output)
  expect(#state.installs == 1 and state.installs[1] == "pkg-b", "only the outdated package is installed", output)
  expect(output:find("Updating package: pkg-b 2.0 -> 2.1", 1, true), "the update is announced", output)
  expect(output:find("ok package pkg-b", 1, true), "the report confirms it", output)
end)

case("a failed package update fails the run and can be retried", function()
  local packages = {
    ["pkg-a"] = current("1.0"),
    ["pkg-b"] = current("2.0"),
    ["pkg-c"] = { installed = true, version = "3.0", latest = "3.1", install_works = false },
  }
  local status, output = run({ packages = packages })
  expect(status == 1, "a failed update must fail", output)
  expect(output:find("failed package pkg-c", 1, true), "the failure is named", output)
  packages["pkg-c"].install_works = true
  status, output = run({ packages = packages })
  expect(status == 0, "the retry must pass", output)
end)

case("a package that is not installed is left to install()", function()
  local status, output = run({
    packages = { ["pkg-a"] = { installed = false, latest = "1.0" }, ["pkg-b"] = current("2.0"), ["pkg-c"] = current("3.0") },
  })
  expect(status == 1, "a missing package must fail the report", output)
  expect(#state.installs == 0, "update() must not install it", output)
  expect(output:find("missing package pkg-a", 1, true), "the report names it", output)
end)

case("without a compiler the parsers are not updated", function()
  local status, output = run({ packages = { ["pkg-a"] = current("1.0"), ["pkg-b"] = current("2.0"), ["pkg-c"] = current("3.0") }, compile = false })
  expect(status == 0, "skipping the parsers must pass", output)
  expect(state.parser_updates == 0, "no parser update may run", output)
end)

case("a failed parser update fails the run", function()
  local status, output = run({ packages = { ["pkg-a"] = current("1.0"), ["pkg-b"] = current("2.0"), ["pkg-c"] = current("3.0") }, parsers_ok = false })
  expect(status == 1, "a failed parser update must fail", output)
  expect(output:find("failed parser update", 1, true), "the failure is named", output)
end)

io.stdout:write(cases, " update cases pass.\n")
