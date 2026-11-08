-- A long random session over several files, the agenda and capture: every
-- step checks both sides hold the same text; every 100 steps logs time
-- and resource use to soak.tsv, so leaks and slowdowns show as trends.
--   nvim --headless -u NONE -l test/soak.lua [seed] [steps]
local ROOT = vim.fn.fnamemodify(arg[0], ":p:h:h")
vim.cmd("filetype on")
vim.opt.rtp:prepend(ROOT)
vim.o.swapfile = false
vim.o.hidden = true

local SEED = tonumber(arg[1]) or os.time()
local STEPS = tonumber(arg[2]) or 1000
local FILES_N, HEADINGS = 3, 15
local LOG_EVERY = 100
math.randomseed(SEED)

local WORK = os.getenv("SOAK_DIR") or vim.fn.tempname()
vim.fn.mkdir(WORK, "p")
local rpc, mirror, emacs = require("emacs.rpc"), require("emacs.mirror"), require("emacs")
emacs.setup({ log = WORK .. "/emacs.log", init = ROOT .. "/test/init.el" })

-- Prompts get plausible answers instead of a script.
rpc.handlers.read_key = function() return ({ "t", "n", "d", "q", "a" })[math.random(5)] end
rpc.handlers.read_string = function() return ({ "", "1", "x", "+1d" })[math.random(4)] end
rpc.handlers.completing_read = function() return "" end
rpc.handlers.confirm = function() return math.random() < 0.5 end

