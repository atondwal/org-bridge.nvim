-- Headless test runner: nvim --headless -u NONE -l test/run.lua [filter...]
-- (a test runs if its "file: name" contains any filter)
-- Each test/cases/*.lua returns { ["name"] = function(t) ... end }.
-- Expectations in test/cases are what the same keys produce in
-- `emacs -Q --batch -l test/init.el` (org 9.6.15, Emacs 29.3), unless a
-- case file says otherwise.
local ROOT = vim.fn.fnamemodify(arg[0], ":p:h:h")
vim.cmd("filetype on")
vim.opt.rtp:prepend(ROOT)
vim.o.swapfile = false
package.path = ROOT .. "/test/?.lua;" .. package.path

-- Longer than rpc's 20s startup timeout: Emacs starts inside the first test.
local WATCHDOG_MS = 30000

local WORK = os.getenv("EMACS_NVIM_TEST_DIR") or vim.fn.tempname()
vim.fn.mkdir(WORK, "p")
local rpc = require("emacs.rpc")
local emacs = require("emacs")
local mirror = require("emacs.mirror")
emacs.setup({ log = WORK .. "/emacs.log", init = ROOT .. "/test/init.el" })

-- Answer that makes the input request raise quit, as Escape/C-g would.
local QUIT = {}

-- Scripted answers for Emacs's input requests, consumed in order.
local answers = {}
local asked = {}
for _, method in ipairs({ "read_key", "read_string", "completing_read", "confirm" }) do
  rpc.handlers[method] = function(p)
    asked[#asked + 1] = { method = method, params = p }
    local a = table.remove(answers, 1)
    if a == nil then error("test: unexpected " .. method .. " " .. vim.inspect(p), 0) end
    if a == QUIT then error("quit", 0) end
    return a
  end
end

-- The handlers above, restored before each test.
local scripted = {}
for k, v in pairs(rpc.handlers) do scripted[k] = v end

local T = {}

function T.file(name, content)
  local path = WORK .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

function T.open(name, content)
  local path = T.file(name, content)
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  return path
end

function T.lines(buf) return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false) end

function T.cursor(line, col) vim.api.nvim_win_set_cursor(0, { line, col or 0 }) end

function T.keys(keys, count) emacs.exec({ keys = keys, count = count }) end

function T.command(cmd) emacs.exec({ command = cmd }) end

function T.answer(...) for _, a in ipairs({ ... }) do answers[#answers + 1] = a end end

function T.asked() return asked end

-- Closed fold ranges in the current window, as "first-last" strings.
function T.folds()
  local out, l, n = {}, 1, vim.fn.line("$")
  while l <= n do
    local fe = vim.fn.foldclosedend(l)
    if fe ~= -1 then
      out[#out + 1] = l .. "-" .. fe
      l = fe + 1
    else
      l = l + 1
    end
  end
  return out
end

function T.eq(got, want, what)
  if not vim.deep_equal(got, want) then
    error(("%s\n  want: %s\n  got:  %s"):format(what or "mismatch", vim.inspect(want), vim.inspect(got)), 2)
  end
end

function T.eval(expr) return emacs.eval(expr) end

local undo = {}
-- Run fn after the current test, pass or fail (latest first).
function T.after(fn) undo[#undo + 1] = fn end

-- Set an Emacs variable to an Elisp value for the rest of this test.
function T.set(var, value)
  local old = emacs.eval(("(prog1 (prin1-to-string %s) (setq %s %s))"):format(var, var, value))
  T.after(function() emacs.eval(("(setq %s (car (read-from-string %s)))"):format(var, old)) end)
end

-- Set a mirror.config key for the rest of this test.
function T.config(key, value)
  local old = mirror.config[key]
  mirror.config[key] = value
  T.after(function() mirror.config[key] = old end)
end

-- Emacs's copy of a buffer, given its file path or its buffer name.
function T.emacs_text(buffer)
  return vim.json.decode(emacs.eval(([[(with-current-buffer (or (get-file-buffer %q) (get-buffer %q))
    (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))]]):format(buffer, buffer)))
end

-- T.emacs_text split into lines like T.lines().
function T.emacs_lines(buffer)
  return vim.split((T.emacs_text(buffer):gsub("\n$", "")), "\n", { plain = true })
end

T.DOC = table.concat({ "* A", "body a", "** A1", "text", "* B", "body b", "" }, "\n")

-- head padded so its tags end at column 77 (org-tags-column -77).
function T.aligned(head, tags)
  return head .. string.rep(" ", math.max(1, 77 - #head - #tags)) .. tags
end

function T.feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- First line of buf (default current) matching pattern.
function T.find_line(pattern, buf)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)) do
    if l:find(pattern) then return i end
  end
end

function T.read_file(path)
  local f = assert(io.open(path))
  local s = f:read("a")
  f:close()
  return s
end

-- Stop the test and count it as skipped (a feature this Neovim lacks).
local SKIP = {}
function T.skip(reason) error(setmetatable({ reason = reason }, SKIP), 0) end

T.WORK = WORK
T.QUIT = QUIT

local filters = { unpack(arg) }
local passed, failed, skipped = 0, 0, 0
local files = vim.fn.glob(ROOT .. "/test/cases/*.lua", false, true)
for _, file in ipairs(files) do
  local cases = dofile(file)
  local names = vim.tbl_keys(cases)
  table.sort(names)
  for _, name in ipairs(names) do
    local full = vim.fn.fnamemodify(file, ":t:r") .. ": " .. name
    local selected = #filters == 0
    for _, f in ipairs(filters) do selected = selected or full:find(f, 1, true) ~= nil end
    if selected then
      answers, asked, undo = {}, {}, {}
      -- A test may replace a prompt handler; start each from the scripted ones.
      for k, v in pairs(scripted) do rpc.handlers[k] = v end
      vim.cmd("silent! %bwipeout!")
      -- A test may end in Insert or Visual mode (M-RET, C-c @ start them).
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "nx", false)
      local watchdog = vim.defer_fn(rpc.stop, WATCHDOG_MS)
      local ok, err = xpcall(cases[name], function(e)
        if getmetatable(e) == SKIP then return e end
        return debug.traceback(e, 2)
      end, T)
      watchdog:stop()
      for i = #undo, 1, -1 do undo[i]() end
      if ok and #answers > 0 then ok, err = false, "unused answers: " .. vim.inspect(answers) end
      if not ok and getmetatable(err) == SKIP then
        skipped = skipped + 1
        io.stdout:write("\nSKIP ", full, " (", err.reason, ")\n")
      elseif ok then
        passed = passed + 1
        io.stdout:write("\nPASS ", full, "\n")
      else
        failed = failed + 1
        io.stdout:write("\nFAIL ", full, "\n  ", tostring(err):gsub("\n", "\n  "), "\n")
      end
    end
  end
end
io.stdout:write(("%d passed, %d failed, %d skipped\n"):format(passed, failed, skipped))
rpc.stop()
vim.cmd(failed > 0 and "cquit" or "qall!")
