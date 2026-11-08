-- Agenda commands that edit or show the entry at point: line dragging,
-- C-k, z notes, effort, tags, properties, archiving, S-left/right, C, T,
-- x/Q/q, o, SPC/DEL and k capture. Expectations come from the same keys
-- in batch Emacs (execute-kbd-macro in the agenda).
local api = vim.api

local dates = require("dates")

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function lines_of(path) return api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false) end

local A_TEXT = { "* TODO Write report :work:", "* TODO Call Bob :home:", "* NEXT Plan trip :work:" }

-- a.org is open in Neovim; b.org is only an agenda file.
local function setup(t)
  local a = t.open("a.org", table.concat(A_TEXT, "\n") .. "\n")
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

-- Week agenda starting today over day.org, whose two entries are
-- scheduled today.
local function week(t)
  local path = t.open("day.org", ("* TODO Write report\nSCHEDULED: <%s>\n* TODO Call Bob\nSCHEDULED: <%s>\n"):format(
    dates.org(0), dates.org(0)))
  t.eval(([[(progn (require 'org-agenda) (setq org-agenda-files (list %q)))]]):format(path))
  t.set("org-agenda-start-on-weekday", "nil")
  t.answer("a")
  t.command("org-agenda")
  return path
end

-- Each entry line's text after its category, tag padding squeezed to a space.
local function items(t)
  local out = {}
  for _, l in ipairs(t.lines()) do
    local item = l:match("^  %a+:%s+(.-)%s*$")
    if item then out[#out + 1] = (item:gsub("%s+:", " :")) end
  end
  return out
end

local function window_of(path)
  local buf = vim.fn.bufnr(path)
  if buf == -1 then return nil end
  return vim.fn.win_findbuf(buf)[1]
end

local function last_message() return vim.trim(vim.fn.execute("1messages")) end

-- "[2026-11-08 Sun 02:52]"
local STAMP = "%[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]"

return {
  ["M-down drags the agenda line down and leaves the file alone"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Write report"))
    t.feed("<M-Down>")
    t.eq(items(t), { "TODO Call Bob :home:", "TODO Write report :work:", "NEXT Plan trip :work:",
      "TODO Pay rent :home:", "TODO Read book" })
    t.eq(api.nvim_win_get_cursor(0)[1], 4, "cursor moves with the line")
    t.eq(lines_of(a), A_TEXT)
  end,

  ["M-up drags the agenda line up"] = function(t)
    setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.feed("<M-Up>")
    t.eq(items(t), { "TODO Call Bob :home:", "TODO Write report :work:", "NEXT Plan trip :work:",
      "TODO Pay rent :home:", "TODO Read book" })
    t.eq(api.nvim_win_get_cursor(0)[1], 3, "cursor moves with the line")
  end,

  -- org-agenda-confirm-kill is 1: a one-line entry goes without asking.
  ["C-k kills a one-line entry from the file and the agenda"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.feed("<C-k>")
    t.eq(#t.asked(), 1, "no confirm")
    t.eq(lines_of(a), { "* TODO Write report :work:", "* NEXT Plan trip :work:" })
    t.eq(items(t), { "TODO Write report :work:", "NEXT Plan trip :work:", "TODO Pay rent :home:", "TODO Read book" })
    t.eq(last_message(), "Agenda item and source killed")
  end,

  ["C-k asks before killing a longer entry, then C-_ brings it back"] = function(t)
    local a = t.open("a.org", "* TODO Write report\n* TODO Call Bob\nnotes\n* TODO Plan\n")
    t.eval(([[(setq org-agenda-files (list %q))]]):format(a))
    todo_list(t)
    local agenda_win = api.nvim_get_current_win()
    t.cursor(t.find_line("Call Bob"))
    t.answer(true)
    t.feed("<C-k>")
    t.eq(t.asked()[2].method, "confirm")
    t.eq(t.asked()[2].params.prompt, 'Delete entry with 2 lines in buffer "a.org"? ')
    t.eq(lines_of(a), { "* TODO Write report", "* TODO Plan" })
    t.eq(items(t), { "TODO Write report", "TODO Plan" })
    t.eq(api.nvim_get_current_win(), agenda_win, "agenda window kept")
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "the indirect buffer's window is gone again")
    t.keys("C-_")
    t.eq(lines_of(a), { "* TODO Write report", "* TODO Call Bob", "notes", "* TODO Plan" })
    t.eq(items(t), { "TODO Write report", "TODO Call Bob", "TODO Plan" })
  end,

  ["z opens a note buffer, and C-c C-c files the note in LOGBOOK"] = function(t)
    local a = setup(t)
    t.set("org-log-into-drawer", "t")
    todo_list(t)
    local agenda = api.nvim_get_current_buf()
    t.cursor(t.find_line("Call Bob"))
    press("z")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Org Note*", "note buffer focused")
    t.eq(t.lines(), { "# Insert note for this entry.", "# Finish with C-c C-c, or cancel with C-c C-k.", "" })
    press("GAcalled him\27")
    t.keys("C-c C-c")
    t.eq(api.nvim_get_current_buf(), agenda, "back in the agenda")
    local lines = lines_of(a)
    -- Emacs leaves a blank line after the drawer.
    t.eq({ lines[1], lines[2], lines[3], lines[5], lines[6], lines[7], lines[8], #lines },
      { "* TODO Write report :work:", "* TODO Call Bob :home:", ":LOGBOOK:", "  called him", ":END:", "",
        "* NEXT Plan trip :work:", 8 })
    assert(lines[4]:find("^%- Note taken on " .. STAMP .. " \\\\$"), lines[4])
    t.eq(t.emacs_lines(a), lines, "Emacs agrees")
  end,

  ["e sets the entry's effort"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer("1:00")
    press("e")
    t.eq(t.asked()[2].params.prompt, "Effort: ")
    t.eq(lines_of(a), { "* TODO Write report :work:", "* TODO Call Bob :home:", ":PROPERTIES:", ":Effort:   1:00",
      ":END:", "* NEXT Plan trip :work:" })
    t.eq(last_message(), "Effort is now 1:00")
  end,

  ["C-c C-x e sets the effort in a file only the agenda opened"] = function(t)
    local _, b = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Pay rent"))
    t.answer("0:30")
    t.keys("C-c C-x e")
    t.eq(lines_of(b), { "* TODO Pay rent :home:", ":PROPERTIES:", ":Effort:   0:30", ":END:", "* TODO Read book" })
    t.eq(t.emacs_lines(b), lines_of(b), "Emacs agrees")
  end,

  -- : is Neovim's command line in the agenda (config.passthrough), so
  -- send it as Emacs keys.
  [": sets the entry's tags and realigns them"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer("home:urgent")
    t.keys(":")
    -- completing-read-multiple: one string, starting from the current tags.
    t.eq({ t.asked()[2].params.prompt, t.asked()[2].params.initial }, { "Tags: ", ":home:" })
    t.eq(lines_of(a), { "* TODO Write report :work:", t.aligned("* TODO Call Bob", ":home:urgent:"),
      "* NEXT Plan trip :work:" })
    t.eq(items(t)[2], "TODO Call Bob :home:urgent:")
  end,

  ["C-c C-x p sets a property of the entry"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer("Phone", "555")
    t.keys("C-c C-x p")
    -- The default in brackets is the last property set, by any test.
    assert(t.asked()[2].params.prompt:find("^Property"), t.asked()[2].params.prompt)
    t.eq(lines_of(a), { "* TODO Write report :work:", "* TODO Call Bob :home:", ":PROPERTIES:", ":Phone:    555",
      ":END:", "* NEXT Plan trip :work:" })
  end,

  -- org-archive-subtree-save-file-p is from-org: from the agenda, Emacs
  -- leaves the archive unsaved.
  ["$ archives the entry without asking"] = function(t)
    local a = setup(t)
    local archive = a .. "_archive"
    os.remove(archive)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    press("$")
    t.eq(#t.asked(), 1, "no confirm")
    t.eq(lines_of(a), { "* TODO Write report :work:", "* NEXT Plan trip :work:" })
    t.eq(items(t), { "TODO Write report :work:", "NEXT Plan trip :work:", "TODO Pay rent :home:", "TODO Read book" })
    local emacs_lines = t.emacs_lines(archive)
    assert(emacs_lines[9]:find("^:ARCHIVE_TIME: %d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d$"), emacs_lines[9])
    t.eq(emacs_lines, { "#    -*- mode: org -*-", "", "", "Archived entries from file " .. a, "", "",
      "* TODO Call Bob :home:", ":PROPERTIES:", emacs_lines[9], ":ARCHIVE_FILE: " .. a, ":ARCHIVE_CATEGORY: a",
      ":ARCHIVE_TODO: TODO", ":END:" }, "Emacs's archive")
    t.eq(lines_of(archive), emacs_lines, "archive mirror")
    t.eq(vim.bo[vim.fn.bufnr(archive)].modified, true, "archive left unsaved, as in Emacs")
  end,

  ["a asks before archiving; n leaves the entry"] = function(t)
    local a = setup(t)
    os.remove(a .. "_archive")
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    t.answer(false)
    press("a")
    t.eq(t.asked()[2].params.prompt, "Archive this subtree or entry? ")
    t.eq(lines_of(a), A_TEXT)
    t.eq(#items(t), 5)
    t.answer(true)
    press("a")
    t.eq(lines_of(a), { "* TODO Write report :work:", "* NEXT Plan trip :work:" })
    t.eq(lines_of(a .. "_archive")[7], "* TODO Call Bob :home:")
  end,

  ["S-right moves the entry's date a day later"] = function(t)
    local path = week(t)
    t.cursor(t.find_line("Call Bob"))
    t.feed("<S-Right>")
    t.eq(lines_of(path), { "* TODO Write report", "SCHEDULED: <" .. dates.org(0) .. ">", "* TODO Call Bob",
      "SCHEDULED: <" .. dates.org(1) .. ">" })
    t.eq(last_message(), "Time stamp changed to <" .. dates.org(1) .. ">")
  end,

  ["S-left twice moves the entry's date two days earlier"] = function(t)
    local path = week(t)
    t.cursor(t.find_line("Call Bob"))
    t.feed("<S-Left><S-Left>")
    t.eq(lines_of(path)[4], "SCHEDULED: <" .. dates.org(-2) .. ">")
    t.eq(last_message(), "Time stamp changed to <" .. dates.org(-2) .. ">")
  end,

  ["C shows the date in other calendars in *Dates*"] = function(t)
    week(t)
    local agenda_win = api.nvim_get_current_win()
    t.cursor(t.find_line("Write report"))
    press("C")
    t.eq(api.nvim_get_current_win(), agenda_win, "agenda keeps focus")
    local win = assert(window_of("emacs://*Dates*"), "*Dates* shown")
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
    t.eq(lines[1], "Gregorian:  " .. os.date("%A, %B ", dates.time(0)) .. tonumber(os.date("%d", dates.time(0)))
      .. os.date(", %Y", dates.time(0)))
    t.eq(#lines, 14)
    assert(lines[2]:find("^ISO:        Day %d of week %d+ of %d+$"), lines[2])
  end,

  ["T shows the entry's tags"] = function(t)
    setup(t)
    todo_list(t)
    t.cursor(t.find_line("Call Bob"))
    press("T")
    t.eq(last_message(), "Tags are :home:")
    t.cursor(t.find_line("Read book"))
    press("T")
    t.eq(last_message(), "No tags associated with this line")
  end,

  ["x closes the agenda and kills the buffers it opened"] = function(t)
    local a, b = setup(t)
    todo_list(t)
    local agenda = api.nvim_get_current_buf()
    press("x")
    t.eq(#vim.fn.win_findbuf(agenda), 0, "agenda window closed")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "a.org")
    t.eq(t.eval([[(and (get-buffer "*Org Agenda*") t)]]), "nil", "agenda killed")
    t.eq(t.eval(([[(and (get-file-buffer %q) t)]]):format(b)), "nil", "b.org killed")
    t.eq(t.eval(([[(and (get-file-buffer %q) t)]]):format(a)), "t", "a.org kept")
  end,

  ["Q closes and kills the agenda but keeps the files"] = function(t)
    local _, b = setup(t)
    todo_list(t)
    local agenda = api.nvim_get_current_buf()
    press("Q")
    t.eq(#vim.fn.win_findbuf(agenda), 0, "agenda window closed")
    t.eq(t.eval([[(and (get-buffer "*Org Agenda*") t)]]), "nil", "agenda killed")
    t.eq(t.eval(([[(and (get-file-buffer %q) t)]]):format(b)), "t", "b.org kept")
  end,

  ["q with org-agenda-sticky buries the agenda instead of killing it"] = function(t)
    setup(t)
    t.set("org-agenda-sticky", "t")
    t.after(function() t.eval("(org-agenda-kill-all-agenda-buffers)") end)
    todo_list(t)
    local agenda = api.nvim_get_current_buf()
    press("q")
    t.eq(#vim.fn.win_findbuf(agenda), 0, "agenda window closed")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "a.org")
    t.eq(t.eval([[(and (get-buffer "*Org Agenda(t)*") t)]]), "t", "agenda buried, not killed")
  end,

  ["o deletes the other windows"] = function(t)
    setup(t)
    todo_list(t)
    local agenda_win = api.nvim_get_current_win()
    t.eq(#api.nvim_tabpage_list_wins(0), 2)
    press("o")
    t.eq(api.nvim_tabpage_list_wins(0), { agenda_win })
  end,

  ["SPC shows the entry in the other window and keeps the agenda focused"] = function(t)
    local _, b = setup(t)
    todo_list(t)
    local agenda_win = api.nvim_get_current_win()
    t.cursor(t.find_line("Pay rent"))
    t.feed("<Space>")
    t.eq(api.nvim_get_current_win(), agenda_win, "agenda keeps focus")
    local bw = assert(window_of(b), "b.org shown")
    t.eq(api.nvim_win_get_cursor(bw)[1], 1)
    t.eq(#api.nvim_tabpage_list_wins(0), 2)
  end,

  -- Emacs scrolls by the window's height less next-screen-context-lines
  -- (2), and point follows the window start; DEL scrolls back and leaves
  -- point where it is, still in view.
  ["SPC again scrolls the entry's window up, and DEL scrolls it back"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then
      t.skip("0.9's nvim_win_call restores another window's view, so Emacs's scrolling can't show")
    end
    local body = {}
    for i = 1, 100 do body[i] = "line " .. i end
    local path = t.file("long.org", "* TODO Long\n" .. table.concat(body, "\n") .. "\n* TODO Next\n")
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    todo_list(t)
    t.cursor(t.find_line("Long"))
    local function view()
      local w = assert(window_of(path), "long.org shown")
      local v = api.nvim_win_call(w, vim.fn.winsaveview)
      return { top = v.topline, line = v.lnum }, api.nvim_win_get_height(w)
    end
    t.feed("<Space>")
    local shown, height = view()
    t.eq(shown, { top = 1, line = 1 }, "entry shown from its heading")
    t.feed("<Space>")
    t.eq(view(), { top = height - 1, line = height - 1 }, "scrolled up")
    t.feed("<BS>")
    t.eq(view(), { top = 1, line = height - 1 }, "scrolled back")
  end,

  -- k is Neovim's motion in the agenda, so send it as Emacs keys.
  ["k captures with the date of the agenda line"] = function(t)
    week(t)
    local inbox = t.file("inbox.org", "")
    t.set("bookmark-default-file", ("%q"):format(t.WORK .. "/no-bookmarks"))
    t.set("org-capture-templates", ([['(("d" "Dated" entry (file %q) "* TODO %%?\n%%t"))]]):format(inbox))
    local day = dates.time(2)
    t.cursor(t.find_line("^" .. os.date("%A", day) .. "%s+" .. tonumber(os.date("%d", day))))
    t.answer("d")
    t.keys("k")
    assert(api.nvim_buf_get_name(0):find("CAPTURE"), "capture buffer: " .. api.nvim_buf_get_name(0))
    t.eq(t.lines(), { "* TODO ", "<" .. dates.org(2) .. ">" })
    -- Capture starts Insert mode at %?; a, as agenda.lua's capture test does.
    press("aCall Bob\27")
    t.keys("C-c C-c")
    t.eq(vim.fn.readfile(inbox), { "* TODO Call Bob", "<" .. dates.org(2) .. ">" })
    assert(api.nvim_buf_get_name(0):find("Org Agenda"), "back in the agenda")
  end,
}
