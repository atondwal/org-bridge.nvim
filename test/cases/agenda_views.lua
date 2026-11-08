-- Agenda beyond the basics.
local api = vim.api

local dates = require("dates")

-- Org's spelling of a date some days from now: "2026-11-07 Sat".
local org_date = dates.org

-- Pattern for the agenda's date header of a day: "Saturday    7 November 2026".
local function day_header(days)
  local t = dates.time(days)
  return "^" .. os.date("%A", t) .. "%s+" .. tonumber(os.date("%d", t)) .. os.date(" %B %Y", t)
end

-- a.org is open in Neovim; b.org is only an agenda file.
local function setup(t)
  local a = t.open("a.org", table.concat({
    "* TODO Write report :work:",
    "SCHEDULED: <" .. org_date(0) .. ">",
    "* TODO Call Bob :home:",
    "* NEXT Plan trip :work:",
    "DEADLINE: <" .. org_date(5) .. ">",
    "",
  }, "\n"))
  local b = t.file("b.org", table.concat({
    "* TODO Pay rent :home:",
    "SCHEDULED: <" .. org_date(7) .. ">",
    "* TODO Read book",
    "",
  }, "\n"))
  t.eval(([[(setq org-agenda-files (list %q %q) org-directory %q)]]):format(a, b, t.WORK))
  return a, b, api.nvim_get_current_buf()
end

local function cursor_text() return api.nvim_get_current_line() end

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

-- Open the global TODO list ("t" in the dispatcher).
local function todo_list(t)
  t.answer("t")
  t.command("org-agenda")
  assert(api.nvim_buf_get_name(0):find("Org Agenda"), "agenda focused")
end

local function window_of(path)
  local buf = vim.fn.bufnr(path)
  if buf == -1 then return nil end
  return vim.fn.win_findbuf(buf)[1]
end

