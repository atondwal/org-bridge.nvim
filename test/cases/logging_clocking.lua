-- Logging and clocking: org-log-done time/note, per-state logging into
-- LOGBOOK, clock in/out/cancel/last/goto, effort of the clocked task.
-- Expected text comes from emacs -Q --batch -l test/init.el.
local api = vim.api

local TS = "%[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]"
local CLOCK_OPEN = "^CLOCK: " .. TS .. "$"
local CLOCK_ZERO = "^CLOCK: " .. TS .. "%-%-" .. TS .. " =>  0:00$"
local PER_STATE = [['((sequence "TODO(t!)" "WAIT(w@/!)" "|" "DONE(d!)"))]]

local function note_buffer_shown(t)
  t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Org Note*", "note buffer shown")
end

-- Replace the note buffer's last line with `text`, then C-c C-c.
local function finish_note(t, text)
  api.nvim_buf_set_lines(0, -2, -1, false, { text })
  t.keys("C-c C-c")
end

local function clock_out_after(t)
  t.after(function() t.eval("(when (org-clocking-p) (org-clock-out))") end)
end

-- Check `lines` against `want`, where a want entry starting with "^" is a pattern.
local function match(t, lines, want, what)
  t.eq(#lines, #want, (what or "") .. " line count: " .. vim.inspect(lines))
  for i, w in ipairs(want) do
    if w:sub(1, 1) == "^" then
      assert(lines[i]:find(w), ("%s line %d: %s"):format(what or "", i, lines[i]))
    else
      t.eq(lines[i], w, (what or "") .. " line " .. i)
    end
  end
end

return {
  ["org-log-done note: C-c C-c stores a CLOSING NOTE under CLOSED"] = function(t)
    t.set("org-log-done", "'note")
    local path = t.open("lognote.org", "* TODO Task\nbody\n")
    t.answer("d")
    t.keys("C-c C-t")
    note_buffer_shown(t)
    t.eq(t.lines(), { "# Insert note for closed todo item.", "# Finish with C-c C-c, or cancel with C-c C-k.", "" })
    finish_note(t, "all done")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "lognote.org", "back in the file")
    match(t, t.lines(), { "* DONE Task", "^CLOSED: " .. TS .. "$",
      "^%- CLOSING NOTE " .. TS .. " \\\\$", "  all done", "body" })
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["WAIT(w@/!) asks for a note into LOGBOOK; DONE(d!) adds a time line above it"] = function(t)
    t.set("org-log-done", "'time")
    t.set("org-log-into-drawer", "t")
    t.set("org-todo-keywords", PER_STATE)
    local path = t.open("perstate.org", "* TODO Task\nbody\n")
    t.answer("w")
    t.keys("C-c C-t")
    note_buffer_shown(t)
    t.eq(t.lines()[1], '# Insert note for state change from "TODO" to "WAIT".')
    finish_note(t, "blocked")
    match(t, t.lines(), { "* WAIT Task", ":LOGBOOK:",
      '^%- State "WAIT"       from "TODO"       ' .. TS .. " \\\\$", "  blocked", ":END:", "body" }, "WAIT")
    t.answer("d")
    t.keys("C-c C-t")
    match(t, t.lines(), { "* DONE Task", "^CLOSED: " .. TS .. "$", ":LOGBOOK:",
      '^%- State "DONE"       from "WAIT"       ' .. TS .. "$",
      '^%- State "WAIT"       from "TODO"       ' .. TS .. " \\\\$", "  blocked", ":END:", "body" }, "DONE")
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["C-c C-k on a WAIT note keeps the state and logs nothing"] = function(t)
    t.set("org-log-into-drawer", "t")
    t.set("org-todo-keywords", PER_STATE)
    local path = t.open("perstatek.org", "* TODO Task\nbody\n")
    t.answer("w")
    t.keys("C-c C-t")
    note_buffer_shown(t)
    api.nvim_buf_set_lines(0, -2, -1, false, { "nope" })
    t.keys("C-c C-k")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "perstatek.org", "back in the file")
    t.eq(t.lines(), { "* WAIT Task", "body" })
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["C-c C-x C-q cancels the clock and removes the empty drawer"] = function(t)
    local path = t.open("cancel.org", "* A\nbody\n* B\n")
    clock_out_after(t)
    t.keys("C-c C-x C-i")
    match(t, t.lines(), { "* A", ":LOGBOOK:", CLOCK_OPEN, ":END:", "body", "* B" }, "clocked in")
    t.keys("C-c C-x C-q")
    t.eq(t.lines(), { "* A", "body", "* B" })
    t.eq(t.eval("(org-clocking-p)"), "nil")
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["org-clock-out-remove-zero-time-clocks drops the 0:00 line and its drawer"] = function(t)
    t.set("org-clock-out-remove-zero-time-clocks", "t")
    local path = t.open("zero.org", "* A\nbody\n")
    clock_out_after(t)
    t.keys("C-c C-x C-i")
    t.keys("C-c C-x C-o")
    t.eq(t.lines(), { "* A", "body" })
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["C-c C-x C-x from another heading clocks the last task back in"] = function(t)
    local path = t.open("inlast.org", "* A\n* B\n")
    clock_out_after(t)
    t.keys("C-c C-x C-i")
    t.keys("C-c C-x C-o")
    t.cursor(5, 1)
    t.eq(t.lines()[5], "* B")
    t.keys("C-c C-x C-x")
    match(t, t.lines(), { "* A", ":LOGBOOK:", CLOCK_OPEN, CLOCK_ZERO, ":END:", "* B" })
    t.eq(api.nvim_win_get_cursor(0), { 6, 1 }, "cursor follows B down")
    t.eq(t.eval("(substring-no-properties org-clock-current-task)"), '"A"')
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["C-u C-c C-x C-x picks a task from the clock history menu"] = function(t)
    t.eval("(setq org-clock-history nil)")
    t.after(function() t.eval("(setq org-clock-history nil)") end)
    local path = t.open("history.org", "* A\n* B\n* C\n")
    clock_out_after(t)
    t.keys("C-c C-x C-i")
    t.cursor(5)
    t.keys("C-c C-x C-i")
    t.keys("C-c C-x C-o")
    t.cursor(9)
    t.eq(t.lines()[9], "* C")
    -- History, most recent first: [1] B, [2] A.
    t.answer("2")
    t.keys("C-c C-x C-x", 4)
    t.eq(t.asked()[1].method, "read_key")
    t.eq(t.eval("(substring-no-properties org-clock-current-task)"), '"A"')
    match(t, t.lines(), { "* A", ":LOGBOOK:", CLOCK_OPEN, CLOCK_ZERO, ":END:",
      "* B", ":LOGBOOK:", CLOCK_ZERO, ":END:", "* C" })
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["C-c C-x C-j from another file jumps to the clocked heading"] = function(t)
    t.open("gotoa.org", "* Intro\ntext\n* Task\nbody\n")
    clock_out_after(t)
    t.cursor(3)
    t.keys("C-c C-x C-i")
    t.open("gotob.org", "* Other\n")
    local other = api.nvim_get_current_buf()
    t.keys("C-c C-x C-j")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "gotoa.org", "switched file")
    t.eq(api.nvim_win_get_cursor(0), { 3, 0 }, "on the heading")
    t.eq(t.lines(other), { "* Other" }, "other file untouched")
  end,

  ["C-c C-x C-e from another file sets the clocked task's effort"] = function(t)
    local path = t.open("efforta.org", "* Task\nbody\n")
    clock_out_after(t)
    t.keys("C-c C-x C-i")
    t.open("effortb.org", "* Other\n")
    local other = api.nvim_get_current_buf()
    t.answer("1:30")
    t.keys("C-c C-x C-e")
    t.eq(t.asked()[1].params.prompt, "Set effort (hh:mm or mm): ")
    t.eq(t.lines(), { "* Other" }, "current file untouched")
    match(t, t.emacs_lines(path), { "* Task", ":PROPERTIES:", ":Effort:   1:30", ":END:",
      ":LOGBOOK:", CLOCK_OPEN, ":END:", "body" }, "Emacs")
    vim.cmd("silent buffer " .. vim.fn.fnameescape(path))
    t.eq(t.lines(), t.emacs_lines(path), "Neovim's copy of the clocked file")
    t.eq(t.lines(other), { "* Other" })
  end,

  ["C-c C-c on a CLOCK line recomputes its duration"] = function(t)
    local path = t.open("recompute.org", table.concat({ "* A", ":LOGBOOK:",
      "CLOCK: [2026-11-01 Sun 10:00]--[2026-11-01 Sun 12:45] =>  0:01",
      "CLOCK: [2026-11-02 Mon 09:00]--[2026-11-02 Mon 09:30] =>  0:30", ":END:", "" }, "\n"))
    t.cursor(3)
    t.keys("C-c C-c")
    t.eq(t.lines()[3], "CLOCK: [2026-11-01 Sun 10:00]--[2026-11-01 Sun 12:45] =>  2:45")
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["org-log-note-clock-out: the clock-out note goes under the CLOCK line"] = function(t)
    t.set("org-log-note-clock-out", "t")
    local path = t.open("clocknote.org", "* A\n")
    clock_out_after(t)
    t.keys("C-c C-x C-i")
    t.keys("C-c C-x C-o")
    note_buffer_shown(t)
    t.eq(t.lines(), { "# Insert note for stopped clock.", "# Finish with C-c C-c, or cancel with C-c C-k.",
      "", "# Task: A", "" })
    finish_note(t, "wrapped up")
    match(t, t.lines(), { "* A", ":LOGBOOK:", CLOCK_ZERO, "- wrapped up", ":END:" })
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["C-_ after a CLOSING NOTE removes the note; a second C-_ the DONE"] = function(t)
    t.set("org-log-done", "'note")
    local path = t.open("noteundo.org", "* TODO Task\nbody\n")
    t.answer("d")
    t.keys("C-c C-t")
    finish_note(t, "all done")
    t.eq(#t.lines(), 5, "note stored")
    t.keys("C-_")
    match(t, t.lines(), { "* DONE Task", "^CLOSED: " .. TS .. "$", "body" }, "first C-_")
    t.keys("C-_")
    t.eq(t.lines(), { "* TODO Task", "body" }, "second C-_")
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  -- Emacs: kill-buffer runs org-check-running-clock, which asks to clock out
  -- and then to save. The closed clock must reach the file.
  ["wiping the clocked buffer clocks out, saves, and clears the statusline"] = function(t)
    local path = t.open("wipe.org", "* A\n")
    clock_out_after(t)
    t.keys("C-c C-x C-i")
    vim.cmd("silent write")
    vim.cmd("silent enew")
    t.answer(true, true)
    vim.cmd("silent bwipeout " .. vim.fn.fnameescape(path))
    t.eq(vim.tbl_map(function(a) return a.params.prompt end, t.asked()),
      { "Clock-out in buffer wipe.org before killing it? ", "Save changed buffer?" })
    t.eq(t.eval("(org-clocking-p)"), "nil")
    match(t, vim.split(t.read_file(path), "\n"), { "* A", ":LOGBOOK:", CLOCK_ZERO, ":END:", "" }, "file")
    t.eq(require("emacs").statusline(), "", "statusline")
  end,
}
