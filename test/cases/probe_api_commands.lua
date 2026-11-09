-- The documented user commands, the Lua API and setup()'s options: each
-- works as the README says, and errors arrive as Vim errors, not tracebacks.
-- Expected org results: emacs -Q --batch -l test/init.el, the same commands.
local api = vim.api
local rpc = require("emacs.rpc")
local mirror = require("emacs.mirror")
local emacs = require("emacs")

local GROUP = "org-bridge.nvim"

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

local function commands()
  vim.g.loaded_emacs_nvim = nil
  vim.cmd("runtime plugin/emacs.lua")
end

local function messages() return vim.split(vim.fn.execute("messages"), "\n", { trimempty = true }) end

-- Type an Ex command as a user would; returns the Vim error it gave
-- (v:errmsg, nil if none) and the messages it added.
local function ex(cmd)
  vim.cmd("messages clear")
  vim.v.errmsg = ""
  api.nvim_feedkeys(":" .. cmd .. "\r", "xt", false)
  return vim.v.errmsg ~= "" and vim.v.errmsg or nil, messages()
end

local function global_autocmds()
  return vim.tbl_filter(function(a) return not a.buflocal end, api.nvim_get_autocmds({ group = GROUP }))
end

-- Call setup() again as a user's config would; the harness's setup and
-- options come back after the test.
local function setup_again(t, opts)
  local before = {}
  for _, a in ipairs(global_autocmds()) do before[a.id] = true end
  local saved_mirror, saved_rpc = vim.deepcopy(mirror.config), vim.deepcopy(rpc.config)
  t.after(function()
    for _, a in ipairs(global_autocmds()) do
      if not before[a.id] then api.nvim_del_autocmd(a.id) end
    end
    for k, v in pairs(saved_mirror) do mirror.config[k] = v end
    for k, v in pairs(saved_rpc) do rpc.config[k] = v end
    -- A setup() that replaces its own autocmds took the harness's with it.
    if #api.nvim_get_autocmds({ group = GROUP, event = "FileType" }) == 0 then emacs.setup({}) end
  end)
  emacs.setup(opts)
end

-- Restart Emacs after the test so it runs with the harness's options again.
local function restart_after(t) t.after(rpc.stop) end

local function contains(lines, pattern)
  for _, l in ipairs(lines) do
    if l:find(pattern) then return true end
  end
  return false
end

-- :checkhealth emacs's report, as lines. 0.10+ fills the buffer as the
-- checks run, so wait for the last line the report should have.
local HEALTH_MS = 10000
local function health(last)
  vim.cmd("checkhealth emacs")
  local buf = api.nvim_get_current_buf()
  local function lines() return api.nvim_buf_get_lines(buf, 0, -1, false) end
  vim.wait(HEALTH_MS, function() return contains(lines(), last) end, 20)
  local out = lines()
  vim.cmd("bwipeout!")
  return out
end

