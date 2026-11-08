-- Editing from the agenda: priority, deadline, > reschedule, clocking,
-- bulk schedule/refile, category and regexp filters, log mode and agenda
-- undo, with the org file mirrors following every change.
local api = vim.api

local org_date = require("dates").org

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function lines_of(path) return api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false) end

-- a.org is open in Neovim; b.org is only an agenda file.
local function setup(t)
  local a = t.open("a.org", "* TODO Write report :work:\n* TODO Call Bob :home:\n* NEXT Plan trip :work:\n")
  local b = t.file("b.org", "* TODO Pay rent :home:\n* TODO Read book\n")
  t.eval(([[(setq org-agenda-files (list %q %q))]]):format(a, b))
  return a, b
end

-- The global TODO list: line 3 Write report, 4 Call Bob, 5 Plan trip,
-- 6 Pay rent, 7 Read book.
local function todo_list(t)
  t.answer("t")
  t.command("org-agenda")
  assert(api.nvim_buf_get_name(0):find("Org Agenda"), "agenda focused")
end

-- Week agenda over a.org with two items scheduled today.
local function week(t, text)
  local a = t.open("day.org", text)
  t.eval(([[(setq org-agenda-files (list %q))]]):format(a))
  t.answer("a")
  t.command("org-agenda")
  return a
end

