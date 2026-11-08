-- Agenda views and display toggles: d/w/y and v d/w/m, f/b in the day
-- view, j (goto date), G, E, R, D, and F following j/k. Expectations are
-- from batch Emacs on the same files.
local api = vim.api

local dates = require("dates")
local org_date = dates.org

-- Pattern for the agenda's date header of a day: "Sunday      8 November 2026".
local function day_header(days)
  local time = dates.time(days)
  return "^" .. os.date("%A", time) .. "%s+" .. tonumber(os.date("%d", time)) .. os.date(" %B %Y", time)
end

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function cursor_text() return api.nvim_get_current_line() end

-- v.org (open in Neovim): Write report at 10:00 today with a body, Call Bob
-- today with 1:30 clocked today, Pay rent in three days.
local function setup(t)
  local today = org_date(0)
  local path = t.open("v.org", table.concat({
    "* TODO Write report",
    "SCHEDULED: <" .. today .. " 10:00>",
    "Report body line",
    "second body line",
    "* TODO Call Bob",
    "SCHEDULED: <" .. today .. ">",
    ":LOGBOOK:",
    "CLOCK: [" .. today .. " 08:00]--[" .. today .. " 09:30] =>  1:30",
    ":END:",
    "* TODO Pay rent",
    "SCHEDULED: <" .. org_date(3) .. ">",
    "",
  }, "\n"))
  t.eval(([[(progn (require 'org-agenda) (setq org-agenda-files (list %q)))]]):format(path))
  return path
end

local function week_agenda(t)
  t.answer("a")
  t.command("org-agenda")
  assert(api.nvim_buf_get_name(0):find("Org Agenda"), "agenda focused")
end

-- The day agenda for today ("d" from the week agenda).
local function day_agenda(t)
  week_agenda(t)
  press("d")
  t.eq(t.lines()[1], "Day-agenda (W" .. os.date("%V") .. "):")
end

-- A Neovim motion, then the CursorMoved that Neovim's main loop fires
-- after it (a headless -l script has no main loop, so fire it here).
local function move(keys)
  press(keys)
  api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

local function text(t) return table.concat(t.lines(), "\n") end

return {
  ["d switches to the day view and w back to the week"] = function(t)
    setup(t)
    week_agenda(t)
    press("d")
    t.eq(t.lines()[1], "Day-agenda (W" .. os.date("%V") .. "):")
    assert(t.lines()[2]:find(day_header(0)), text(t))
    t.eq(api.nvim_win_get_cursor(0)[1], 2, "cursor on today")
    assert(not t.find_line(day_header(1)), "one day only:\n" .. text(t))
    press("w")
    t.eq(t.lines()[1], "Week-agenda (W" .. os.date("%V") .. "):")
    assert(cursor_text():find(day_header(0)), "cursor on today: " .. cursor_text())
  end,

  ["y asks before the year view, which starts on 1 January"] = function(t)
    setup(t)
    week_agenda(t)
    t.answer(true)
    press("y")
    t.eq(t.asked()[2].method, "confirm")
    t.eq(t.asked()[2].params.prompt, "Are you sure you want to compute the agenda for an entire year? ")
    t.eq(t.lines()[1], "Year-agenda:")
    assert(t.lines()[2]:find("^%a+%s+1 January " .. os.date("%Y")), t.lines()[2])
    assert(cursor_text():find(day_header(0)), "cursor on today: " .. cursor_text())
  end,

  ["v d, v w and v m switch the span through the view menu"] = function(t)
    setup(t)
    week_agenda(t)
    t.answer("d")
    press("v")
    t.eq(t.asked()[2].method, "read_key")
    t.eq(t.lines()[1], "Day-agenda (W" .. os.date("%V") .. "):")
    t.answer("w")
    press("v")
    t.eq(t.lines()[1], "Week-agenda (W" .. os.date("%V") .. "):")
    t.answer("m")
    press("v")
    assert(t.lines()[1]:find("^Month%-agenda %(W%d+%-W%d+%):$"), t.lines()[1])
    assert(t.find_line("^%a+%s+1 " .. os.date("%B %Y")), "the month's first day:\n" .. text(t))
    assert(cursor_text():find(day_header(0)), "cursor on today: " .. cursor_text())
    assert(t.find_line("Scheduled:  TODO Pay rent"), "the month shows Pay rent:\n" .. text(t))
  end,

  ["f and b in the day view move one day, . comes back"] = function(t)
    setup(t)
    day_agenda(t)
    press("f")
    t.eq(t.lines()[1], "Day-agenda (W" .. os.date("%V", dates.time(1)) .. "):")
    assert(t.lines()[2]:find(day_header(1)), text(t))
    press("b")
    assert(t.lines()[2]:find(day_header(0)), text(t))
    press("ff.")
    assert(t.lines()[2]:find(day_header(0)), text(t))
    assert(t.find_line("Scheduled:  TODO Call Bob"), text(t))
  end,

  -- j is Neovim's motion in the agenda (mirror.config.passthrough), so
  -- send it as Emacs keys.
  ["j asks for a date and shows its week with the cursor on it"] = function(t)
    setup(t)
    week_agenda(t)
    t.answer(os.date("%Y-%m-%d", dates.time(10)))
    t.keys("j")
    t.eq(t.asked()[2].method, "read_string")
    t.eq(t.lines()[1], "Week-agenda (W" .. os.date("%V", dates.time(10)) .. "):")
    assert(cursor_text():find(day_header(10)), "cursor on the date: " .. cursor_text())
  end,

  -- G is Neovim's motion in the agenda (mirror.config.passthrough), so
  -- send it as Emacs keys.
  ["G hides the time grid, and G again shows it"] = function(t)
    setup(t)
    t.set("org-agenda-use-time-grid", "t")
    day_agenda(t)
    local grid = "^%s+8:00%.%.%.%.%.%. %-%-%-%-"
    assert(t.find_line(grid), text(t))
    t.keys("G")
    assert(not t.find_line(grid), text(t))
    t.eq(t.lines()[3], "  v:          10:00...... Scheduled:  TODO Write report")
    t.keys("G")
    assert(t.find_line(grid), text(t))
  end,

  ["E shows entry bodies under their lines, and E again hides them"] = function(t)
    setup(t)
    t.set("org-agenda-entry-text-mode", "nil")
    t.set("org-agenda-use-time-grid", "nil")
    day_agenda(t)
    local line = t.find_line("Scheduled:  TODO Write report")
    local function below()
      local out = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(0, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
        for _, vl in ipairs(m[4].virt_lines or {}) do
          out[#out + 1] = table.concat(vim.tbl_map(function(c) return c[1] end, vl))
        end
      end
      return out
    end
    t.eq(below(), {})
    press("E")
    t.eq(below(), { "    > Report body line", "    > second body line" })
    press("E")
    t.eq(below(), {})
  end,

  ["R appends the clock report table, and R again removes it"] = function(t)
    setup(t)
    t.set("org-agenda-clockreport-mode", "nil")
    day_agenda(t)
    press("R")
    t.eq(t.lines()[t.find_line("^| File")], "| File  | Headline         | Time   |")
    assert(t.find_line("^|%s+| ALL %*Total time%* | %*1:30%* |$"), text(t))
    assert(t.find_line("^| v%.org | %*File time%*%s+| %*1:30%* |$"), text(t))
    assert(t.find_line("%[%[file:.*v%.org::%*Call Bob%]%[Call Bob%]%]%s+| 1:30   |$"), text(t))
    press("R")
    assert(not t.find_line("^| File"), text(t))
  end,

  ["D adds the diary's entries for the day, and D again drops them"] = function(t)
    setup(t)
    local diary = t.file("diary", os.date("%m/%d/%Y", dates.time(0)) .. " Dentist visit\n")
    t.set("diary-file", ("%q"):format(diary))
    t.set("org-agenda-include-diary", "nil")
    day_agenda(t)
    assert(not t.find_line("Dentist"), text(t))
    press("D")
    assert(t.find_line("^  Diary:      Dentist visit$"), text(t))
    press("D")
    assert(not t.find_line("Dentist"), text(t))
  end,

  -- Emacs follows on each line move (C-n, <down>: org-agenda-next-line
  -- calls org-agenda-do-context-action); Neovim's j/k are line moves.
  ["F follows j and k in the file window"] = function(t)
    local path = setup(t)
    t.set("org-agenda-follow-mode", "nil")
    t.answer("t")
    t.command("org-agenda")
    local agenda_win = api.nvim_get_current_win()
    t.cursor(t.find_line("Write report"))
    press("F")
    local file_win = assert(vim.fn.win_findbuf(vim.fn.bufnr(path))[1], "v.org shown")
    local function file_line() return api.nvim_win_get_cursor(file_win)[1] end
    t.eq(file_line(), 1, "on Write report")
    move("j")
    vim.wait(2000, function() return file_line() == 5 end)
    t.eq(file_line(), 5, "follows j to Call Bob")
    move("j")
    vim.wait(2000, function() return file_line() == 10 end)
    t.eq(file_line(), 10, "follows j to Pay rent")
    move("k")
    vim.wait(2000, function() return file_line() == 5 end)
    t.eq(file_line(), 5, "follows k back to Call Bob")
    t.eq(api.nvim_get_current_win(), agenda_win, "agenda keeps focus")
  end,
}
