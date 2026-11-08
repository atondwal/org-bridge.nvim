-- Properties, deadlines, relative dates, S-arrows on timestamps and
-- priorities.

local date_in = require("dates").org

local function asked_summary(t)
  local out = {}
  for _, q in ipairs(t.asked()) do out[#out + 1] = q.method .. " " .. q.params.prompt end
  return out
end

return {
  ["C-c C-x p creates a properties drawer"] = function(t)
    t.open("prop.org", "* Task\nbody\n")
    t.answer("COLOR", "red")
    t.keys("C-c C-x p")
    t.eq(t.lines(), { "* Task", ":PROPERTIES:", ":COLOR:    red", ":END:", "body" })
    local asked = asked_summary(t)
    t.eq(#asked, 2, "two prompts: " .. vim.inspect(asked))
    assert(asked[1]:find("^completing_read Property"), vim.inspect(asked))
    t.eq(asked[2], "completing_read COLOR value: ")
  end,

  ["C-c C-x p adds to a drawer, and an empty value keeps the current one"] = function(t)
    t.open("prop2.org", "* Task\n:PROPERTIES:\n:COLOR: blue\n:END:\n")
    t.answer("SIZE", "big")
    t.keys("C-c C-x p")
    t.eq(t.lines(), { "* Task", ":PROPERTIES:", ":COLOR: blue", ":SIZE:     big", ":END:" })
    t.cursor(1)
    t.answer("COLOR", "")
    t.keys("C-c C-x p")
    t.eq(t.asked()[4].params.prompt, "COLOR value [blue]: ")
    t.eq(t.lines()[3], ":COLOR: blue")
  end,

  ["C-c C-d reads +3d relative to today"] = function(t)
    t.open("dl.org", "* Task\n")
    t.answer("+3d")
    t.keys("C-c C-d")
    t.eq(t.lines(), { "* Task", "DEADLINE: <" .. date_in(3) .. ">" })
    assert(t.asked()[1].params.prompt:find("^DEADLINE Date"), vim.inspect(t.asked()))
  end,

  ["C-c C-s reads a weekday name as the next such day"] = function(t)
    t.open("fri.org", "* Task\n")
    -- org-read-date-get-relative: "fri" on a Friday means a week ahead.
    local ahead = (6 - os.date("*t").wday) % 7
    if ahead == 0 then ahead = 7 end
    t.answer("fri")
    t.keys("C-c C-s")
    t.eq(t.lines()[2], "SCHEDULED: <" .. date_in(ahead) .. ">")
  end,

  ["a single + shifts from today, not from the old deadline"] = function(t)
    t.open("dl2.org", "* Task\nDEADLINE: <2030-01-15 Tue>\n")
    t.answer("+1w")
    t.keys("C-c C-d")
    t.eq(t.lines()[2], "DEADLINE: <" .. date_in(7) .. ">")
    t.eq(t.asked()[1].params.prompt, "DEADLINE Date+time [2030-01-15]: ")
  end,

  ["S-up and S-down change the timestamp field under the cursor"] = function(t)
    t.open("ts.org", "* M <2026-11-07 Sat 10:30>\n")
    t.cursor(1, 13)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* M <2026-11-08 Sun 10:30>", "day")
    t.cursor(1, 10)
    t.keys("<S-down>")
    t.eq(t.lines()[1], "* M <2026-10-08 Thu 10:30>", "month")
    t.cursor(1, 6)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* M <2027-10-08 Fri 10:30>", "year")
    t.cursor(1, 24)
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* M <2027-10-08 Fri 10:35>", "minute, rounded to 5")
  end,

  ["S-up and S-down cycle the priority cookie"] = function(t)
    t.open("prio.org", "* TODO [#B] Task\n")
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* TODO [#A] Task")
    t.keys("<S-up>")
    t.eq(t.lines()[1], "* TODO Task", "up from A removes it")
    t.keys("<S-down>")
    t.eq(t.lines()[1], "* TODO [#B] Task", "down from none starts at the default")
    t.keys("<S-down>")
    t.keys("<S-down>")
    t.eq(t.lines()[1], "* TODO Task", "down from C removes it")
  end,

  ["a date prompt previews the date as you type"] = function(t)
    t.open("preview.org", "* Task\n")
    local rpc = require("emacs.rpc")
    local seen, scripted = nil, rpc.handlers.read_string
    t.after(function() rpc.handlers.read_string = scripted end)
    rpc.handlers.read_string = function(p)
      seen = { p.date, rpc.call("date_preview", { text = "2026-12-01" }),
        rpc.call("date_preview", { text = "2026-1" }) }
      return "2026-12-01"
    end
    t.keys("C-c C-s")
    t.eq(seen[1], true, "flagged as a date prompt")
    t.eq(seen[2].text, "=> <2026-12-01 Tue>")
    local month = seen[2].calendar[1]:find("December 2026", 1, true)
    assert(month and month > 20, "December in the middle: " .. vim.inspect(seen[2].calendar))
    local row, col = seen[2].cursor[1], seen[2].cursor[2]
    t.eq(seen[2].calendar[row + 1]:sub(col + 1, col + 2), " 1")
    t.eq(t.lines()[2], "SCHEDULED: <2026-12-01 Tue>")
  end,

  -- Keys in the date prompt run Emacs's calendar commands, so they move the
  -- date as in org: the months shown scroll only when the date leaves them.
  ["date prompt keys move the date as Emacs's calendar does"] = function(t)
    t.open("shift.org", "* Task\n")
    local rpc = require("emacs.rpc")
    local seen, scripted = nil, rpc.handlers.read_string
    t.after(function() rpc.handlers.read_string = scripted end)
    local function move(text, command, view)
      return rpc.call("date_move", { text = text, command = command, view = view })
    end
    rpc.handlers.read_string = function()
      seen = {
        move("2026-11-30", "calendar-forward-day").text,
        move("2026-11-30 10:00", "calendar-forward-week").text,
        move("2027-01-31", "calendar-forward-month").text,
        move("2026-11-30 10:00", "calendar-backward-year").text,
        move("", "calendar-backward-day").text,
        move("2026-11-07", "calendar-scroll-left", { 11, 2026 }),
        move("2026-11-07", "calendar-scroll-left", { 12, 2026 }),
      }
      return "2026-12-01"
    end
    t.keys("C-c C-s")
    t.eq(seen, { "2026-12-01", "2026-12-07 10:00", "2027-02-28", "2025-11-30 10:00",
      date_in(-1):sub(1, 10),
      { text = "2026-11-07", view = { 12, 2026 } }, { text = "2027-01-01", view = { 1, 2027 } } })
  end,

  -- Typed like org's prompt; C-o browses the calendar with keys, Enter
  -- picks there and Esc goes back to typing.
  ["the date prompt takes a typed answer, or C-o and keys to pick one"] = function(t)
    package.loaded["emacs.ui"] = nil
    require("emacs.ui") -- the real prompts, reading the keys fed below
    local function answer(keys)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "t", false)
      t.keys("C-c C-s")
      return t.lines()[2]
    end
    local day = date_in
    t.open("typed.org", "* Task\n")
    t.eq(answer("+3<CR>"), "SCHEDULED: <" .. day(3) .. ">", "typed +3")
    t.open("pick.org", "* Task\n")
    t.eq(answer("<C-o>lj<CR>"), "SCHEDULED: <" .. day(8) .. ">", "C-o l j Enter")
    t.open("pick_back.org", "* Task\n")
    t.eq(answer("<C-o>l<Esc>+1<CR>"), "SCHEDULED: <" .. day(1) .. ">", "Esc goes back to typing")
    t.open("keys.org", "* Task\n")
    t.eq(answer("<S-Right><S-Down><CR>"), "SCHEDULED: <" .. day(8) .. ">", "S-arrows")
    t.open("today.org", "* Task\n")
    t.eq(answer("+3<Home>.<CR>"), "SCHEDULED: <" .. day(0) .. ">", ". at the start is today")
    t.open("month.org", "* Task\n")
    t.eq(answer("2026-11-07<M-S-Right><CR>"), "SCHEDULED: <2026-12-07 Mon>", "M-S-Right is a month")
  end,
}
