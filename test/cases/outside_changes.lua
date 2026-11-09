-- Changes Emacs makes outside a command (timers, process sentinels, server
-- clients) reach Neovim without one, as Magit's refresh after git exits
-- and emacsclient's commit message do.
local api = vim.api

local WAIT_MS = 3000

local function wait_for(what, cond)
  if not vim.wait(WAIT_MS, cond, 10) then error("timed out waiting for " .. what, 2) end
end

-- Buffer names shown in the current tab's windows, top to bottom.
local function shown()
  local wins = api.nvim_tabpage_list_wins(0)
  table.sort(wins, function(a, b) return api.nvim_win_get_position(a)[1] < api.nvim_win_get_position(b)[1] end)
  return vim.tbl_map(function(w) return vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(w)), ":t") end, wins)
end

local function lines_of(name)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(b) == "emacs://" .. name then return api.nvim_buf_get_lines(b, 0, -1, false) end
  end
end

-- Elisp running FORM once the process `true' exits, from its sentinel.
local function after_process(form)
  return ("(set-process-sentinel (start-process \"t\" nil \"true\") (lambda (_p _e) %s))"):format(form)
end

-- Start Emacs's server, as Magit's with-editor does; stopped after the test.
local function start_server(t)
  if vim.fn.executable("emacsclient") == 0 then t.skip("no emacsclient") end
  t.eval(([[(progn (require 'server)
    (setq server-socket-dir %q server-name "nvb-test")
    (make-directory server-socket-dir t)
    (set-file-modes server-socket-dir #o700)
    ;; As with-editor's mode: buffer-local state a reload would reset.
    (add-hook 'server-visit-hook (lambda () (setq-local nvb-test-visited t)))
    (server-start))]]):format(t.WORK .. "/server"))
  -- Stop the server without asking about clients left.
  t.after(function() t.eval("(server-start t t)") end)
end

-- Have emacsclient open path, as git does a commit message.
local function edit_with_client(t, path)
  t.eval(([[(start-process "client" nil "emacsclient" "-s" (expand-file-name server-name server-socket-dir) %q)]]):format(path))
  wait_for("the file", function() return api.nvim_buf_get_name(0) == path end)
end

local function client_done(t)
  return t.eval([[(let ((p (get-process "client"))) (or (null p) (eq (process-status p) 'exit)))]]) == "t"
end

return {
  ["a timer's edit reaches Neovim without a command"] = function(t)
    local path = t.open("timer_edit.org", "* A\n")
    t.command("ignore")
    t.eval(("(run-at-time 0.3 nil (lambda () (with-current-buffer (get-file-buffer %q) (goto-char (point-max)) (insert \"* B\\n\"))))"):format(path))
    wait_for("the edit", function() return #t.lines() == 2 end)
    t.eq(t.lines(), { "* A", "* B" })
  end,

  -- Insert mode waits the same way; feedkeys can't hold it in a test.
  ["a change waits while Neovim is in Visual mode, and arrives on leaving it"] = function(t)
    local path = t.open("visual_waits.org", "* A\n")
    t.command("ignore")
    t.feed("v")
    t.eval(("(run-at-time 0.1 nil (lambda () (with-current-buffer (get-file-buffer %q) (goto-char (point-min)) (insert \"* Z\\n\"))))"):format(path))
    vim.wait(800)
    t.eq({ vim.fn.mode(), t.lines() }, { "v", { "* A" } }, "in Visual mode")
    t.feed("<Esc>")
    wait_for("the edit", function() return #t.lines() == 2 end)
    t.eq(t.lines(), { "* Z", "* A" })
  end,

  ["a window a sentinel shows appears in Neovim and the next command keeps it"] = function(t)
    t.open("sentinel_window.org", "* A\n")
    t.command("ignore")
    t.eval(after_process([[(with-current-buffer (get-buffer-create "*out*") (insert "done\n"))
      (select-window (split-window-below))
      (switch-to-buffer "*out*")]]))
    wait_for("the window", function() return #api.nvim_tabpage_list_wins(0) == 2 end)
    t.eq(shown(), { "sentinel_window.org", "*out*" })
    t.eq(t.lines(), { "done" }, "the new window is current")
    t.command("ignore")
    t.eq(shown(), { "sentinel_window.org", "*out*" }, "after a command")
  end,

  ["a second change before any command reuses the window the first made"] = function(t)
    t.open("twice.org", "* A\n")
    t.command("ignore")
    t.eval([[(run-at-time 0.1 nil (lambda ()
      (with-current-buffer (get-buffer-create "*out*") (erase-buffer) (insert "one\n"))
      (display-buffer "*out*" '(display-buffer-below-selected))))]])
    wait_for("the window", function() return #api.nvim_tabpage_list_wins(0) == 2 end)
    t.eval([[(run-at-time 0.1 nil (lambda () (with-current-buffer "*out*" (insert "two\n"))))]])
    wait_for("the second line", function() return vim.tbl_contains(shown(), "*out*") and #lines_of("*out*") == 2 end)
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "still two windows")
  end,

  ["a command sent before Neovim heard of a new window shows the window instead"] = function(t)
    t.open("raced.org", "* A\n")
    t.command("ignore")
    t.eval([[(run-at-time 0.1 nil (lambda ()
      (with-current-buffer (get-buffer-create "*out*") (insert "x\n"))
      (display-buffer "*out*" '(display-buffer-below-selected))))]])
    -- Block Neovim's loop: Emacs's notice waits unread, as when a key is
    -- typed just as Emacs changes.
    vim.loop.sleep(600)
    t.keys("C-c C-t")
    t.eq(shown(), { "raced.org", "*out*" })
    t.eq(t.emacs_lines(t.WORK .. "/raced.org"), { "* A" }, "the command didn't run")
  end,

  ["Neovim's cursor stays where it moved when Emacs changes another window"] = function(t)
    t.open("cursor_stays.org", "* A\nline\nline\nline\n")
    t.command("ignore")
    t.cursor(3, 2)
    t.eval([[(run-at-time 0.1 nil (lambda ()
      (with-current-buffer (get-buffer-create "*out*") (insert "x\n"))
      (display-buffer "*out*" '(display-buffer-below-selected))))]])
    wait_for("the window", function() return #api.nvim_tabpage_list_wins(0) == 2 end)
    t.eq(api.nvim_win_get_cursor(0), { 3, 2 })
  end,

  -- How Magit's commit message arrives: git runs emacsclient, the server
  -- opens the file while Emacs is idle.
  -- Twice: the second time reuses the buffer Neovim kept (Magit's second commit).
  ["a file emacsclient opens appears with Emacs's keys, and C-x # finishes it, twice"] = function(t)
    local msg = t.file("MSG.txt", "")
    t.open("client.org", "* A\n")
    t.command("ignore")
    start_server(t)
    for i = 1, 2 do
      t.file("MSG.txt", "template " .. i .. "\n") -- as git writes it before each commit
      edit_with_client(t, msg)
      t.eq(vim.fn.maparg("<C-c>", "n") ~= "", true, "C-c goes to Emacs")
      api.nvim_buf_set_lines(0, 0, -1, false, { "typed in Neovim " .. i })
      t.command("ignore")
      t.eq(t.eval(("(with-current-buffer (get-file-buffer %q) (bound-and-true-p nvb-test-visited))"):format(msg)), "t",
        "Emacs's buffer kept its state")
      t.answer(true) -- Save file?
      t.keys("C-x #")
      wait_for("emacsclient to exit", function() return client_done(t) end)
      t.eq(t.read_file(msg), "typed in Neovim " .. i .. "\n")
      t.eq(shown(), { "client.org" })
    end
  end,

  -- As quitting git's editor: :w alone keeps git waiting; quitting the
  -- file's last window after writing ends the edit with what was written,
  -- and so does :q!, dropping what wasn't.
  ["quitting a file emacsclient opened ends the edit"] = function(t)
    local msg = t.file("QUIT_MSG.txt", "template\n")
    t.open("quit_client.org", "* A\n")
    vim.cmd("split")
    t.command("ignore")
    start_server(t)
    for _, quit in ipairs({ "wq", "q!" }) do
      edit_with_client(t, msg)
      api.nvim_buf_set_lines(0, 0, -1, false, { "saved" })
      vim.cmd("silent w")
      vim.wait(300)
      t.eq(client_done(t), false, ":w keeps it waiting")
      api.nvim_buf_set_lines(0, 0, -1, false, { "typed after" })
      vim.cmd(quit == "wq" and "silent wq" or "q!")
      wait_for("emacsclient to exit after :" .. quit, function() return client_done(t) end)
      t.eq(t.read_file(msg), (quit == "wq" and "typed after" or "saved") .. "\n")
      t.eq(shown(), { "quit_client.org" })
    end
  end,

  ["nothing is pulled when Emacs is idle"] = function(t)
    t.open("idle.org", "* A\n")
    t.command("ignore")
    local calls = 0
    local rpc = require("emacs.rpc")
    local call = rpc.call
    rpc.call = function(m, p)
      calls = calls + 1
      return call(m, p)
    end
    t.after(function() rpc.call = call end)
    vim.wait(1000)
    t.eq(calls, 0)
  end,
}