return {
  -- Emacs: C-c C-t t on * B gives "* TODO B".
  [":Emacs runs a key sequence in the current buffer"] = function(t)
    commands()
    local path = t.open("api_keys.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.eq(ex("Emacs C-c C-t"), nil)
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  -- Emacs: C-u 2 M-x org-next-visible-heading from * A lands on * B.
  [":EmacsCommand with a count passes it as the prefix argument"] = function(t)
    commands()
    t.open("api_count.org", t.DOC)
    t.cursor(1)
    t.eq(ex("2EmacsCommand org-next-visible-heading"), nil)
    t.eq(api.nvim_win_get_cursor(0)[1], 5)
  end,

  [":EmacsEval prints the value"] = function(t)
    commands()
    t.open("api_eval.org", t.DOC)
    local err, msgs = ex("EmacsEval (+ 1 2)")
    t.eq(err, nil)
    t.eq(msgs[#msgs], "3")
  end,

  -- Emacs's M-: (error "boom") says "boom" in the echo area. In Neovim it
  -- should be a Vim error (v:errmsg, :try catches it), not a Lua traceback.
  [":EmacsEval of an Elisp error is a Vim error"] = function(t)
    commands()
    t.open("api_eval_err.org", t.DOC)
    local err, msgs = ex([[EmacsEval (error "boom")]])
    t.eq(contains(msgs, "traceback") or contains(msgs, "%.lua:"), false, "no traceback: " .. vim.inspect(msgs))
    t.eq(msgs[#msgs], "Emacs: boom", "message")
    assert(err and err:find("Emacs: boom", 1, true), "Vim error: " .. tostring(err))
  end,

  -- Emacs: M-: (+ 1 RET says "End of file during parsing".
  [":EmacsEval of unbalanced Elisp reports the read error cleanly"] = function(t)
    commands()
    t.open("api_eval_read.org", t.DOC)
    local _, msgs = ex("EmacsEval (+ 1")
    t.eq(msgs[#msgs], "Emacs: End of file during parsing", "message")
    t.eq(rpc.running(), true, "Emacs still running")
    t.eq(t.eval("(+ 1 2)"), "3", "next eval works")
  end,

  -- Emacs: M-x no-such-command is refused; the buffer is unchanged.
  [":EmacsCommand of a non-command is a Vim error and changes nothing"] = function(t)
    commands()
    local path = t.open("api_nocmd.org", t.DOC)
    local err, msgs = ex("EmacsCommand no-such-command")
    t.eq(contains(msgs, "traceback") or contains(msgs, "%.lua:"), false, "no traceback: " .. vim.inspect(msgs))
    assert(contains(msgs, "no%-such%-command"), "names the command: " .. vim.inspect(msgs))
    assert(err, "Vim error")
    t.eq(t.lines(), vim.split(t.DOC:gsub("\n$", ""), "\n"))
    agree(t, path)
  end,

  -- Emacs: C-c z is undefined in org-mode ("C-c z is undefined").
  [":Emacs with an unbound key says so and changes nothing"] = function(t)
    commands()
    local path = t.open("api_unbound.org", t.DOC)
    local _, msgs = ex("Emacs C-c z")
    t.eq(msgs[#msgs], "C-c z is undefined")
    agree(t, path)
  end,

  [":EmacsAgenda t opens the TODO list without asking"] = function(t)
    commands()
    local path = t.open("api_agenda.org", "* TODO Agenda item\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.eq(ex("EmacsAgenda t"), nil)
    t.eq(#t.asked(), 0, "no dispatcher")
    assert(t.find_line("TODO Agenda item"), "agenda:\n" .. table.concat(t.lines(), "\n"))
    vim.cmd("only")
  end,

  [":EmacsAgenda without a key asks the dispatcher"] = function(t)
    commands()
    local path = t.open("api_agenda2.org", "* TODO Agenda item\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.answer("t")
    t.eq(ex("EmacsAgenda"), nil)
    t.eq(#t.asked(), 1, "one dispatcher question")
    assert(t.find_line("TODO Agenda item"), "agenda:\n" .. table.concat(t.lines(), "\n"))
    vim.cmd("only")
  end,

  -- Emacs: org-capture t shows "* TODO " in CAPTURE-inbox.org.
  [":EmacsCapture opens the capture template; C-c C-k aborts it"] = function(t)
    commands()
    t.set("org-directory", ("%q"):format(t.WORK))
    t.file("inbox.org", "* Inbox\n")
    t.open("api_capture.org", t.DOC)
    t.answer("t")
    t.eq(ex("EmacsCapture"), nil)
    t.eq(t.lines()[1], "* TODO ")
    t.keys("C-c C-k")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "capture window closed")
  end,

  -- Emacs: org-capture-finalize saves the target even on abort; an empty
  -- inbox.org is written back as an empty file.
  ["aborting a capture into an empty file leaves it empty on disk"] = function(t)
    t.set("org-directory", ("%q"):format(t.WORK))
    local inbox = t.file("inbox.org", "")
    t.open("api_capture_empty.org", t.DOC)
    t.answer("t")
    t.command("org-capture")
    t.keys("C-c C-k")
    t.eq(t.read_file(inbox), "")
  end,

  [":EmacsLog opens the log in a split"] = function(t)
    commands()
    t.open("api_log.org", t.DOC)
    t.eq(ex("EmacsLog"), nil)
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "split")
    t.eq(api.nvim_buf_get_name(0), vim.fn.fnamemodify(rpc.config.log, ":p"))
    assert(contains(t.lines(), "^== starting"), "log has the start line")
    vim.cmd("only")
  end,

  [":checkhealth emacs reports Emacs, Org and the bridge"] = function(t)
    t.open("api_health.org", t.DOC)
    local lines = health("bridge running")
    assert(contains(lines, "OK.*Emacs %d+%.%d"), "Emacs line:\n" .. table.concat(lines, "\n"))
    assert(contains(lines, "OK.*Org %d"), "Org line")
    assert(contains(lines, "OK.*bridge running"), "bridge line")
    t.eq(contains(lines, "ERROR"), false, "no errors")
  end,

  -- emacs -Q --batch -l broken.el exits with "Symbol’s value as variable
  -- is void: no-such-variable".
  [":checkhealth emacs shows the init file's error"] = function(t)
    local init = t.file("api_broken_init.el", "(message \"%s\" no-such-variable)\n")
    local old = rpc.config.init
    rpc.config.init = init
    t.after(function() rpc.config.init = old end)
    local lines = health("no%-such%-variable")
    assert(contains(lines, "ERROR.*init file"), "error line:\n" .. table.concat(lines, "\n"))
    assert(contains(lines, "no%-such%-variable"), "Emacs's message")
  end,

  [":checkhealth emacs names a missing Emacs executable"] = function(t)
    local old = rpc.config.emacs
    rpc.config.emacs = "no-such-emacs-binary"
    t.after(function() rpc.config.emacs = old end)
    local lines = health("not on PATH")
    assert(contains(lines, "ERROR.*no%-such%-emacs%-binary.*not on PATH"), table.concat(lines, "\n"))
  end,

  ["require('emacs').eval returns the printed value in the current buffer's mirror"] = function(t)
    t.open("api_lua_eval.org", t.DOC)
    t.eq(emacs.eval("(list 1 \"a\" 'b)"), '(1 "a" b)')
    t.eq(emacs.eval("(buffer-name)"), '"api_lua_eval.org"')
  end,

  -- The Lua caller gets the error to handle, without a traceback in it.
  ["require('emacs').eval raises an Elisp error as a Lua error"] = function(t)
    t.open("api_lua_err.org", t.DOC)
    local ok, err = pcall(emacs.eval, [[(error "boom")]])
    t.eq(ok, false)
    t.eq(err, "Emacs: boom")
  end,

  -- Edits made in Neovim but not yet synced are what eval sees.
  ["require('emacs').eval sees unsynced Neovim edits"] = function(t)
    t.open("api_lua_sync.org", t.DOC)
    api.nvim_buf_set_lines(0, 1, 2, false, { "edited" })
    t.eq(emacs.eval("(save-excursion (goto-char (point-min)) (forward-line 1) (thing-at-point 'line t))"),
      '"edited\n"')
  end,

  -- Emacs: M-x org-toggle-heading on "body a" under * A makes it "** body a".
  ["require('emacs').exec runs keys and commands"] = function(t)
    local path = t.open("api_lua_exec.org", t.DOC)
    t.cursor(2)
    emacs.exec({ command = "org-toggle-heading" })
    t.eq(t.lines()[2], "** body a", "command")
    t.cursor(1)
    t.answer("t")
    emacs.exec({ keys = "C-c C-t" })
    t.eq(t.lines()[1], "* TODO A", "keys")
    agree(t, path)
  end,

  ["setup() with an unknown option names it"] = function(t)
    local ok, err = pcall(setup_again, t, { no_such_option = true })
    t.eq(ok, false)
    assert(tostring(err):find("unknown option no_such_option", 1, true), tostring(err))
  end,

  ["setup() twice still attaches and maps the org keys"] = function(t)
    setup_again(t, {})
    local path = t.open("api_twice.org", t.DOC)
    t.eq(mirror.id(api.nvim_get_current_buf()) ~= nil, true, "attached")
    t.cursor(5)
    -- C-c reads the rest of the sequence from Emacs's key prompts.
    t.answer("C-t", "t")
    t.feed("<C-c>")
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  -- A second setup() (a re-sourced config) should not run each handler
  -- twice: two FileType handlers attach twice, two VimLeavePre handlers
  -- shut Emacs down twice.
  ["setup() twice does not register its autocmds twice"] = function(t)
    local function count()
      local n = {}
      for _, a in ipairs(global_autocmds()) do n[a.event] = (n[a.event] or 0) + 1 end
      return n
    end
    local once = count()
    setup_again(t, {})
    t.eq(count(), once)
  end,

  -- setup({ keys = ... }) later: a file opened after it gets the new keys.
  ["setup() again with keys maps only those in buffers opened after it"] = function(t)
    setup_again(t, { keys = { n = { "<C-c>" }, i = {}, x = {} } })
    t.open("api_keys_later.org", "* A\n** B\n")
    t.eq(vim.fn.maparg("<Tab>", "n", false, true).desc, nil, "<Tab> not mapped")
    t.eq(vim.fn.maparg("<C-c>", "n", false, true).desc, "org-bridge.nvim", "<C-c> mapped")
    t.answer("C-t", "t")
    t.feed("<C-c>")
    t.eq(t.lines()[1], "* TODO A")
  end,

  -- README: "false turns one off": the other letter stays.
  ["setup() textobjects with one letter keeps the other's default"] = function(t)
    setup_again(t, { textobjects = { subtree = "s" } })
    local path = t.open("api_textobj.org", t.DOC)
    t.cursor(3)
    t.feed("das")
    t.eq(t.lines(), { "* A", "body a", "* B", "body b" }, "das deletes the subtree")
    t.cursor(2)
    t.feed("dae")
    t.eq(t.lines(), { "* A", "* B", "body b" }, "dae still deletes the element")
    agree(t, path)
  end,

  ["setup() textobjects false turns the letter off"] = function(t)
    setup_again(t, { textobjects = { subtree = false, element = "e" } })
    t.open("api_textobj_off.org", t.DOC)
    t.eq(vim.fn.maparg("ar", "o", false, true).desc, nil, "ar not mapped")
    t.eq(vim.fn.maparg("ae", "o", false, true).desc, "org-bridge.nvim", "ae mapped")
  end,

  -- Emacs: M-x org-overview leaves only the top headings.
  ["setup() fold_commands maps a fold key to another command"] = function(t)
    setup_again(t, { fold_commands = { zR = "org-overview" } })
    t.open("api_fold.org", t.DOC)
    t.feed("zR")
    t.eq(t.folds(), { "1-4", "5-6" })
  end,

  -- The README lists fold_commands' keys as zo zc za zR zM ...; changing
  -- one shouldn't drop the rest.
  ["setup() fold_commands with one key keeps the other fold keys"] = function(t)
    setup_again(t, { fold_commands = { zR = "org-overview" } })
    t.open("api_fold_rest.org", t.DOC)
    t.eq(vim.fn.maparg("zo", "n", false, true).desc, "org-bridge.nvim", "zo mapped")
    t.eq(vim.fn.maparg("zM", "n", false, true).desc, "org-bridge.nvim", "zM mapped")
  end,

  -- Emacs: RET at the end of "- item" indents the new line to the body.
  ["setup() emacs_typing false leaves Insert-mode RET to Vim"] = function(t)
    setup_again(t, { emacs_typing = false })
    t.open("api_typing_off.org", "- item\n")
    t.feed("A<CR>x<Esc>")
    t.eq(t.lines(), { "- item", "x" })
  end,

  ["emacs_typing true sends Insert-mode RET to Emacs"] = function(t)
    local path = t.open("api_typing_on.org", "- item\n")
    t.feed("A<CR>x<Esc>")
    t.eq(t.lines(), { "- item", "  x" })
    agree(t, path)
  end,

  -- l is org-agenda-log-mode in the agenda; passthrough keeps it Neovim's.
  ["setup() passthrough keeps a key Neovim's in the agenda"] = function(t)
    setup_again(t, { passthrough = { "j", "k", "g", "G", ":", "l" } })
    local path = t.open("api_pass.org", "* TODO Agenda item\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    emacs.exec({ command = "org-agenda", pending = { "t" } })
    t.eq(vim.fn.maparg("l", "n", false, true).desc, nil, "l not mapped in the agenda")
    t.eq(vim.fn.maparg("r", "n", false, true).desc, "org-bridge.nvim", "r still Emacs's")
    vim.cmd("only")
  end,

  ["setup() init loads the file into the next Emacs"] = function(t)
    local init = t.file("api_init.el", table.concat({
      ("(load %q)"):format(vim.fn.getcwd() .. "/test/init.el"),
      "(setq api-init-loaded 42)",
    }, "\n"))
    setup_again(t, { init = init })
    restart_after(t)
    rpc.stop()
    t.open("api_init.org", t.DOC)
    t.eq(t.eval("api-init-loaded"), "42")
  end,

  ["setup() log writes the bridge log to that file"] = function(t)
    local log = t.WORK .. "/api_other.log"
    setup_again(t, { log = log })
    restart_after(t)
    rpc.stop()
    t.open("api_log2.org", t.DOC)
    t.eval("1")
    assert(t.read_file(log):find("== starting", 1, true), "log file has the start line")
  end,

  -- Emacs: M-x runs in the current buffer's directory; an empty Neovim
  -- buffer's is :pwd, which :cd changes after Emacs started.
  [":EmacsCommand from a buffer with no file runs in Neovim's current directory"] = function(t)
    local old = vim.fn.getcwd()
    t.after(function() vim.cmd("cd " .. vim.fn.fnameescape(old)) end)
    t.open("api_cwd.org", t.DOC)
    vim.fn.mkdir(t.WORK .. "/elsewhere", "p")
    vim.cmd("enew | cd " .. vim.fn.fnameescape(t.WORK .. "/elsewhere"))
    t.eval([[(defun nvb-test-dir () (interactive) (setq nvb-test-dir default-directory))]])
    t.after(function() t.eval("(fmakunbound 'nvb-test-dir)") end)
    t.command("nvb-test-dir")
    t.eq(t.eval("nvb-test-dir"), ('"%s/"'):format(vim.fn.getcwd()))
  end,
}
