--design choices
--* no stdio with external formatting programs
--* run formatting programs by order, crashes should not make the original buffer dirty
--* assume all formatting programs format in-place
--* it should blocks user input during formatting
--* it should not block the nvim processes

local M = {}

local cthulhu = require("cthulhu")
local buflines = require("infra.buflines")
local BufTickRegulator = require("infra.BufTickRegulator")
local ctx = require("infra.ctx")
local dictlib = require("infra.dictlib")
local ex = require("infra.ex")
local fs = require("infra.fs")
local itertools = require("infra.itertools")
local its = require("infra.its")
local iuv = require("infra.iuv")
local jelly = require("infra.jellyfish")("sculptor", "info")
local listlib = require("infra.listlib")
local mi = require("infra.mi")
local prefer = require("infra.prefer")
local project = require("infra.project")
local subprocess = require("infra.subprocess")

local resolve_stylua_config
do
  local function find(root)
    if root == nil then return end
    for _, basename in ipairs({ "stylua.toml", ".stylua.toml" }) do
      local fpath = fs.joinpath(root, basename)
      if fs.file_exists(fpath) then return fpath end
    end
  end

  local function resolve() return find(project.git_root()) or find(project.working_root()) or find(mi.stdpath("config")) end

  local found
  ---@return string?
  function resolve_stylua_config()
    if not found then found = resolve() end
    return found
  end
end

---@class sculptor.RunSpec
---@field bin string
---@field args string[]
---@field normal_exit integer

---@alias sculptor.Program fun(fpath:string):nil|sculptor.RunSpec

-- all formatting programs should modify the file inplace
---@type {[string]:sculptor.Program}
local programs = {
  zig = function(fpath) --
    return { bin = "zig", args = { "fmt", "--ast-check", fpath }, normal_exit = 0 }
  end,
  stylua = function(fpath)
    local conf = resolve_stylua_config()
    if conf == nil then return jelly.warn("no stylua config file found") end
    return { bin = "stylua", args = { "--config-path", conf, fpath }, normal_exit = 0 }
  end,
  isort = function(fpath) --
    return { bin = "isort", args = { "--quiet", "--profile", "black", fpath }, normal_exit = 0 }
  end,
  black = function(fpath) --
    return { bin = "black", args = { "--quiet", "--target-version", "py310", "--line-length", "256", fpath }, normal_exit = 0 }
  end,
  go = function(fpath) --
    return { bin = "gofmt", args = { "-w", fpath }, normal_exit = 0 }
  end,
  ["clang-format"] = function(fpath) --
    return { bin = "clang-format", args = { "-i", fpath }, normal_exit = 0 }
  end,
  gomodifytags = function(fpath) --
    return { bin = "gomodifytags", args = { "-all", "-add-tags", "json", "-w", "-file", fpath }, normal_exit = 0 }
  end,
  ["fish-indent"] = function(fpath) --
    return { bin = "fish_indent", args = { "-w", fpath }, normal_exit = 0 }
  end,
}

--{ft: {profile: [program]}}
---@type {[string]:{[string]:sculptor.Program[]}}
local profiles = (function(specs)
  local result = {}
  for ft, profile_name, prog_names in itertools.itern(specs) do
    if result[ft] == nil then result[ft] = {} end
    if result[ft][profile_name] ~= nil then error("duplicate definitions for profile " .. profile_name) end
    result[ft][profile_name] = its(prog_names):map(function(name) return assert(programs[name]) end):tolist()
  end
  return result
end)({
  { "lua", "default", { "stylua" } },
  { "zig", "default", { "zig" } },
  { "python", "default", { "isort", "black" } },
  { "go", "default", { "go" } },
  { "go", "jsontags", { "gomodifytags" } },
  { "c", "default", { "clang-format" } },
  { "fish", "default", { "fish-indent" } },
})

