-- Sessions and multiple editors: :mksession, :%bwipeout and :source; a
-- second Neovim (with this plugin) writing the same org file; swap files.
-- Expected text: emacs -Q --batch -l test/init.el; else both sides agree.
local api = vim.api
local mirror = require("emacs.mirror")

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local NS = api.nvim_create_namespace("emacs")
local SECOND_TIMEOUT_MS = 20000

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

local function todo(t, lnum, key)
  t.cursor(lnum)
  t.answer(key or "t")
  t.keys("C-c C-t")
end

-- Lines inside closed Neovim folds, minus each fold's first (shown) line.
local function vim_hidden()
  local out = {}
  for l = 1, vim.fn.line("$") do
    local fs = vim.fn.foldclosed(l)
    if fs ~= -1 and fs ~= l then out[#out + 1] = l end
  end
  return out
end

local HIDDEN_EXPR = [[(with-current-buffer (get-file-buffer %q)
  (save-excursion (goto-char (point-min))
    (let ((n 1) out)
      (while (not (eobp))
        (when (invisible-p (point)) (push n out))
        (forward-line 1) (setq n (1+ n)))
      (concat "[" (mapconcat #'number-to-string (nreverse out) ",") "]"))))]]

local function emacs_hidden(t, path) return vim.json.decode(vim.json.decode(t.eval(HIDDEN_EXPR:format(path)))) end

local function emacs_has(t, path) return t.eval(("(and (get-file-buffer %q) t)"):format(path)) == "t" end

-- :mksession!, :%bwipeout!, :source: the round trip a restart makes.
local function session_round_trip(t)
  local session = t.WORK .. "/session.vim"
  vim.cmd("mksession! " .. vim.fn.fnameescape(session))
  vim.cmd("silent %bwipeout!")
  vim.cmd("silent source " .. vim.fn.fnameescape(session))
end

-- Swap files under t.WORK for the rest of the test (the runner turns
-- them off; -l also zeroes 'updatecount', which stops swap creation).
local function swap_on(t)
  local old = { vim.o.swapfile, vim.o.updatecount, vim.o.directory }
  local dir = t.WORK .. "/swap"
  vim.fn.mkdir(dir, "p")
  vim.o.swapfile, vim.o.updatecount, vim.o.directory = true, 200, dir .. "//"
  t.after(function() vim.o.swapfile, vim.o.updatecount, vim.o.directory = old[1], old[2], old[3] end)
  return dir
end

-- The second editor: opens arg[2] with this plugin (E325 caught), runs
-- C-c C-t <arg[4]> on line arg[3], :w!, and reports to arg[5] as JSON.
local SECOND = [[
local root, file, lnum, key, out = arg[1], arg[2], tonumber(arg[3]), arg[4], arg[5]
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.o.swapfile, vim.o.updatecount, vim.o.directory = true, 200, vim.fn.fnamemodify(out, ":h") .. "/swap//"
local rpc = require("emacs.rpc")
local emacs = require("emacs")
emacs.setup({ log = out .. ".log", init = root .. "/test/init.el" })
rpc.handlers.read_key = function() return key end
local report = {}
local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(file))
report.edit_error = not ok and tostring(err) or nil
report.attached = require("emacs.mirror").id(vim.api.nvim_get_current_buf()) ~= nil
report.readonly = vim.bo.readonly
if report.attached then
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  emacs.exec({ keys = "C-c C-t" })
  report.lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  report.emacs = vim.json.decode(emacs.eval("(buffer-substring-no-properties (point-min) (point-max))"))
end
ok, err = pcall(vim.cmd, "silent write!")
report.write_error = not ok and tostring(err) or nil
local f = assert(io.open(out, "w"))
f:write(vim.json.encode(report))
f:close()
vim.cmd("qa!")
]]

-- Kill pid's children, then pid: only processes this test started.
local function kill_tree(pid)
  for _, child in ipairs(vim.fn.systemlist({ "ps", "-o", "pid=", "--ppid", tostring(pid) })) do
    vim.loop.kill(tonumber(child), 9)
  end
  vim.loop.kill(pid, 9)
end

-- Neovim's state and data under t.WORK, so neither editor writes into ~.
local function child_env(t)
  local env = {}
  for _, k in ipairs({ "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME" }) do
    env[k] = t.WORK .. "/xdg/" .. k
  end
  return env
end

-- Run the second editor on path; returns its report. Fails if it hangs.
local function second_editor(t, path, lnum, key)
  local script = t.file("second.lua", SECOND)
  local out = t.WORK .. "/second.json"
  os.remove(out)
  local output = {}
  local function collect(_, data) vim.list_extend(output, data) end
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script,
    ROOT, path, tostring(lnum), key, out }, { env = child_env(t), on_stdout = collect, on_stderr = collect })
  local pid = vim.fn.jobpid(job)
  local status = vim.fn.jobwait({ job }, SECOND_TIMEOUT_MS)[1]
  if status == -1 then
    kill_tree(pid)
    error("second editor hung: " .. table.concat(output, "\n"))
  end
  if vim.fn.filereadable(out) == 0 then error("second editor exited " .. status .. ": " .. table.concat(output, "\n")) end
  return vim.json.decode(t.read_file(out))
end

-- A swap file for path left by a Neovim that died with unsaved changes:
-- the next editor of path gets E325 ATTENTION.
local function stale_swap(t, path)
  local dir = t.WORK .. "/swap"
  vim.fn.mkdir(dir, "p")
  local script = t.file("holder.lua", ([[
vim.o.swapfile, vim.o.updatecount, vim.o.directory = true, 200, %q
vim.cmd("edit " .. vim.fn.fnameescape(%q))
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved" })
vim.cmd("preserve")
io.stdout:write("preserved\n")
vim.wait(60000)
]]):format(dir .. "//", path))
  local ready = false
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script },
    { env = child_env(t), on_stdout = function(_, d) ready = ready or table.concat(d):find("preserved") ~= nil end })
  local pid = vim.fn.jobpid(job)
  local got = vim.wait(10000, function() return ready end, 20)
  kill_tree(pid)
  vim.fn.jobwait({ job }, 2000)
  assert(got, "holder preserved its swap")
  local swaps = vim.fn.glob(dir .. "/*" .. vim.fn.fnamemodify(path, ":t") .. ".sw?", false, true)
  t.after(function() for _, s in ipairs(swaps) do os.remove(s) end end)
  assert(#swaps == 1, "one stale swap file")
end

return {
  -- Emacs: the reopened buffer is a fresh visit; C-c C-t t on * B gives TODO B.
  ["after :mksession, :%bwipeout and :source, the buffer is mirrored again"] = function(t)
    local path = t.open("sess_basic.org", t.DOC)
    t.cursor(5)
    session_round_trip(t)
    t.eq(emacs_has(t, path), true, "Emacs visits the file again")
    t.eq(vim.fn.line("."), 5, "cursor restored")
    todo(t, 5)
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  [":%bwipeout! kills Emacs's copies of every org buffer"] = function(t)
    local a = t.open("wipe_a.org", t.DOC)
    local b = t.open("wipe_b.org", "* X\n")
    vim.cmd("silent %bwipeout!")
    t.eq({ emacs_has(t, a), emacs_has(t, b) }, { false, false })
  end,

  -- Emacs: the second file, visited after the restore, takes C-c C-t t.
  ["a session's other org buffer attaches when first shown"] = function(t)
    local a = t.open("sess_a.org", t.DOC)
    local b = t.open("sess_b.org", "* X\n* Y\n")
    vim.cmd("silent buffer " .. vim.fn.bufnr(a))
    session_round_trip(t)
    vim.cmd("silent buffer " .. vim.fn.bufnr(b))
    todo(t, 2)
    t.eq(t.lines(), { "* X", "* TODO Y" })
    agree(t, b)
    vim.cmd("silent buffer " .. vim.fn.bufnr(a))
    agree(t, a, "first file")
  end,

  -- The session closes the fold TAB made; Emacs must hide the same lines.
  ["a subtree folded before :mksession shows the same folds in both after :source"] = function(t)
    local path = t.open("sess_fold.org", t.DOC)
    t.cursor(1)
    t.keys("TAB")
    t.eq(vim_hidden(), { 2, 3, 4 }, "TAB folded A")
    session_round_trip(t)
    t.eq(vim_hidden(), emacs_hidden(t, path), "Emacs hides what Neovim hides")
    agree(t, path)
  end,

  -- As with Emacs's desktop, the restored buffer has a reopened file's
  -- folds (none here), so TAB on * A folds it, in both.
  ["TAB after :source acts on the folds the buffer shows"] = function(t)
    local path = t.open("sess_fold_tab.org", t.DOC)
    t.cursor(1)
    t.keys("TAB")
    session_round_trip(t)
    t.eq(vim_hidden(), {}, "restored open")
    t.cursor(1)
    t.keys("TAB")
    t.eq(vim_hidden(), { 2, 3, 4 }, "Neovim")
    t.eq(emacs_hidden(t, path), { 2, 3, 4 }, "Emacs")
    agree(t, path)
  end,

  ["Emacs's highlights come back after :source"] = function(t)
    t.open("sess_hl.org", t.DOC)
    local function marks() return #api.nvim_buf_get_extmarks(0, NS, { 0, 0 }, { 0, -1 }, {}) end
    t.eq(marks() > 0, true, "heading highlighted before")
    session_round_trip(t)
    vim.cmd("redraw")
    t.eq(marks() > 0, true, "heading highlighted after")
  end,

  -- Emacs: revert-buffer after the other editor's save, then C-c C-t t on
  -- * A; C-x C-s writes both changes.
  ["another Neovim's org edit, then :checktime and an org command here"] = function(t)
    swap_on(t)
    local path = t.open("two_editors.org", t.DOC)
    vim.o.autoread = true
    t.after(function() vim.o.autoread = false end)
    local r = second_editor(t, path, 5, "t")
    t.eq(r.attached, true, "second editor attached despite our swap file")
    t.eq(r.lines, r.emacs and vim.split(r.emacs:gsub("\n$", ""), "\n") or nil, "second editor's Emacs agrees")
    t.eq(t.read_file(path), "* A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "second editor wrote")
    vim.cmd("checktime")
    t.eq(t.lines()[5], "* TODO B", "reloaded")
    todo(t, 1)
    t.eq(t.lines(), { "* TODO A", "body a", "** A1", "text", "* TODO B", "body b" })
    agree(t, path)
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* TODO A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "file on disk")
  end,

  -- Emacs: revert-buffer discards the unsaved TODO A for the disk text.
  ["a reload chosen in FileChangedShell drops our unsaved org change in both"] = function(t)
    local path = t.open("conflict.org", t.DOC)
    todo(t, 1)
    local r = second_editor(t, path, 5, "d")
    t.eq(r.lines and r.lines[5], "* DONE B", "second editor's change")
    local au = api.nvim_create_autocmd("FileChangedShell", {
      callback = function() vim.v.fcs_choice = "reload" end,
    })
    t.after(function() api.nvim_del_autocmd(au) end)
    vim.cmd("checktime")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* DONE B", "body b" })
    agree(t, path)
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(path)), "nil", "Emacs unmodified")
    todo(t, 1)
    t.eq(t.lines()[1], "* TODO A")
    agree(t, path, "after C-c C-t")
  end,

  -- A crashed editor's swap file: the second editor gets E325, and must
  -- still attach, run the org command and write instead of hanging.
  ["the second editor gets E325 on a stale swap file and still finishes"] = function(t)
    local path = t.file("stale_second.org", t.DOC)
    stale_swap(t, path)
    local r = second_editor(t, path, 5, "t")
    t.eq(r.edit_error ~= nil and r.edit_error:find("E325") ~= nil, true, "E325 raised")
    t.eq(r.attached, true, "attached")
    t.eq(r.lines, vim.split(r.emacs:gsub("\n$", ""), "\n"), "its Emacs agrees")
    t.eq(r.write_error, nil, ":w! wrote")
    t.eq(t.read_file(path), "* A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "file on disk")
  end,

  -- Emacs: the agenda's t d marks the task DONE in its file buffer. Here
  -- Neovim loads that file for Emacs mid-command, over a stale swap file.
  ["the agenda's t d on a file with a stale swap file survives the E325"] = function(t)
    swap_on(t)
    local path = t.file("stale_agenda.org", "* TODO Call Bob\n")
    stale_swap(t, path)
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    t.after(function() t.eval("(setq org-agenda-files nil)") end)
    t.open("stale_other.org", "* B\n")
    t.answer("t")
    t.command("org-agenda")
    t.cursor(t.find_line("Call Bob"))
    t.answer("d")
    api.nvim_feedkeys("t", "x", false)
    vim.cmd("only")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(path))
    t.eq(t.lines(), { "* DONE Call Bob" })
    agree(t, path)
  end,
}
