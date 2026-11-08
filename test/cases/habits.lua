-- org-habit: a .+1d/3d habit in the agenda with its consistency graph,
-- marked DONE from the agenda and the file, K, and the only-for-today option.
-- Expected text: emacs -Q --batch -l test/init.el with org-habit, same day.
local api = vim.api
local mirror = require("emacs.mirror")

local AGENDA = "*Org Agenda*"
local NS = api.nvim_create_namespace("emacs")

local org_date = require("dates").org

-- Done yesterday and three days ago; due today.
local function habit_text()
  return table.concat({
    "* TODO Exercise",
    "SCHEDULED: <" .. org_date(0) .. " .+1d/3d>",
    ":PROPERTIES:",
    ":STYLE:    habit",
    ":LAST_REPEAT: [" .. org_date(-1) .. " 08:00]",
    ":END:",
    ":LOGBOOK:",
    '- State "DONE"       from "TODO"       [' .. org_date(-1) .. " 08:00]",
    '- State "DONE"       from "TODO"       [' .. org_date(-3) .. " 08:00]",
    ":END:",
    "",
  }, "\n")
end

-- A log note made now, as Emacs writes it.
local TODAY_NOTE = vim.pesc('- State "DONE"       from "TODO"       [' .. org_date(0)) .. " %d%d:%d%d%]"

