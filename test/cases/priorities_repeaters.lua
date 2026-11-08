-- Priorities (C-c , and S-up/S-down) and repeating tasks: C-c C-t to DONE
-- on +, ++ and .+ repeaters, LAST_REPEAT and the state-change log, and
-- deadlines with warning periods. Expectations come from the same commands
-- in emacs -Q --batch -l test/init.el, with post-command-hook run as the
-- command loop does (org writes the repeat log from it).

local date_in = require("dates").org

-- Lua pattern for an inactive timestamp of today with a time.
local function now_pattern()
  return "%[" .. os.date("%Y-%m-%d %a"):gsub("%-", "%%-") .. " %d%d:%d%d%]"
end

local LOG_LINE = '^%- State "DONE"       from "TODO"       '

return {
  ["C-c , reads the priority from its menu"] = function(t)
    t.open("prio_menu.org", "* TODO Task\n")
    t.answer("A")
    t.keys("C-c ,")
    t.eq(t.lines(), { "* TODO [#A] Task" })
    t.eq(t.asked()[1].method, "read_key")
  end,

  ["C-c , SPC removes the priority"] = function(t)
    t.open("prio_spc.org", "* TODO [#B] Task\n")
    t.answer("SPC")
    t.keys("C-c ,")
    t.eq(t.lines(), { "* TODO Task" })
  end,

  ["C-c , in the body sets the heading's priority"] = function(t)
    t.open("prio_body.org", "* TODO Task\nbody\n")
    t.cursor(2, 2)
    t.answer("C")
    t.keys("C-c ,")
    t.eq(t.lines(), { "* TODO [#C] Task", "body" })
    t.eq(vim.api.nvim_win_get_cursor(0)[1], 2, "cursor stays in the body")
  end,

  ["S-up from C and S-down past A on a plain heading"] = function(t)
    t.open("prio_shift.org", "* TODO [#C] Task\n* [#A] Plain\n")
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* TODO [#B] Task")
    t.cursor(2)
    t.keys("<S-down>")
    t.keys("<S-down>")
    t.eq(t.lines()[2], "* [#C] Plain")
  end,

  ["DONE on a +1w repeater shifts one week and returns to TODO"] = function(t)
    t.set("org-log-repeat", "nil")
    t.open("rep_plus.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* TODO Task", "SCHEDULED: <2026-11-09 Mon +1w>" })
  end,

  ["DONE on ++1d and ++1w catches up past today"] = function(t)
    t.set("org-log-repeat", "nil")
    t.open("rep_catch.org", ("* TODO Daily\nSCHEDULED: <%s ++1d>\n* TODO Weekly\nSCHEDULED: <%s ++1w>\n")
      :format(date_in(-3), date_in(-14)))
    t.answer("d")
    t.keys("C-c C-t")
    t.cursor(3)
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* TODO Daily", "SCHEDULED: <" .. date_in(1) .. " ++1d>",
      "* TODO Weekly", "SCHEDULED: <" .. date_in(7) .. " ++1w>" })
  end,

  ["++1d more than 10 intervals behind asks before catching up"] = function(t)
    t.set("org-log-repeat", "nil")
    t.open("rep_far.org", ("* TODO Task\nSCHEDULED: <%s ++1d>\n"):format(date_in(-30)))
    t.answer("d", true)
    t.keys("C-c C-t")
    t.eq(t.asked()[2].method, "confirm")
    assert(t.asked()[2].params.prompt:find("10 repeater intervals were not enough", 1, true),
      vim.inspect(t.asked()[2]))
    t.eq(t.lines(), { "* TODO Task", "SCHEDULED: <" .. date_in(1) .. " ++1d>" })
  end,

  ["DONE on .+2d shifts from today"] = function(t)
    t.set("org-log-repeat", "nil")
    t.open("rep_dot.org", "* TODO Task\nSCHEDULED: <2026-10-01 Thu .+2d>\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* TODO Task", "SCHEDULED: <" .. date_in(2) .. " .+2d>" })
  end,

  ["a deadline keeps its warning period when it repeats"] = function(t)
    t.set("org-log-repeat", "nil")
    t.open("rep_dl.org", "* TODO Task\nDEADLINE: <2026-11-10 Tue +1m -3d>\n* TODO Both\n"
      .. "DEADLINE: <2026-11-20 Fri -5d> SCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.cursor(3)
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* TODO Task", "DEADLINE: <2026-12-10 Thu +1m -3d>", "* TODO Both",
      "DEADLINE: <2026-11-20 Fri -5d> SCHEDULED: <2026-11-09 Mon +1w>" })
  end,

  ["org-log-repeat time writes LAST_REPEAT and a state line"] = function(t)
    t.set("org-log-repeat", "'time")
    local path = t.open("rep_log.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    local l = t.lines()
    t.eq(#l, 6, vim.inspect(l))
    t.eq({ l[1], l[2], l[3], l[5] }, { "* TODO Task", "SCHEDULED: <2026-11-09 Mon +1w>", ":PROPERTIES:", ":END:" })
    assert(l[4]:find("^:LAST_REPEAT: " .. now_pattern() .. "$"), l[4])
    assert(l[6]:find(LOG_LINE .. now_pattern() .. "$"), l[6])
    t.eq(t.emacs_lines(path), l, "Emacs has the same text")
  end,

  ["org-log-into-drawer puts the repeat log in LOGBOOK"] = function(t)
    t.set("org-log-repeat", "'time")
    t.set("org-log-into-drawer", "t")
    t.open("rep_drawer.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    local l = t.lines()
    t.eq(#l, 8, vim.inspect(l))
    t.eq({ l[5], l[6], l[8] }, { ":END:", ":LOGBOOK:", ":END:" })
    assert(l[7]:find(LOG_LINE .. now_pattern() .. "$"), l[7])
  end,

  ["org-log-repeat note opens the note buffer and C-c C-c stores it"] = function(t)
    t.set("org-log-repeat", "'note")
    local path = t.open("rep_note.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "*Org Note*", "note buffer shown")
    t.eq(t.lines()[1], '# Insert note for state change from "TODO" to "DONE".')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "fixed it" })
    t.keys("C-c C-c")
    local l = t.emacs_lines(path)
    t.eq(#l, 7, vim.inspect(l))
    t.eq(l[2], "SCHEDULED: <2026-11-09 Mon +1w>")
    assert(l[6]:find(LOG_LINE .. now_pattern() .. " \\\\$"), l[6])
    t.eq(l[7], "  fixed it")
  end,

  ["C-c C-d on a repeating deadline keeps its repeater and warning"] = function(t)
    t.open("rep_redate.org", "* TODO Task\nDEADLINE: <2026-11-10 Tue +1m -3d>\n")
    t.answer("2026-12-01")
    t.keys("C-c C-d")
    t.eq(t.lines(), { "* TODO Task", "DEADLINE: <2026-12-01 Tue +1m -3d>" })
    t.eq(t.asked()[1].params.prompt, "DEADLINE Date+time [2026-11-10]: ")
  end,

  ["org-todo-repeat-to-state sets the state after a repeat"] = function(t)
    t.set("org-log-repeat", "nil")
    t.set("org-todo-repeat-to-state", '"NEXT"')
    t.open("rep_next.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* NEXT Task", "SCHEDULED: <2026-11-09 Mon +1w>" })
  end,

  ["S-right through NEXT to DONE repeats the task"] = function(t)
    t.set("org-log-repeat", "nil")
    t.open("rep_sright.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.keys("<S-right>")
    t.eq(t.lines()[1], "* NEXT Task")
    t.keys("<S-right>")
    t.eq(t.lines(), { "* TODO Task", "SCHEDULED: <2026-11-09 Mon +1w>" })
  end,

  ["clearing the keyword on a repeater does not shift it"] = function(t)
    t.set("org-log-repeat", "nil")
    t.open("rep_clear.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("SPC")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* Task", "SCHEDULED: <2026-11-02 Mon +1w>" })
  end,

  ["DONE on a non-repeating deadline adds CLOSED before it"] = function(t)
    t.set("org-log-done", "'time")
    t.open("dl_closed.org", "* TODO Task\nDEADLINE: <2026-11-10 Tue -3d>\n")
    t.answer("d")
    t.keys("C-c C-t")
    local l = t.lines()
    t.eq(#l, 2, vim.inspect(l))
    t.eq(l[1], "* DONE Task")
    assert(l[2]:find("^CLOSED: " .. now_pattern() .. " DEADLINE: <2026%-11%-10 Tue %-3d>$"), l[2])
  end,

  ["S-up with the cursor on the cookie, and on a timestamp after it"] = function(t)
    t.open("prio_col.org", "* TODO [#B] Task\n* TODO [#B] Task <2026-11-10 Tue>\n")
    t.cursor(1, 8)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* TODO [#A] Task", "on the cookie")
    t.cursor(2, 20)
    t.keys("<S-up>")
    t.eq(t.lines()[2], "* TODO [#B] Task <2027-11-10 Wed>", "on the timestamp's year")
  end,

  ["one undo reverts a logged repeat"] = function(t)
    t.set("org-log-repeat", "'time")
    local path = t.open("rep_undo.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(#t.lines(), 6)
    vim.cmd("silent undo")
    t.eq(t.lines(), { "* TODO Task", "SCHEDULED: <2026-11-02 Mon +1w>" })
    -- Neovim edits reach Emacs on a debounced sync; run it now.
    require("emacs.mirror").sync()
    t.eq(t.emacs_lines(path), t.lines(), "Emacs follows the undo")
  end,

  ["C-c , with a key outside A-C or C-g leaves the priority"] = function(t)
    t.open("prio_bad.org", "* TODO [#B] Task\n")
    t.answer("x")
    pcall(t.keys, "C-c ,") -- Emacs signals "Priority must be between A and C"
    t.eq(t.lines(), { "* TODO [#B] Task" }, "bad key")
    t.answer(t.QUIT)
    pcall(t.keys, "C-c ,")
    t.eq(t.lines(), { "* TODO [#B] Task" }, "C-g")
  end,

  ["C-c C-k in the note buffer drops the note but keeps the repeat"] = function(t)
    t.set("org-log-repeat", "'note")
    local path = t.open("rep_note_k.org", "* TODO Task\nSCHEDULED: <2026-11-02 Mon +1w>\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.keys("C-c C-k")
    local l = t.emacs_lines(path)
    t.eq(#l, 5, vim.inspect(l))
    t.eq({ l[1], l[2], l[3], l[5] }, { "* TODO Task", "SCHEDULED: <2026-11-09 Mon +1w>", ":PROPERTIES:", ":END:" })
    assert(l[4]:find("^:LAST_REPEAT: " .. now_pattern() .. "$"), l[4])
    t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "rep_note_k.org", "back in the file")
    t.eq(t.lines(), l)
  end,
}
