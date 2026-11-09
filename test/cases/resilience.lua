-- Failure handling: Emacs killed mid-session or mid-command, :EmacsRestart
-- with unsaved edits, interrupting a runaway :EmacsEval, a broken init file,
-- stray stdout/stderr output, and commands that fail after editing.
local api = vim.api
local uv = vim.loop
local rpc = require("emacs.rpc")
local mirror = require("emacs.mirror")

local DOC_LINES = { "* A", "body a", "** A1", "text", "* B", "body b" }
-- Longest a C-c may take to get Neovim back; a person gives up after this.
local INTERRUPT_MS = 4000
-- After this a runaway Emacs is killed so the test ends well before the watchdog.
local RESCUE_MS = 8000

local function agree(t, path, what) t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees") end

local function emacs_pid(t) return tonumber(t.eval("(emacs-pid)")) end

local function kill_emacs(t)
  local pid = emacs_pid(t)
  uv.kill(pid, 9)
  assert(vim.wait(5000, function() return not rpc.running() end, 10), "Emacs still running")
  return pid
end

local function alive(pid) return uv.kill(pid, 0) == 0 end

-- Run fn while a timer presses C-c after `after_ms`; if Emacs is still busy
-- at RESCUE_MS, kill it. Returns pcall's results, the elapsed ms and
-- whether the rescue had to kill Emacs.
local function interrupted(t, after_ms, fn)
  local pid = emacs_pid(t)
  local rescued = false
  local press, rescue = uv.new_timer(), uv.new_timer()
  press:start(after_ms, 0, function() api.nvim_input("<C-c>") end)
  rescue:start(RESCUE_MS, 0, function()
    if alive(pid) then rescued = true; uv.kill(pid, 9) end
  end)
  local start = uv.hrtime()
  local ok, err = pcall(fn)
  local ms = (uv.hrtime() - start) / 1e6
  press:close()
  rescue:close()
  return ok, err, ms, rescued
end

-- Restart Emacs with `init` as the user's init file; the test's own init
-- comes back afterwards.
local function restart_with_init(t, init)
  local old = rpc.config.init
  rpc.config.init = init
  t.after(function()
    rpc.config.init = old
    rpc.stop()
  end)
  rpc.stop()
end

-- Neovim's message history, one entry per line.
local function messages() return vim.split(vim.fn.execute("messages"), "\n", { trimempty = true }) end