local FILES = {}
for i = 1, FILES_N do
  FILES[i] = ("%s/s%d.org"):format(WORK, i)
  local lines = {}
  for h = 1, HEADINGS do
    lines[#lines + 1] = ("* %sTask %d-%d :t%d:"):format(h % 3 == 0 and "TODO " or "", i, h, h % 4)
    if h % 4 == 0 then lines[#lines + 1] = ("SCHEDULED: <2026-11-0%d>"):format(h % 7 + 1) end
    lines[#lines + 1] = "body " .. h
    if h % 5 == 0 then lines[#lines + 1] = ("| a | %d |"):format(h) end
  end
  vim.fn.writefile(lines, FILES[i])
end
emacs.eval(("(setq org-agenda-files '(%s) org-capture-templates '((\"t\" \"T\" entry (file %q) \"* TODO %%?\")))")
  :format(table.concat(vim.tbl_map(function(f) return ("%q"):format(f) end, FILES), " "), FILES[1]))
vim.cmd("silent edit " .. FILES[1])

-- What each step did, for the report when the texts part.
local history = {}
local function note(what)
  history[#history + 1] = ("%s %s:%d"):format(what, vim.fn.expand("%:t"), vim.api.nvim_win_get_cursor(0)[1])
end

local function in_file() return vim.api.nvim_buf_get_name(0):match("/s%d%.org$") ~= nil end
local function random_line() vim.api.nvim_win_set_cursor(0, { math.random(vim.api.nvim_buf_line_count(0)), 0 }) end

local KEYS = { "TAB", "<backtab>", "M-RET", "<M-up>", "<M-down>", "C-c C-t", "<S-right>", "<S-up>",
  "C-c C-c", "C-c -", "C-c ,", "<M-S-right>", "<M-left>" }
local VIM = { "dd", "yyp", "J", "x", "ix\27", "Anew\27", "u", "\18" }

-- { weight, op }; an op returns nothing and may raise (org's user errors).
local OPS = {
  { 30, function()
    if not in_file() then return end
    random_line()
    local key = KEYS[math.random(#KEYS)]
    note("emacs " .. key)
    emacs.exec({ keys = key })
  end },
  { 30, function()
    if not in_file() then return end
    random_line()
    local keys = VIM[math.random(#VIM)]
    note("vim " .. vim.fn.keytrans(keys))
    vim.cmd("silent! normal! " .. keys)
  end },
  -- A modified special buffer (capture) refuses :edit (E37): skip then.
  { 8, function() vim.cmd("silent! edit " .. FILES[math.random(FILES_N)]); note("edit") end },
  { 5, function()
    if #vim.api.nvim_tabpage_list_wins(0) < 3 then vim.cmd("split " .. FILES[math.random(FILES_N)]) else vim.cmd("close") end
    note("split/close")
  end },
  { 6, function()
    emacs.exec({ command = "org-agenda", pending = { "a" } })
    if not vim.api.nvim_buf_get_name(0):find("Agenda") then return end
    for _ = 1, math.random(3) do
      vim.cmd("normal! " .. math.random(2, 8) .. "G")
      local key = ({ "t", "n", "p", "r" })[math.random(4)]
      note("agenda " .. key)
      emacs.exec({ keys = key })
    end
    emacs.exec({ keys = "q" })
  end },
  { 5, function()
    emacs.exec({ command = "org-capture", pending = { "t" } })
    if not vim.api.nvim_buf_get_name(0):find("CAPTURE") then return end
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "* TODO captured " .. math.random(1000) })
    local key = math.random() < 0.7 and "C-c C-c" or "C-c C-k"
    note("capture " .. key)
    emacs.exec({ keys = key })
  end },
  { 3, function() note("save all"); emacs.exec({ command = "org-save-all-org-buffers" }) end },
}
local TOTAL = 0
for _, o in ipairs(OPS) do TOTAL = TOTAL + o[1] end
local function pick()
  local r = math.random(TOTAL)
  for _, o in ipairs(OPS) do
    r = r - o[1]
    if r <= 0 then return o[2] end
  end
end

-- The first file whose texts differ, or nil.
local function desynced()
  mirror.sync()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b):match("/(s%d%.org)$")
    if name and vim.api.nvim_buf_is_loaded(b) then
      local et = vim.json.decode(emacs.eval(("(with-current-buffer %q (save-restriction (widen) (buffer-substring-no-properties 1 (point-max))))"):format(name)))
      local empty = vim.api.nvim_buf_call(b, function() return vim.fn.wordcount().bytes == 0 end)
      local nt = empty and "" or table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") .. (vim.bo[b].eol and "\n" or "")
      if et ~= nt then
        vim.fn.writefile(vim.split(et, "\n"), WORK .. "/emacs.txt")
        vim.fn.writefile(vim.split(nt, "\n"), WORK .. "/nvim.txt")
        return name
      end
    end
  end
end

local function extmarks()
  local n = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    for _, ns in pairs(vim.api.nvim_get_namespaces()) do n = n + #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) end
  end
  return n
end

local log = assert(io.open(WORK .. "/soak.tsv", "w"))
log:write("step\tms_per_step\temacs_buffers\tnvim_windows\textmarks\tlua_kb\n")
local start, errors, failed = vim.loop.hrtime(), 0, nil
for step = 1, STEPS do
  if not pcall(pick()) then errors = errors + 1 end
  vim.cmd("silent! normal! \27")
  local bad = desynced()
  if bad then
    failed = ("step %d: %s differs (texts in %s/emacs.txt, nvim.txt); last steps:\n  %s"):format(
      step, bad, WORK, table.concat(vim.list_slice(history, #history - 19), "\n  "))
    break
  end
  if step % LOG_EVERY == 0 then
    local now = vim.loop.hrtime()
    log:write(("%d\t%.1f\t%s\t%d\t%d\t%d\n"):format(step, (now - start) / 1e6 / LOG_EVERY,
      emacs.eval("(length (buffer-list))"), #vim.api.nvim_list_wins(), extmarks(), collectgarbage("count")))
    log:flush()
    start = now
  end
end
log:close()
io.stdout:write(failed and ("SOAK FAIL seed=%d %s\n"):format(SEED, failed)
  or ("SOAK OK seed=%d steps=%d (op errors %d; log %s/soak.tsv)\n"):format(SEED, STEPS, errors, WORK))
rpc.stop()
vim.cmd(failed and "cquit" or "qall!")