return {
  -- Org realigns the tags of the heading it changes.
  [", sets the priority of the entry"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer("A")
    press(",")
    t.eq(lines_of(a), { "* TODO Write report :work:", t.aligned("* TODO [#A] Call Bob", ":home:"),
      "* NEXT Plan trip :work:" })
    assert(t.find_line("TODO %[#A%] Call Bob"), "agenda line updated:\n" .. table.concat(t.lines(), "\n"))
  end,

  ["C-c C-d adds a deadline in a file only the agenda opened"] = function(t)
    local _, b = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Read book"))
    t.answer("2026-11-20")
    t.keys("C-c C-d")
    t.eq(t.asked()[2].params.prompt, "DEADLINE Date+time [" .. os.date("%Y-%m-%d") .. "]: ")
    t.eq(lines_of(b), { "* TODO Pay rent :home:", "* TODO Read book", "DEADLINE: <2026-11-20 Fri>" })
    t.eq(t.emacs_lines(b), lines_of(b), "Emacs agrees")
  end,

  ["> moves the entry's date to the one typed"] = function(t)
    local a = week(t, ("* TODO Write report\nSCHEDULED: <%s>\n* TODO Call Bob\nSCHEDULED: <%s>\n"):format(
      org_date(0), org_date(0)))
    t.cursor(t.find_line("Call Bob"))
    t.answer("2026-11-20")
    press(">")
    t.eq(t.asked()[2].params.prompt, "Date+time [" .. os.date("%Y-%m-%d") .. "]: ")
    t.eq(lines_of(a), { "* TODO Write report", "SCHEDULED: <" .. org_date(0) .. ">", "* TODO Call Bob",
      "SCHEDULED: <2026-11-20 Fri>" })
  end,

  -- Emacs: "Not allowed in 'todo'-type agenda buffer or component".
  ["> in the TODO list refuses without asking or editing"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    pcall(press, ">")
    t.eq(#t.asked(), 1, "no date prompt")
    t.eq(lines_of(a), { "* TODO Write report :work:", "* TODO Call Bob :home:", "* NEXT Plan trip :work:" })
  end,

  ["I clocks in and O clocks out, logging into the file mirror"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.after(function() t.eval("(when (org-clocking-p) (org-clock-cancel))") end)
    t.cursor(t.find_line("Call Bob"))
    press("I")
    t.eq(t.eval("(and (org-clocking-p) t)"), "t")
    local stamp = "%[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]"
    local lines = lines_of(a)
    t.eq({ lines[2], lines[3], lines[5], lines[6] },
      { "* TODO Call Bob :home:", ":LOGBOOK:", ":END:", "* NEXT Plan trip :work:" })
    assert(lines[4]:find("^CLOCK: " .. stamp .. "$"), lines[4])
    press("O")
    t.eq(t.eval("(org-clocking-p)"), "nil")
    lines = lines_of(a)
    assert(lines[4]:find("^CLOCK: " .. stamp .. "%-%-" .. stamp .. " =>  0:00$"), lines[4])
    t.eq(t.emacs_lines(a), lines, "Emacs agrees")
  end,

  ["B s schedules every marked entry"] = function(t)
    local a, b = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Write report"))
    t.keys("m")
    t.cursor(t.find_line("Pay rent"))
    t.keys("m")
    t.answer("s", "2026-11-20")
    press("B")
    t.eq(t.asked()[3].params.prompt, "(Re)Schedule to Date+time [" .. os.date("%Y-%m-%d") .. "]: ")
    t.eq(lines_of(a), { "* TODO Write report :work:", "SCHEDULED: <2026-11-20 Fri>", "* TODO Call Bob :home:",
      "* NEXT Plan trip :work:" })
    t.eq(lines_of(b), { "* TODO Pay rent :home:", "SCHEDULED: <2026-11-20 Fri>", "* TODO Read book" })
  end,

  ["B r refiles every marked entry under one heading"] = function(t)
    local a, b = setup(t)
    t.set("org-refile-targets", "'((org-agenda-files :level . 1))")
    todo_list(t)
    t.cursor(t.find_line("Write report"))
    t.keys("m")
    t.cursor(t.find_line("Read book"))
    t.keys("m")
    t.answer("r", "Plan trip")
    press("B")
    t.eq(lines_of(a), { "* TODO Call Bob :home:", "* NEXT Plan trip :work:",
      t.aligned("** TODO Write report", ":work:"), "** TODO Read book" })
    t.eq(lines_of(b), { "* TODO Pay rent :home:" })
    assert(t.find_line("a:%s+TODO Read book"), "agenda rebuilt:\n" .. table.concat(t.lines(), "\n"))
  end,

  -- Emacs makes lines 3-5 (a.org's entries) invisible.
  ["< filters by the category at point, and | clears it"] = function(t)
    setup(t)
    todo_list(t)
    t.cursor(t.find_line("Pay rent"))
    press("<")
    t.eq(t.eval("org-agenda-category-filter"), '("+b")')
    t.eq(t.folds(), { "2-5" })
    press("|")
    t.eq(t.folds(), {})
  end,

  -- Emacs makes lines 3, 5 and 7 invisible.
  ["= filters by regexp, and | clears it"] = function(t)
    setup(t)
    todo_list(t)
    t.answer([[Bob\|rent]])
    press("=")
    t.eq(t.asked()[2].params.prompt, "Narrow to entries matching regexp: ")
    t.eq(t.folds(), { "2-3", "4-5", "6-7" })
    press("|")
    t.eq(t.folds(), {})
  end,

  ["l shows clocked and closed items, and l again hides them"] = function(t)
    local today = org_date(0)
    week(t, ("* DONE Filed taxes\nCLOSED: [%s 10:00]\n* TODO Write report\nSCHEDULED: <%s>\n"
      .. ":LOGBOOK:\nCLOCK: [%s 08:00]--[%s 09:30] =>  1:30\n:END:\n"):format(today, today, today, today))
    t.after(function() t.eval("(setq org-agenda-show-log nil)") end)
    assert(not t.find_line("Clocked:"), "no log before l")
    press("l")
    assert(t.find_line("8:00%-9:30  Clocked:   %(1:30%) TODO Write report"), table.concat(t.lines(), "\n"))
    assert(t.find_line("10:00%.%.%.%.%.%. Closed:     DONE Filed taxes"), table.concat(t.lines(), "\n"))
    press("l")
    assert(not t.find_line("Clocked:") and not t.find_line("Closed:"), table.concat(t.lines(), "\n"))
  end,

  -- Undo restores the tags org realigned too.
  ["C-_ in the agenda undoes t in the file and the agenda"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer("d")
    press("t")
    t.eq(lines_of(a)[2], t.aligned("* DONE Call Bob", ":home:"))
    t.keys("C-_")
    t.eq(lines_of(a), { "* TODO Write report :work:", "* TODO Call Bob :home:", "* NEXT Plan trip :work:" })
    t.eq(#t.lines(), 7, "agenda keeps its lines:\n" .. table.concat(t.lines(), "\n"))
    assert(t.find_line("a:%s+TODO Call Bob"), "agenda line restored:\n" .. table.concat(t.lines(), "\n"))
  end,

  ["C-_ twice undoes two agenda edits in two files"] = function(t)
    local a, b = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer("d")
    press("t")
    t.cursor(t.find_line("Pay rent"))
    t.answer("B")
    press(",")
    t.keys("C-_")
    t.eq(lines_of(b), { "* TODO Pay rent :home:", "* TODO Read book" }, "priority undone")
    t.eq(lines_of(a)[2], t.aligned("* DONE Call Bob", ":home:"), "todo kept")
    t.keys("C-_")
    t.eq(lines_of(a), { "* TODO Write report :work:", "* TODO Call Bob :home:", "* NEXT Plan trip :work:" },
      "todo undone")
    assert(t.find_line("a:%s+TODO Call Bob"), table.concat(t.lines(), "\n"))
  end,

  -- C-u reaches a key the agenda forwards: in the TODO list, C-u r asks
  -- for a keyword and lists only its entries (org's manual, "r").
  ["C-u r in the TODO list asks for a keyword and lists only it"] = function(t)
    local path = t.open("cu_redo.org", "* TODO Call Bob\n* NEXT Other\n")
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    t.set("org-todo-keywords", [['((sequence "TODO" "NEXT" "|" "DONE"))]])
    t.answer("t")
    t.command("org-agenda")
    t.answer("NEXT")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-u>r", true, false, true), "xt", false)
    t.eq(t.asked()[2].params.prompt, "Keyword (or KWD1|KWD2|...): ")
    assert(t.find_line("NEXT Other") and not t.find_line("Call Bob"), table.concat(t.lines(), "\n"))
  end,
}