return {
  -- Neovim edits made since the last sync live only in Neovim; Emacs dying
  -- must not lose them, and the restarted Emacs must start from them.
  ["unsynced Neovim edits survive a killed Emacs and reach the new one"] = function(t)
    local path = t.open("kill_unsynced.org", t.DOC)
    mirror.sync()
    api.nvim_buf_set_lines(0, 1, 2, false, { "body a, edited" })
    kill_emacs(t)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* A", "body a, edited", "** A1", "text", "* TODO B", "body b" })
    agree(t, path)
    t.eq(vim.bo.modified, true, "still unsaved in Neovim")
  end,

  [":EmacsRestart keeps unsaved edits in every org buffer, both sides"] = function(t)
    vim.cmd("runtime plugin/emacs.lua")
    local first = t.open("restart_a.org", t.DOC)
    api.nvim_buf_set_lines(0, 0, 1, false, { "* A edited" })
    local first_buf = api.nvim_get_current_buf()
    local second = t.open("restart_b.org", t.DOC)
    api.nvim_buf_set_lines(0, 4, 5, false, { "* B edited" })
    mirror.sync()
    kill_emacs(t)
    vim.cmd("EmacsRestart")
    t.eq(t.lines(first_buf)[1], "* A edited", "first buffer in Neovim")
    t.eq(t.lines()[5], "* B edited", "second buffer in Neovim")
    t.eq(t.emacs_lines(first), t.lines(first_buf), "first buffer Emacs agrees")
    agree(t, second, "second buffer")
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(second)), "t", "Emacs knows it is unsaved")
    t.eq(t.read_file(second), t.DOC, "nothing written to disk")
  end,

  -- Emacs dies while it waits for an answer (C-c C-t's key): the command
  -- fails with an error naming Emacs, nothing in the buffer changes, and
  -- the next key starts a fresh Emacs.
  ["Emacs dying in the middle of a command leaves the buffer and recovers"] = function(t)
    local path = t.open("kill_mid.org", t.DOC)
    local pid = emacs_pid(t)
    local scripted = rpc.handlers.read_key
    rpc.handlers.read_key = function()
      uv.kill(pid, 9)
      vim.wait(5000, function() return not rpc.running() end, 10)
      return "t"
    end
    t.cursor(5)
    local ok, err = pcall(t.keys, "C-c C-t")
    assert(not ok, "the command failed")
    t.eq(t.lines(), DOC_LINES, "buffer unchanged")
    rpc.handlers.read_key = scripted
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B", "next command runs")
    agree(t, path)
    t.eq(tostring(err), "org-bridge.nvim: Emacs exited", "the error says what happened")
  end,

  -- Emacs's own buffers (Magit's) die with it; the next Emacs's buffer of
  -- the same name must show, and no key may run in a dead one.
  ["a dead Emacs's buffers go, and the next one shows its own of the same name"] = function(t)
    t.open("dead_buffers.org", t.DOC)
    local function show()
      t.eval([[(defun nvb-test-show () (interactive)
        (with-current-buffer (get-buffer-create "nvb-test-out") (insert "one\n"))
        (pop-to-buffer "nvb-test-out"))]])
      t.command("nvb-test-show")
    end
    show()
    t.eq(api.nvim_buf_get_name(0), "emacs://nvb-test-out")
    kill_emacs(t)
    t.eq(vim.fn.bufexists("emacs://nvb-test-out"), 0, "gone")
    show()
    t.eq({ api.nvim_buf_get_name(0), t.lines() }, { "emacs://nvb-test-out", { "one" } })
  end,

  -- (kill-emacs) from :EmacsEval is Emacs exiting on its own.
  [":EmacsEval (kill-emacs) reports the exit and the next key restarts"] = function(t)
    vim.cmd("runtime plugin/emacs.lua")
    local path = t.open("kill_eval.org", t.DOC)
    vim.cmd("messages clear")
    -- The exit is the command's error, as a Vim error.
    local ok, err = pcall(vim.cmd, "EmacsEval (kill-emacs 0)")
    t.eq(ok, false)
    assert(tostring(err):find("org-bridge.nvim: Emacs exited", 1, true), err)
    assert(vim.wait(5000, function() return not rpc.running() end, 10), "Emacs exited")
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  -- Emacs: M-: (while t) RET then C-g says "Quit" and Emacs carries on.
  -- Neovim's C-c must at least end the wait, with the buffer intact.
  ["C-c interrupts :EmacsEval of an infinite loop"] = function(t)
    local path = t.open("loop.org", t.DOC)
    api.nvim_buf_set_lines(0, 1, 2, false, { "unsynced edit" })
    local ok, err, ms, rescued = interrupted(t, 1000, function() t.eval("(while t)") end)
    assert(not ok, "the eval failed")
    assert(not rescued and ms < INTERRUPT_MS,
      ("C-c ended the wait (took %d ms, Emacs killed by the test: %s, error: %s)"):format(ms, rescued, err))
    t.eq(t.lines()[2], "unsynced edit", "Neovim's text intact")
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  ["C-c interrupts :EmacsEval of a long sleep"] = function(t)
    t.open("sleep.org", t.DOC)
    local ok, err, ms, rescued = interrupted(t, 1000, function() t.eval("(sleep-for 60)") end)
    assert(not ok, "the eval failed")
    assert(not rescued and ms < INTERRUPT_MS,
      ("C-c ended the wait (took %d ms, Emacs killed by the test: %s, error: %s)"):format(ms, rescued, err))
  end,

  -- A short sleep is not a hang: it returns its value.
  [":EmacsEval of a two-second sleep returns normally"] = function(t)
    t.eq(t.eval("(progn (sleep-for 2) 42)"), "42")
  end,

  -- Emacs: load stops at the error; forms before it stay in effect and
  -- Emacs carries on. The bridge must say so and keep working.
  ["an error in the init file is reported and org still works"] = function(t)
    local init = t.file("broken-init.el", table.concat({
      "(load " .. ("%q"):format(vim.fn.getcwd() .. "/test/init.el") .. ")",
      [[(setq org-todo-keywords '((sequence "TODO(t)" "WAIT(w)" "|" "DONE(d)")))]],
      [[(error "Broken on purpose")]],
      [[(setq org-todo-keywords '((sequence "NEVER(n)")))]],
    }, "\n"))
    restart_with_init(t, init)
    vim.cmd("messages clear")
    local path = t.file("init_error.org", t.DOC)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.wait(100)
    assert(vim.tbl_contains(messages(), "org-bridge.nvim: your init file failed: Broken on purpose"),
      "reported: " .. vim.inspect(messages()))
    t.cursor(5)
    t.answer("w")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* WAIT B", "forms before the error took effect")
    agree(t, path)
  end,

  -- Opened with :silent edit, as file pickers do; Emacs starts inside it.
  ["a syntax error in the init file is reported and org still works"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("reporting after :silent needs state(), Neovim 0.10") end
    local init = t.file("unbalanced-init.el", "(setq org-todo-keywords '((sequence \"TODO\" \"DONE\"))\n")
    restart_with_init(t, init)
    vim.cmd("messages clear")
    local path = t.open("init_syntax.org", t.DOC)
    -- Reported once the autocmd that started Emacs is done.
    local want = "org-bridge.nvim: your init file failed: End of file during parsing: " .. init
    vim.wait(1000, function() return vim.tbl_contains(messages(), want) end)
    assert(vim.tbl_contains(messages(), want), "reported: " .. vim.inspect(messages()))
    -- Without test/init.el's keywords C-c C-t cycles; no menu.
    t.cursor(5)
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  -- Batch Emacs writes princ to stdout and message to stderr. Neither is
  -- part of the protocol; a lot of either must not wedge the bridge.
  ["a lot of Emacs output on stdout and stderr does not wedge the bridge"] = function(t)
    local path = t.open("noisy.org", t.DOC)
    t.eq(t.eval([[(progn (dotimes (_ 5000) (princ (make-string 99 ?x)) (terpri)) 1)]]), "1", "stdout")
    t.eq(t.eval([[(progn (dotimes (_ 5000) (message "%s" (make-string 99 ?y))) 2)]]), "2", "stderr")
    t.eq(t.eval([[(progn (princ "READY\n" #'external-debugging-output) (princ "{\"id\": 1}\n") 3)]]), "3",
      "protocol-looking lines")
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  -- Emacs: a command that inserts then signals leaves the insertion, and
  -- the echo area shows the error.
  ["a command that edits then errors leaves the same partial edit on both sides"] = function(t)
    local path = t.open("partial_error.org", t.DOC)
    t.eval([[(defun nvb-test-edit-then-fail () (interactive) (insert "X") (error "Failed halfway"))]])
    t.after(function() t.eval("(fmakunbound 'nvb-test-edit-then-fail)") end)
    vim.cmd("messages clear")
    t.cursor(5, 2)
    t.command("nvb-test-edit-then-fail")
    t.eq(t.lines()[5], "* XB", "the insertion stays")
    agree(t, path)
    t.eq(messages()[#messages()], "Failed halfway", "error shown")
  end,

  -- Emacs: C-g at a prompt after the command edited keeps the edit.
  ["a command quit at a prompt after editing keeps the edit on both sides"] = function(t)
    local path = t.open("partial_quit.org", t.DOC)
    t.eval([[(defun nvb-test-edit-then-ask () (interactive) (insert "Y") (read-string "More? "))]])
    t.after(function() t.eval("(fmakunbound 'nvb-test-edit-then-ask)") end)
    t.cursor(5, 2)
    t.answer(t.QUIT)
    t.command("nvb-test-edit-then-ask")
    t.eq(t.lines()[5], "* YB", "the insertion stays")
    agree(t, path)
  end,
}