-- habits.org open in Neovim as the only agenda file, org-habit loaded, a
-- one-day agenda. Loading org-habit binds K in the agenda; unloading it
-- doesn't, so the key is cleared by hand.
local function setup(t)
  local path = t.open("habits.org", habit_text())
  t.eval("(require 'org-habit)")
  t.after(function()
    t.eval([[(progn (unload-feature 'org-habit t) (define-key org-agenda-mode-map "K" nil))]])
  end)
  t.set("org-agenda-files", ("(list %q)"):format(path))
  t.set("org-directory", ("%q"):format(t.WORK))
  t.set("org-agenda-span", "'day")
  return path, api.nvim_get_current_buf()
end

local function agenda(t)
  t.answer("a")
  t.command("org-agenda")
  assert(api.nvim_buf_get_name(0):find("Org Agenda"), "agenda focused")
end

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function agree(t, buffer, buf, what)
  mirror.sync()
  t.eq(api.nvim_buf_get_lines(buf, 0, -1, false), t.emacs_lines(buffer), (what or "") .. " Emacs agrees")
end

-- The file's lines with today's note times written as HH:MM.
local function untimed(lines)
  return vim.tbl_map(function(l)
    return (l:gsub("%[(" .. vim.pesc(org_date(0)) .. ") %d%d:%d%d%]", "[%1 HH:MM]"))
  end, lines)
end

local HABIT_LINE = "^  habits:     TODO Exercise%s+%* %*!%s+$"

return {
  ["the day agenda shows the habit with its graph as Emacs does"] = function(t)
    setup(t)
    agenda(t)
    local row = t.find_line("Exercise")
    assert(row and t.lines()[row]:find(HABIT_LINE), "habit line:\n" .. table.concat(t.lines(), "\n"))
    agree(t, AGENDA, 0, "agenda")
  end,

  -- Emacs paints every graph cell, blanks included, with a background:
  -- org-habit-clear-face is "blue", ready "forestgreen", and so on.
  ["every graph cell carries its org-habit face with Emacs's background color"] = function(t)
    setup(t)
    agenda(t)
    local row = t.find_line("Exercise") - 1
    local want = vim.json.decode(vim.json.decode(t.eval(([[(with-current-buffer %q
      (goto-char (point-min)) (search-forward "Exercise")
      (let (out (p (line-beginning-position)))
        (while (< p (line-end-position))
          (let ((f (get-text-property p 'face)))
            (when (and f (symbolp f) (string-prefix-p "org-habit" (symbol-name f)))
              (push (format "[%%d,%%S]" (- p (line-beginning-position)) (symbol-name f)) out)))
          (setq p (1+ p)))
        (concat "[" (mapconcat #'identity (nreverse out) ",") "]")))]]):format(AGENDA))))
    -- org-habit steps back 21 x 24 hours, so late in the day after a clock
    -- change its graph is a day short: only its rough size is fixed.
    assert(#want > 20, "Emacs's graph cells: " .. #want)
    local marks = api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })
    local got, missing = {}, {}
    for _, cell in ipairs(want) do
      local col, face = cell[1], cell[2]
      local group
      for _, m in ipairs(marks) do
        local d = m[4]
        if d.hl_group and m[3] <= col and col < (d.end_col or m[3] + 1) and d.hl_group:find("org_habit") then
          group = d.hl_group
        end
      end
      if not group then
        missing[#missing + 1] = col .. ":" .. face
      else
        t.eq(group, "EmacsFace_" .. face:gsub("[^%w]", "_"), "face at col " .. col)
        local bg = api.nvim_get_hl(0, { name = group, link = false }).bg
        local emacs_bg = vim.json.decode(t.eval(("(face-attribute '%s :background nil t)"):format(face)))
        if bg ~= api.nvim_get_color_by_name(emacs_bg) then got[#got + 1] = col .. ":" .. face .. ":" .. emacs_bg end
      end
    end
    t.eq(missing, {}, "graph cells without a highlight")
    t.eq(got, {}, "graph cells whose background isn't Emacs's")
  end,

  -- Emacs: the line turns "DONE Exercise" without a graph; the file is
  -- rescheduled from today, LAST_REPEAT set, the note goes into LOGBOOK.
  ["t d in the agenda reschedules the habit from today and logs it in the drawer"] = function(t)
    local path, file_buf = setup(t)
    t.set("org-log-into-drawer", "t")
    agenda(t)
    t.cursor(t.find_line("Exercise"))
    t.answer("d")
    press("t")
    t.eq(api.nvim_get_current_line(), "  habits:     DONE Exercise", "agenda line")
    t.eq(untimed(api.nvim_buf_get_lines(file_buf, 0, -1, false)), {
      "* TODO Exercise",
      "SCHEDULED: <" .. org_date(1) .. " .+1d/3d>",
      ":PROPERTIES:",
      ":STYLE:    habit",
      ":LAST_REPEAT: [" .. org_date(0) .. " HH:MM]",
      ":END:",
      ":LOGBOOK:",
      '- State "DONE"       from "TODO"       [' .. org_date(0) .. " HH:MM]",
      '- State "DONE"       from "TODO"       [' .. org_date(-1) .. " 08:00]",
      '- State "DONE"       from "TODO"       [' .. org_date(-3) .. " 08:00]",
      ":END:",
    }, "Neovim's habits.org")
    agree(t, path, file_buf, "file")
    agree(t, AGENDA, 0, "agenda")
  end,

  -- Emacs: rescheduled to tomorrow, the habit leaves today's agenda on r;
  -- with org-habit-show-all-today it stays, today's cell now a "*".
  ["r after t d drops the habit; show-all-today keeps it with today marked"] = function(t)
    setup(t)
    t.set("org-log-into-drawer", "t")
    agenda(t)
    t.cursor(t.find_line("Exercise"))
    t.answer("d")
    press("t")
    press("r")
    t.eq(t.find_line("Exercise"), nil, "habit gone after r")
    agree(t, AGENDA, 0, "agenda")
    t.set("org-habit-show-all-today", "t")
    press("r")
    local row = t.find_line("Exercise")
    assert(row and t.lines()[row]:find("TODO Exercise%s+%* %*%*%s+$"), "show-all-today:\n" .. table.concat(t.lines(), "\n"))
    agree(t, AGENDA, 0, "agenda")
  end,

  -- Emacs (with post-command-hook, as the command loop runs it): the note
  -- is stored above the LOGBOOK drawer, since org-log-into-drawer is nil.
  ["C-c C-t d in the file repeats the habit and stores the note"] = function(t)
    local path, file_buf = setup(t)
    t.cursor(1)
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(untimed(t.lines()), {
      "* TODO Exercise",
      "SCHEDULED: <" .. org_date(1) .. " .+1d/3d>",
      ":PROPERTIES:",
      ":STYLE:    habit",
      ":LAST_REPEAT: [" .. org_date(0) .. " HH:MM]",
      ":END:",
      '- State "DONE"       from "TODO"       [' .. org_date(0) .. " HH:MM]",
      ":LOGBOOK:",
      '- State "DONE"       from "TODO"       [' .. org_date(-1) .. " 08:00]",
      '- State "DONE"       from "TODO"       [' .. org_date(-3) .. " 08:00]",
      ":END:",
    })
    assert(t.lines()[7]:find(TODAY_NOTE), t.lines()[7])
    agree(t, path, file_buf, "file")
  end,

  -- Emacs: one C-/ undoes the whole state change, note included.
  ["C-_ after C-c C-t d restores the habit on both sides"] = function(t)
    local path, file_buf = setup(t)
    t.cursor(1)
    t.answer("d")
    t.keys("C-c C-t")
    t.keys("C-_")
    t.eq(t.lines(), vim.split(habit_text():gsub("\n$", ""), "\n", { plain = true }))
    agree(t, path, file_buf, "file")
  end,

  ["K hides habits in the agenda and shows them again"] = function(t)
    setup(t)
    agenda(t)
    press("K")
    t.eq(t.find_line("Exercise"), nil, "habit hidden")
    agree(t, AGENDA, 0, "agenda after K")
    press("K")
    local row = t.find_line("Exercise")
    assert(row and t.lines()[row]:find(HABIT_LINE), "habit back:\n" .. table.concat(t.lines(), "\n"))
    agree(t, AGENDA, 0, "agenda after K K")
  end,

  -- Emacs, a week from today: one habit line under today; with the option
  -- nil, one under each of the seven days.
  ["org-habit-show-habits-only-for-today decides how many days list the habit"] = function(t)
    setup(t)
    t.set("org-agenda-span", "'week")
    t.set("org-agenda-start-on-weekday", "nil")
    agenda(t)
    local function count()
      local n = 0
      for _, l in ipairs(t.lines()) do if l:find(HABIT_LINE) then n = n + 1 end end
      return n
    end
    t.eq(count(), 1, "only for today")
    agree(t, AGENDA, 0, "week agenda")
    t.set("org-habit-show-habits-only-for-today", "nil")
    press("r")
    t.eq(count(), 7, "every day")
    agree(t, AGENDA, 0, "week agenda, every day")
  end,

  -- Emacs: t d opens *Org Note*; C-c C-c stores "felt good" under the log
  -- line in LOGBOOK and returns to the agenda.
  ["t d with org-log-repeat note takes the note in *Org Note*"] = function(t)
    local path, file_buf = setup(t)
    t.set("org-log-into-drawer", "t")
    t.set("org-log-repeat", "'note")
    agenda(t)
    t.cursor(t.find_line("Exercise"))
    t.answer("d")
    press("t")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Org Note*", "note buffer shown")
    t.eq(t.lines()[1], '# Insert note for state change from "TODO" to "DONE".')
    api.nvim_buf_set_lines(0, -2, -1, false, { "felt good" })
    t.keys("C-c C-c")
    assert(api.nvim_buf_get_name(0):find("Org Agenda", 1, true), "back in the agenda: " .. api.nvim_buf_get_name(0))
    t.eq(untimed(api.nvim_buf_get_lines(file_buf, 6, 9, false)), {
      ":LOGBOOK:",
      '- State "DONE"       from "TODO"       [' .. org_date(0) .. " HH:MM] \\\\",
      "  felt good",
    }, "Neovim's LOGBOOK")
    agree(t, path, file_buf, "file")
    agree(t, AGENDA, 0, "agenda")
  end,

  -- Emacs: t d on any day's line changes them all to "TODO Exercise",
  -- graphs dropped, and repeats the habit from today.
  ["t d on a later day's habit line rewrites every day's line"] = function(t)
    local path, file_buf = setup(t)
    t.set("org-agenda-span", "'week")
    t.set("org-agenda-start-on-weekday", "nil")
    t.set("org-habit-show-habits-only-for-today", "nil")
    agenda(t)
    local rows = {}
    for i, l in ipairs(t.lines()) do if l:find("Exercise") then rows[#rows + 1] = i end end
    t.cursor(rows[3])
    t.answer("d")
    press("t")
    for _, row in ipairs(rows) do t.eq(t.lines()[row], "  habits:     TODO Exercise", "line " .. row) end
    t.eq(api.nvim_buf_get_lines(file_buf, 1, 2, false)[1], "SCHEDULED: <" .. org_date(1) .. " .+1d/3d>")
    agree(t, path, file_buf, "file")
    agree(t, AGENDA, 0, "agenda")
  end,
}
