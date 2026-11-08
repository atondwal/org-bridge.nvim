-- Dates and times beyond the basics: inactive stamps, times and ranges in
-- org-read-date answers, C-c . twice, S-arrows on hour/minute/range parts,
-- C-c C-y, C-u C-c ., C-c C-o to the agenda, C-c < without a calendar.
-- Expected text comes from emacs -Q --batch -l test/init.el (prompts stubbed).

local date_in = require("dates").org

-- Heading, an empty line to insert on, a body line.
local DOC = "* T\n\nbody\n"

local function agree(t, path) t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees") end

return {
  ["C-c ! inserts an inactive timestamp; a time and a time range go inside it"] = function(t)
    local path = t.open("inactive.org", DOC)
    t.cursor(2)
    t.answer("2026-12-25")
    t.keys("C-c !")
    t.eq(t.lines(), { "* T", "[2026-12-25 Fri]", "body" }, "date only")
    t.open("inactive_t.org", DOC)
    t.cursor(2)
    t.answer("2026-12-25 10:00-11:30")
    t.keys("C-c !")
    t.eq(t.lines(), { "* T", "[2026-12-25 Fri 10:00-11:30]", "body" }, "time range")
    t.eq(t.asked()[1].params.prompt, "Date+time [" .. os.date("%Y-%m-%d") .. "]: ")
    agree(t, t.WORK .. "/inactive_t.org")
    t.eq(t.emacs_lines(path), { "* T", "[2026-12-25 Fri]", "body" }, "first file kept")
  end,

  ["C-c . reads a time alone as today and +2d 9am as two days ahead at 09:00"] = function(t)
    t.open("time_only.org", DOC)
    t.cursor(2)
    t.answer("14:00")
    t.keys("C-c .")
    t.eq(t.lines()[2], "<" .. date_in(0) .. " 14:00>", "14:00")
    local path = t.open("rel_time.org", DOC)
    t.cursor(2)
    t.answer("+2d 9am")
    t.keys("C-c .")
    t.eq(t.lines()[2], "<" .. date_in(2) .. " 09:00>", "+2d 9am")
    agree(t, path)
  end,

  ["C-c ! on an existing stamp replaces it"] = function(t)
    local path = t.open("replace.org", "* T [2026-11-07 Sat]\n")
    t.cursor(1, 6)
    t.answer("2026-12-25 10:00")
    t.keys("C-c !")
    t.eq(t.lines(), { "* T [2026-12-25 Fri 10:00]" })
    agree(t, path)
  end,

  -- Emacs: the second C-c . right after the first (last-command) makes a
  -- range, then C-u C-c C-y appends its length.
  ["C-c . twice makes a range; C-u C-c C-y inserts its length"] = function(t)
    local path = t.open("range.org", DOC)
    t.cursor(2)
    t.answer("2026-12-25")
    t.keys("C-c .")
    t.answer("2026-12-28")
    t.keys("C-c .")
    t.eq(t.lines(), { "* T", "<2026-12-25 Fri>--<2026-12-28 Mon>", "body" }, "range")
    t.eq(t.asked()[2].params.prompt, "Date+time [2026-12-25]: ", "second prompt defaults to the first date")
    t.keys("C-c C-y", 4)
    t.eq(t.lines(), { "* T", "<2026-12-25 Fri>--<2026-12-28 Mon> 3d", "body" }, "C-u C-c C-y")
    agree(t, path)
  end,

  ["C-c ! twice makes an inactive range"] = function(t)
    local path = t.open("irange.org", DOC)
    t.cursor(2)
    t.answer("2026-12-25", "2026-12-28")
    t.keys("C-c !")
    t.keys("C-c !")
    t.eq(t.lines(), { "* T", "[2026-12-25 Fri]--[2026-12-28 Mon]", "body" })
    agree(t, path)
  end,

  ["C-c C-y leaves the text alone; C-u C-c C-y appends days and hours"] = function(t)
    local path = t.open("eval.org", "* T <2026-11-07 Sat 10:00>--<2026-11-10 Tue 12:30>\n")
    t.cursor(1, 7)
    t.keys("C-c C-y")
    t.eq(t.lines(), { "* T <2026-11-07 Sat 10:00>--<2026-11-10 Tue 12:30>" }, "plain: echo area only")
    t.cursor(1, 7)
    t.keys("C-c C-y", 4)
    t.eq(t.lines(), { "* T <2026-11-07 Sat 10:00>--<2026-11-10 Tue 12:30> 3d 02:30" })
    agree(t, path)
  end,

  ["S-up on the start hour of 10:00-11:30 moves the whole range; on the end hour only the end"] = function(t)
    local path = t.open("hrange.org", "* T <2026-11-07 Sat 10:00-11:30>\n")
    t.cursor(1, 20)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* T <2026-11-07 Sat 11:00-12:30>", "start hour")
    t.cursor(1, 26)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* T <2026-11-07 Sat 11:00-13:30>", "end hour")
    t.cursor(1, 23)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* T <2026-11-07 Sat 11:05-13:35>", "start minute, rounded to 5")
    agree(t, path)
  end,

  ["S-down on the hour keeps 10:32; on the minute it rounds down to 10:30"] = function(t)
    local path = t.open("round.org", "* T <2026-11-07 Sat 10:32>\n")
    t.cursor(1, 20)
    t.keys("<S-down>")
    t.eq(t.lines()[1], "* T <2026-11-07 Sat 09:32>", "hour")
    t.cursor(1, 23)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* T <2026-11-07 Sat 09:35>", "minute up to the next 5")
    agree(t, path)
  end,

  ["S-up on the second date of a range changes only that date"] = function(t)
    local path = t.open("drange.org", "* T <2026-11-07 Sat>--<2026-11-10 Tue>\n")
    t.cursor(1, 29)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* T <2026-11-07 Sat>--<2026-12-10 Thu>")
    agree(t, path)
  end,

  ["C-u C-c . with a date alone adds the current time"] = function(t)
    local path = t.open("cu.org", DOC)
    t.cursor(2)
    t.answer("2026-12-25")
    t.keys("C-c .", 4)
    local hh, mm = t.lines()[2]:match("^<2026%-12%-25 Fri (%d%d):(%d%d)>$")
    assert(hh, "date with a time: " .. vim.inspect(t.lines()))
    -- Unrounded: batch Emacs gives the minute as it is (09:54).
    t.eq(tonumber(mm) < 60, true)
    t.eq(t.asked()[1].params.prompt:match("^Date%+time %[%d+%-%d+%-%d+ %d%d:%d%d%]: $") ~= nil, true,
      "prompt shows a default time: " .. t.asked()[1].params.prompt)
    agree(t, path)
  end,

  ["C-c C-o on a timestamp opens the agenda for that day"] = function(t)
    local path = t.open("agenda_day.org", "* T <2026-12-25 Fri 10:00> xmas\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.cursor(1, 8)
    t.keys("C-c C-o")
    local found_day, found_entry = false, false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      for _, l in ipairs(t.lines(vim.api.nvim_win_get_buf(win))) do
        found_day = found_day or l:find("Friday     25 December 2026", 1, true) ~= nil
        found_entry = found_entry or l:find("10:00...... T xmas", 1, true) ~= nil
      end
    end
    t.eq({ found_day, found_entry }, { true, true }, "agenda shows the day and the entry")
  end,

  -- Emacs: "No buffer named *Calendar*", nothing inserted.
  ["C-c < with no calendar open fails and leaves the text alone"] = function(t)
    local path = t.open("cal.org", DOC)
    t.cursor(2)
    pcall(t.keys, "C-c <")
    t.eq(t.lines(), { "* T", "", "body" })
    agree(t, path)
    t.eq(vim.api.nvim_buf_get_name(0), path, "still in the org buffer")
  end,
}