return {
  ["f, b and . move the week view and keep the weekday line"] = function(t)
    setup(t)
    t.answer("a")
    t.command("org-agenda")
    t.eq(t.lines()[1], "Week-agenda (W" .. os.date("%V") .. "):")
    assert(cursor_text():find(day_header(0)), "cursor on today: " .. cursor_text())
    press("f")
    t.eq(t.lines()[1], "Week-agenda (W" .. os.date("%V", dates.time(7)) .. "):")
    assert(cursor_text():find(day_header(7)), "cursor on the same weekday: " .. cursor_text())
    assert(t.find_line("Scheduled:  TODO Pay rent"), "next week shows b.org's item")
    -- b is Neovim's word motion in the agenda, so send it as Emacs keys.
    t.keys("b")
    t.eq(t.lines()[1], "Week-agenda (W" .. os.date("%V") .. "):")
    press("ff.")
    t.eq(t.lines()[1], "Week-agenda (W" .. os.date("%V") .. "):")
    assert(cursor_text():find(day_header(0)), "back on today: " .. cursor_text())
  end,

  ["m in the dispatcher asks for a tags match"] = function(t)
    setup(t)
    t.answer("m", "work")
    t.command("org-agenda")
    t.eq(t.asked()[2].method, "completing_read")
    t.eq(t.asked()[2].params.prompt, "Match: ")
    t.eq(t.lines()[1], "Headlines with TAGS match: work")
    assert(t.find_line("TODO Write report") and t.find_line("NEXT Plan trip"), "work items")
    assert(not t.find_line("Call Bob") and not t.find_line("Pay rent"), "no home items")
  end,

  ["/ filters by tag by hiding lines, and | clears it"] = function(t)
    setup(t)
    todo_list(t)
    t.answer("+home")
    -- / is Neovim's search in the agenda, so send it as Emacs keys.
    t.keys("/")
    t.eq(t.asked()[2].method, "completing_read")
    -- Emacs makes lines 3, 5 and 7 (Write report, Plan trip, Read book) invisible.
    t.eq(t.folds(), { "2-3", "4-5", "6-7" })
    press("|")
    t.eq(t.folds(), {})
  end,

  ["F follows the item at point in the file window"] = function(t)
    local a, b = setup(t)
    todo_list(t)
    local agenda_win = api.nvim_get_current_win()
    t.cursor(t.find_line("Call Bob"))
    press("F")
    t.eq(api.nvim_get_current_win(), agenda_win, "agenda keeps focus")
    local aw = assert(window_of(a), "a.org shown")
    t.eq(api.nvim_win_get_cursor(aw)[1], 3, "a.org window on Call Bob")
    press("n")
    t.eq(api.nvim_win_get_cursor(aw)[1], 4, "a.org window follows to Plan trip")
    press("n")
    -- Emacs shows b.org (never opened in Neovim) in the other window.
    local bw = assert(window_of(b), "b.org shown")
    t.eq(api.nvim_win_get_cursor(bw)[1], 1, "b.org window on Pay rent")
    t.eq(api.nvim_get_current_win(), agenda_win, "agenda still focused")
  end,

  ["m marks entries and B t sets their TODO state"] = function(t)
    local _, _, abuf = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Write report"))
    -- m is Neovim's mark command in the agenda, so send it as Emacs keys.
    t.keys("m")
    t.eq(api.nvim_win_get_cursor(0)[1], t.find_line("Call Bob"), "mark moves to the next line")
    t.keys("m")
    t.answer("t", "DONE")
    press("B")
    assert(t.asked()[2].params.prompt:find("^Bulk"), "bulk prompt: " .. t.asked()[2].params.prompt)
    t.eq(t.asked()[3].params.prompt, "Todo state: ")
    local lines = api.nvim_buf_get_lines(abuf, 0, -1, false)
    assert(lines[1]:find("^%* DONE Write report%s+:work:$"), lines[1])
    assert(lines[3]:find("^%* DONE Call Bob%s+:home:$"), lines[3])
    t.eq(lines[4], "* NEXT Plan trip :work:")
    assert(t.find_line("DONE Write report") and t.find_line("DONE Call Bob"), "agenda redrawn")
  end,

  ["a marked entry shows Emacs's > marker"] = function(t)
    setup(t)
    todo_list(t)
    local line = t.find_line("Write report")
    t.cursor(line)
    t.keys("m")
    -- Emacs draws the mark as an overlay whose display string "> " replaces
    -- the line's first two characters. (Headless 0.9 has no screen to read,
    -- so look for the marker in the text or in virtual text.)
    local shown = api.nvim_buf_get_lines(0, line - 1, line, false)[1]:sub(1, 2)
    for _, m in ipairs(api.nvim_buf_get_extmarks(0, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        if chunk[1]:find(">") then shown = chunk[1] end
      end
    end
    t.eq(shown, "> ")
  end,

  ["C-c C-s in the agenda schedules the item in the file mirror"] = function(t)
    local _, _, abuf = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer("2026-11-10")
    t.keys("C-c C-s")
    t.eq(t.asked()[2].method, "read_string")
    t.eq(api.nvim_buf_get_lines(abuf, 2, 4, false), { "* TODO Call Bob :home:", "SCHEDULED: <2026-11-10 Tue>" })
    t.eq(vim.bo[abuf].modified, true)
  end,

  ["r redraws with Neovim's edits and keeps the cursor line; 2r narrows to NEXT"] = function(t)
    local _, _, abuf = setup(t)
    todo_list(t)
    api.nvim_buf_set_lines(abuf, 2, 3, false, { "* TODO Call Alice :home:" })
    local line = t.find_line("Plan trip")
    t.cursor(line)
    press("r")
    assert(t.find_line("TODO Call Alice"), "agenda sees the edit:\n" .. table.concat(t.lines(), "\n"))
    t.eq(api.nvim_win_get_cursor(0)[1], line)
    press("2r")
    t.eq(t.lines()[1], "Global list of TODO items of type: NEXT")
    t.eq(#t.lines(), 3, "only the NEXT item:\n" .. table.concat(t.lines(), "\n"))
    assert(t.find_line("NEXT Plan trip"))
  end,

  ["the TODO list spans unopened files, and t there gives Neovim a buffer to save"] = function(t)
    local _, b = setup(t)
    todo_list(t)
    t.eq(t.lines()[1], "Global list of TODO items of type: ALL")
    for _, item in ipairs({ "TODO Write report", "TODO Call Bob", "NEXT Plan trip", "TODO Pay rent", "TODO Read book" }) do
      assert(t.find_line(item), item .. " listed:\n" .. table.concat(t.lines(), "\n"))
    end
    t.cursor(t.find_line("Pay rent"))
    t.answer("d")
    press("t")
    local bbuf = vim.fn.bufnr(b)
    assert(bbuf ~= -1, "b.org has a Neovim buffer")
    local first = api.nvim_buf_get_lines(bbuf, 0, 1, false)[1]
    assert(first:find("^%* DONE Pay rent%s+:home:$"), first)
    t.eq(vim.bo[bbuf].modified, true)
    t.command("org-save-all-org-buffers")
    t.eq(vim.bo[bbuf].modified, false)
    assert(vim.fn.readfile(b)[1]:find("^%* DONE Pay rent"), "written to disk")
  end,

  ["the week agenda lists scheduled and deadline items on their days"] = function(t)
    local path = t.open("week.org", table.concat({
      "* TODO Write report",
      "SCHEDULED: <" .. org_date(0) .. ">",
      "* TODO Pay rent",
      "DEADLINE: <" .. org_date(3) .. ">",
      "",
    }, "\n"))
    -- A week starting today, so the deadline's own day is always shown.
    t.eval(([[(progn (require 'org-agenda) (setq org-agenda-files (list %q)))]]):format(path))
    t.set("org-agenda-start-on-weekday", "nil")
    t.answer("a")
    t.command("org-agenda")
    local lines = t.lines()
    local text = table.concat(lines, "\n")
    assert(lines[1]:find("^Week%-agenda"), text)
    local function day_block(days)
      local header = day_header(days)
      for i, l in ipairs(lines) do
        if l:find(header) then
          local items = {}
          for j = i + 1, #lines do
            if not lines[j]:find("^ ") then break end
            items[#items + 1] = vim.trim(lines[j])
          end
          return items
        end
      end
      error("no header " .. header .. " in:\n" .. text)
    end
    t.eq(day_block(0), { "week:       Scheduled:  TODO Write report", "week:       In   3 d.:  TODO Pay rent" })
    t.eq(day_block(3), { "week:       Deadline:   TODO Pay rent" })
    t.eq(api.nvim_buf_get_name(0):find("Org Agenda") ~= nil, true)
  end,

  ["keys after a command answer its menu (:Emacs C-c a t style)"] = function(t)
    local path = t.open("pending.org", "* TODO Pending task\n")
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    require("emacs").exec({ command = "org-agenda", pending = { "t" } })
    assert(t.find_line("Pending task"), "TODO list built without asking")
  end,
}