---@param specs sculptor.RunSpec[]
---@param on_exit fun() @will be run in vim.schedule()
local function serially_run(specs, on_exit) --
  assert(#specs > 0)

  ---@type fun(): sculptor.RunSpec?
  local iter = itertools.iter(specs)

  local function next()
    ---@type sculptor.RunSpec?
    local spec = iter()
    if spec == nil then return vim.schedule(on_exit) end
    subprocess.spawn(spec.bin, { args = spec.args }, function() end, function(exit_code)
      if exit_code ~= spec.normal_exit then return jelly.warn("failed to run: %s %s", spec.bin, spec.args) end
      next()
    end)
  end

  next()
end

local diffpatch
do
  ---ref: https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html

  ---@alias sculptor.DiffHunk [integer,integer,integer,integer]

  ---@param a_bufnr integer
  ---@param b_lines string[]
  ---@param hunks sculptor.DiffHunk[]
  local function patch(a_bufnr, b_lines, hunks)
    local offset = 0
    for start_a, count_a, start_b, count_b in itertools.itern(hunks) do
      assert(not (count_a == 0 and count_b == 0))

      local lines
      if count_b == 0 then
        lines = {}
      else
        local start = start_b - 1
        lines = listlib.slice(b_lines, start, start + count_b)
      end

      do
        local start, stop
        if count_a == 0 then -- append
          start = start_a - 1 + offset + 1
          stop = start
        elseif count_b == 0 then -- delete
          start = start_a - 1 + offset
          stop = start + count_a
        else
          start = start_a - 1 + offset
          stop = start + count_a
        end
        buflines.sets(a_bufnr, start, stop, lines)
      end

      offset = offset + (count_b - count_a)
    end
  end

  ---@param a_bufnr integer
  ---@param b_path string
  function diffpatch(a_bufnr, b_path)
    local b_lines = itertools.tolist(io.lines(b_path))

    local hunks
    do
      local a = buflines.joined(a_bufnr)
      local b = table.concat(b_lines, "\n")
      ---@type sculptor.DiffHunk
      ---@diagnostic disable-next-line: missing-fields
      hunks = vim.diff(a, b, { result_type = "indices" })
      if #hunks == 0 then return jelly.debug("no need to patch") end
    end

    ctx.bufviews(a_bufnr, function()
      ctx.undoblock(a_bufnr, function() patch(a_bufnr, b_lines, hunks) end)
    end)
  end
end

local regulator = BufTickRegulator(1024)

---@param bufnr? integer
---@param ft? string
---@param profile? string
function M.sculpt(bufnr, ft, profile)
  bufnr = mi.resolve_bufnr_param(bufnr)
  ft = ft or prefer.bo(bufnr, "filetype")
  profile = profile or "default"

  if regulator:throttled(bufnr) then return jelly.debug("no change") end
  regulator:update(bufnr) --avoid other sculptor running

  ---@type sculptor.Program[]
  local progs = dictlib.get(profiles, ft, profile) or {}
  jelly.info("using ft=%s, profile=%s, bufnr=%d, progs=%d", ft, profile, bufnr, #progs)
  if #progs == 0 then return jelly.warn("no preset formatting programs") end

  --prepare tmpfile
  local tmpfile = os.tmpname()
  if not cthulhu.nvim.dump_buffer(bufnr, tmpfile) then return jelly.err("failed to dump buf#%d", bufnr) end

  local function sync()
    if not regulator:throttled(bufnr) then
      jelly.warn("buf=%s changed while sculpting", bufnr)
    else
      diffpatch(bufnr, tmpfile)
      ctx.buf(bufnr, function() ex.eval("silent write") end)
      regulator:update(bufnr)
    end
    iuv.fs_unlink(tmpfile)
  end

  --progs pipeline against tmpfile
  local specs = {}
  for _, prog in ipairs(progs) do
    local spec = prog(tmpfile)
    if spec then table.insert(specs, spec) end
  end
  if #specs == 0 then return jelly.warn("no available formatting programs") end
  serially_run(specs, sync)
end

M.comp = {
  ---@param ft string @filetype
  ---@return string[]
  available_profiles = function(ft)
    local avails = profiles[ft]
    if avails == nil then return {} end
    return dictlib.keys(avails)
  end,
}

return M
