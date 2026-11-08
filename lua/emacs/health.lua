-- :checkhealth emacs
local rpc = require("emacs.rpc")
local mirror = require("emacs.mirror")

local M = {}

local h = vim.health

local MIN_EMACS_MAJOR = 29

local function emacs_eval(expr)
  local cmd = { rpc.config.emacs, "-Q", "--batch" }
  if rpc.config.init then vim.list_extend(cmd, { "-l", vim.fn.expand(rpc.config.init) }) end
  vim.list_extend(cmd, { "--eval", "(princ " .. expr .. ")" })
  local out = vim.fn.system(cmd)
  return vim.v.shell_error == 0, vim.trim(out)
end

local function nvim_version()
  local v = vim.version()
  return ("%d.%d.%d"):format(v.major, v.minor, v.patch)
end

local function raw(keys) return vim.api.nvim_replace_termcodes(keys, true, true, true) end

-- Global mappings longer than a key org buffers send to Emacs and starting
-- with it ("<C-C><C-C>"): typed fast, both keys arrive together and the
-- longer mapping wins over the buffer's, <nowait> or not.
function M.shadowing_maps()
  local found = {}
  for mode, keys in pairs(mirror.config.keys) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      local lhs = raw(m.lhs)
      for _, key in ipairs(keys) do
        local ours = raw(key)
        if #lhs > #ours and vim.startswith(lhs, ours) then
          found[#found + 1] = ("%s %s"):format(mode, vim.fn.keytrans(lhs))
        end
      end
    end
  end
  return found
end

function M.check()
  h.start("org-bridge.nvim")
  if vim.fn.has("nvim-0.13") == 1 then
    h.ok("Neovim " .. nvim_version())
  else
    h.warn("Neovim " .. nvim_version() .. ": link brackets stay visible (conceal-aware wrap needs 0.13)")
  end
  if vim.fn.executable(rpc.config.emacs) == 0 then
    h.error(("`%s` is not on PATH"):format(rpc.config.emacs))
    return
  end
  local good, version = emacs_eval("emacs-version")
  if not good then
    h.error("Emacs failed to start" .. (rpc.config.init and " with your init file" or "") .. ":\n" .. version)
    return
  end
  local major = tonumber(version:match("^(%d+)"))
  if major and major >= MIN_EMACS_MAJOR then
    h.ok("Emacs " .. version)
  else
    h.error(("Emacs %s: need %d+"):format(version, MIN_EMACS_MAJOR))
  end
  local good_org, org = emacs_eval("(progn (require 'org) (org-version))")
  if good_org then h.ok("Org " .. org) else h.error("Org failed to load:\n" .. org) end
  if rpc.config.init then h.ok("init file loads: " .. rpc.config.init) end
  local shadowing = M.shadowing_maps()
  if #shadowing > 0 then
    h.warn("Global mappings take org keys typed quickly in org buffers; unmap them:\n" .. table.concat(shadowing, "\n"))
  end
  if rpc.running() then h.ok("bridge running") else h.ok("bridge not started yet (starts with the first org buffer)") end
end

return M
