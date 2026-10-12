-- Offline check of the Neovim configuration, run by scripts/test.sh as
--   nvim -l tests/nvim_check.lua config/nvim
-- `nvim -l` loads no user configuration and needs no plugins. Every Lua file
-- must parse; every plugin file under lua/plugins/ must return lazy.nvim
-- specs whose plugins (dependencies included) are exactly the entries of
-- lazy-lock.json, so a stale lockfile fails before a machine installs from it.
local config_dir = arg[1]
if not config_dir then
  io.stderr:write("usage: nvim -l tests/nvim_check.lua <config directory>\n")
  os.exit(2)
end

local failures = 0
local function fail(message)
  io.stderr:write(message, "\n")
  failures = failures + 1
end

local lua_files = vim.fn.globpath(config_dir, "**/*.lua", true, true)
table.sort(lua_files)
if #lua_files == 0 then
  fail(config_dir .. " contains no Lua files")
end
for _, path in ipairs(lua_files) do
  local chunk, err = loadfile(path)
  if not chunk then
    fail(err)
  end
end

-- lazy.nvim names a plugin after the last path component of its short URL
-- unless the spec sets `name`.
local declared = { ["lazy.nvim"] = true }
-- A dependency may name a plugin that another file declares in full.
local function collect(spec, origin, is_dependency)
  if type(spec) == "string" then
    spec = { spec }
  end
  if type(spec) ~= "table" then
    fail(origin .. ": a plugin spec must be a table, got " .. type(spec))
    return
  end
  if spec.import then
    return
  end
  local short = spec[1]
  if type(short) ~= "string" then
    fail(origin .. ": a plugin spec must start with its 'owner/repo' string")
    return
  end
  local name = spec.name or short:match("([^/]+)$")
  if not name or name == "" then
    fail(origin .. ": cannot derive a plugin name from '" .. short .. "'")
    return
  end
  if declared[name] and not is_dependency and #vim.tbl_keys(spec) > 1 then
    fail(origin .. ": plugin '" .. name .. "' is declared twice")
  end
  declared[name] = true
  for _, field in ipairs({ "config", "init", "build", "opts", "keys", "dependencies" }) do
    local value = spec[field]
    if value ~= nil then
      local ok = type(value) == "function" or type(value) == "table" or type(value) == "string"
      if field == "build" or field == "config" then
        ok = type(value) == "function" or type(value) == "string" or type(value) == "boolean"
      end
      if not ok then
        fail(origin .. ": '" .. name .. "' has an unexpected type for " .. field)
      end
    end
  end
  for _, dependency in ipairs(spec.dependencies or {}) do
    collect(dependency, origin, true)
  end
end

local plugin_files = vim.fn.globpath(config_dir .. "/lua/plugins", "*.lua", true, true)
table.sort(plugin_files)
if #plugin_files == 0 then
  fail(config_dir .. "/lua/plugins contains no plugin files")
end
for _, path in ipairs(plugin_files) do
  local ok, result = pcall(dofile, path)
  if not ok then
    fail(path .. ": " .. tostring(result))
  elseif type(result) ~= "table" then
    fail(path .. ": must return a plugin spec or a list of specs")
  elseif type(result[1]) == "string" then
    collect(result, path)
  else
    for _, spec in ipairs(result) do
      collect(spec, path)
    end
  end
end

local lockfile = config_dir .. "/lazy-lock.json"
local handle = io.open(lockfile, "r")
if not handle then
  fail(lockfile .. " is missing; run :Lazy restore and commit it")
else
  local content = handle:read("*a")
  handle:close()
  local ok, locked = pcall(vim.json.decode, content)
  if not ok or type(locked) ~= "table" then
    fail(lockfile .. " is not valid JSON")
  else
    for name in pairs(declared) do
      if not locked[name] then
        fail(lockfile .. " lacks the declared plugin '" .. name .. "'; run :Lazy install and commit the lockfile")
      end
    end
    local names = {}
    for name, entry in pairs(locked) do
      if not declared[name] then
        fail(lockfile .. " pins '" .. name .. "', which no plugin file declares; run :Lazy clean and commit the lockfile")
      end
      if type(entry) ~= "table" or type(entry.commit) ~= "string" or entry.commit == "" then
        fail(lockfile .. ": '" .. name .. "' has no commit")
      end
      names[#names + 1] = name
    end
    io.stdout:write(("%d Lua files parse; %d plugins pinned.\n"):format(#lua_files, #names))
  end
end

if failures > 0 then
  io.stderr:write(("%d Neovim configuration problem(s).\n"):format(failures))
  os.exit(1)
end
