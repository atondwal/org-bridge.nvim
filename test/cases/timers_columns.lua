-- Relative timer, effort, column view and C-c C-x p. Timer values are read
-- right after starting (0:00:00) or after shifting the start time back.
local api = vim.api

local NS = api.nvim_create_namespace("emacs")

local COLUMNS_DOC = table.concat({
  "#+COLUMNS: %20ITEM %Effort{:}",
  "* Parent",
  "** A", ":PROPERTIES:", ":Effort:   0:20", ":END:",
  "** B", ":PROPERTIES:", ":Effort:   0:30", ":END:", "",
}, "\n")

local ALLOWED = "#+PROPERTY: Effort_ALL 0 0:10 0:30 1:00\n"

-- Each test starts with no timer; forget the one it started.
local function no_timer(t)
  t.eval("(progn (require 'org-timer) (setq org-timer-start-time nil org-timer-pause-time nil))")
  t.after(function() t.eval("(setq org-timer-start-time nil org-timer-pause-time nil)") end)
end

-- Move the running timer's start back by `secs` seconds.
local function age_timer(t, secs)
  t.eval(("(setq org-timer-start-time (time-subtract org-timer-start-time %d))"):format(secs))
end

local function prompts(t)
  local out = {}
  for _, q in ipairs(t.asked()) do out[#out + 1] = q.method .. " " .. q.params.prompt end
  return out
end

-- All virtual text drawn on 1-based line `lnum`, concatenated.
local function virt_text(lnum)
  local s = ""
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, NS, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do s = s .. chunk[1] end
  end
  return s
end

return {
  ["C-c C-x 0 then C-c C-x . inserts 0:00:00 at point"] = function(t)
    no_timer(t)
    t.open("timer.org", "* H\nline\n")
    t.cursor(2, 0)
    t.keys("C-c C-x 0")
    t.keys("C-c C-x .")
    t.eq(t.lines(), { "* H", "0:00:00 line" })
    t.eq(api.nvim_win_get_cursor(0), { 2, 8 }, "cursor after the timer")
  end,

  ["C-u C-c C-x 0 asks for an offset"] = function(t)
    no_timer(t)
    t.open("offset.org", "* H\nline\n")
    t.cursor(2, 0)
    t.answer("1:00:00")
    t.keys("C-c C-x 0", 4)
    t.keys("C-c C-x .")
    t.eq(t.lines()[2], "1:00:00 line")
    t.eq(#t.asked(), 1, vim.inspect(prompts(t)))
    t.eq(t.asked()[1].params.prompt, "Restart timer with offset [0:00:00]: ")
  end,

  ["C-c C-x . with no timer running starts one"] = function(t)
    no_timer(t)
    t.open("notimer.org", "* H\nline\n")
    t.cursor(2, 0)
    t.keys("C-c C-x .")
    t.eq(t.lines()[2], "0:00:00 line")
    t.eq(t.eval("(not (null org-timer-start-time))"), "t", "timer running")
  end,

  ["C-c C-x , pauses: C-c C-x . inserts the paused value"] = function(t)
    no_timer(t)
    t.open("pause.org", "* H\nline\n")
    t.cursor(2, 0)
    t.keys("C-c C-x 0")
    age_timer(t, 125)
    t.keys("C-c C-x ,")
    t.keys("C-c C-x .")
    t.eq(t.lines()[2], "0:02:05 line")
  end,

  ["C-c C-x - turns a plain line into a timer item"] = function(t)
    no_timer(t)
    t.open("item.org", "* H\nline\n")
    t.cursor(2, 0)
    t.keys("C-c C-x 0")
    t.keys("C-c C-x -")
    t.eq(t.lines(), { "* H", "- 0:00:00 :: line" })
    t.eq(api.nvim_win_get_cursor(0), { 2, 13 })
  end,

  -- Point at the item's body start: org-insert-item makes the new item
  -- before the current one.
  ["C-c C-x - at an item's body start adds a timer item before it"] = function(t)
    no_timer(t)
    t.open("item2.org", "* H\n- 0:00:00 :: a\n")
    t.cursor(2, 13)
    t.keys("C-c C-x 0")
    t.keys("C-c C-x -")
    t.eq(t.lines(), { "* H", "- 0:00:00 ::", "- 0:00:00 :: a" })
    t.eq(api.nvim_win_get_cursor(0), { 3, 13 })
  end,

  ["C-c C-x e prompts for the effort and sets it"] = function(t)
    t.open("effort.org", "* H\nbody\n")
    t.answer("1:30")
    t.keys("C-c C-x e")
    t.eq(t.lines(), { "* H", ":PROPERTIES:", ":Effort:   1:30", ":END:", "body" })
    t.eq(prompts(t), { "completing_read Effort: " })
  end,

  ["C-u C-c C-x e steps to the next allowed effort without asking"] = function(t)
    t.open("effort2.org", ALLOWED .. "* H\n:PROPERTIES:\n:Effort:   0:10\n:END:\n")
    t.cursor(2)
    t.keys("C-c C-x e", 4)
    t.eq(t.lines()[4], ":Effort:   0:30")
    t.eq(#t.asked(), 0, vim.inspect(prompts(t)))
  end,

  -- org-columns-edit-value writes the column's upcased key back.
  ["column view: e edits the effort, q quits"] = function(t)
    local path = t.open("cvedit.org", COLUMNS_DOC)
    t.cursor(3, 1)
    t.keys("C-c C-x C-c")
    t.answer("1:00")
    t.keys("e")
    t.eq(prompts(t), { "read_string Edit: " })
    t.eq(api.nvim_win_get_cursor(0), { 3, 1 }, "cursor stays on the Effort cell")
    t.keys("q")
    t.eq(t.lines()[5], ":EFFORT:   1:00")
    t.eq(t.lines(), t.emacs_lines(path), "Neovim and Emacs agree")
    t.eq(t.eval([[(with-current-buffer "cvedit.org" (length org-columns-overlays))]]), "0", "overlays left")
  end,

  ["column view: the parent's summary follows an edited child"] = function(t)
    t.open("cvsum.org", COLUMNS_DOC)
    t.cursor(2, 0)
    t.keys("C-c C-x C-c")
    assert(virt_text(2):find("0:50", 1, true), "parent sum before: " .. virt_text(2))
    t.cursor(7, 1)
    t.answer("1:00")
    t.keys("e")
    assert(virt_text(2):find("1:20", 1, true), "parent sum after: " .. virt_text(2))
    assert(virt_text(7):find("1:00", 1, true), "child cell after: " .. virt_text(7))
    t.keys("q")
    t.eq(t.lines()[9], ":EFFORT:   1:00")
  end,

  -- 0:20 is not allowed, so the first S-right picks the first value, 0.
  ["column view: S-right steps through Effort_ALL"] = function(t)
    t.open("cvnext.org", ALLOWED .. COLUMNS_DOC)
    t.cursor(4, 1)
    t.keys("C-c C-x C-c")
    t.keys("<S-right>")
    t.keys("<S-right>")
    t.keys("q")
    t.eq(t.lines()[6], ":EFFORT:   0:10")
  end,

  ["M-RET at the end of a timer item adds a timer item"] = function(t)
    no_timer(t)
    t.open("mret.org", "* H\n- 0:00:05 :: a\n")
    t.keys("C-c C-x 0")
    t.cursor(2, 13)
    t.feed("<M-CR>") -- cursor on the last character: acts at end of line
    t.eq(t.lines(), { "* H", "- 0:00:05 :: a", "- 0:00:00 :: " })
    t.eq(api.nvim_win_get_cursor(0)[1], 3)
  end,

  -- The countdown has run a moment by the time C-c C-x . reads it.
  ["C-c C-x ; starts a countdown that C-c C-x . inserts"] = function(t)
    no_timer(t)
    t.after(function() t.eval("(org-timer-stop)") end)
    t.open("countdown.org", "* H\nline\n")
    t.cursor(2, 0)
    t.answer("5")
    t.keys("C-c C-x ;")
    t.eq(prompts(t), { "read_string How much time left? (minutes or h:mm:ss) " })
    t.keys("C-c C-x .")
    local line = t.lines()[2]
    assert(line == "0:04:59 line" or line == "0:05:00 line", line)
  end,

  ["column view: typed e, n, n, p step the effort"] = function(t)
    t.open("cvfeed.org", ALLOWED .. COLUMNS_DOC)
    t.cursor(4, 1)
    t.keys("C-c C-x C-c")
    t.answer("0:10")
    t.feed("e")
    t.feed("n")
    t.feed("n")
    t.feed("p")
    t.feed("q")
    t.eq(t.asked()[1].params.prompt, "Value: ")
    t.eq(t.lines()[6], ":EFFORT:   0:30")
    t.eq(t.eval([[(with-current-buffer "cvfeed.org" (length org-columns-overlays))]]), "0", "overlays left")
  end,

  -- The README keeps digits as Neovim counts in column view.
  ["column view: a typed digit picks that allowed value"] = function(t)
    t.open("cvdigit.org", ALLOWED .. COLUMNS_DOC)
    t.cursor(4, 1)
    t.keys("C-c C-x C-c")
    t.feed("3")
    t.feed("q")
    t.eq(t.lines()[6], ":EFFORT:   0:30")
  end,

  ["column view: e on TODO opens fast selection, e on ITEM renames"] = function(t)
    local doc = COLUMNS_DOC:gsub("%%20ITEM", "%%20ITEM %%TODO"):gsub("%*%* A", "** TODO A")
    t.open("cvtodo.org", doc)
    t.cursor(3, 1)
    t.keys("C-c C-x C-c")
    t.answer("d")
    t.feed("e")
    t.eq(t.lines()[3], "** DONE A")
    t.cursor(3, 0)
    t.answer("Renamed")
    t.feed("e")
    t.eq(t.asked()[2].params.prompt, "Edit: ")
    t.feed("q")
    t.eq(t.lines()[3], "** DONE Renamed")
  end,

  ["column view: a edits the allowed values"] = function(t)
    t.open("cvallowed.org", COLUMNS_DOC)
    t.cursor(3, 1)
    t.keys("C-c C-x C-c")
    t.answer("0:15 0:45")
    t.feed("a")
    t.eq(prompts(t), { "read_string Allowed: " })
    t.feed("q")
    t.eq(t.lines(), { "#+COLUMNS: %20ITEM %Effort{:}", "* Parent", "** A", ":PROPERTIES:",
      ":Effort:   0:20", ":EFFORT_ALL: 0:15 0:45", ":END:", "** B", ":PROPERTIES:", ":Effort:   0:30", ":END:" })
  end,

  -- Changing a column's width rewrites the #+COLUMNS line.
  ["column view: > and < rewrite the #+COLUMNS width"] = function(t)
    t.open("cvwidth.org", COLUMNS_DOC)
    t.cursor(3, 1)
    t.keys("C-c C-x C-c")
    t.feed(">")
    t.eq(t.lines()[1], "#+COLUMNS: %20ITEM %7EFFORT(Effort){:}", "widened")
    t.feed("<")
    t.feed("<")
    t.eq(t.lines()[1], "#+COLUMNS: %20ITEM %5EFFORT(Effort){:}", "narrowed twice")
    t.feed("q")
  end,

  -- Column view binds M-left/M-right (move column); typed, not via t.keys.
  ["column view: M-left moves a column and rewrites #+COLUMNS"] = function(t)
    t.open("cvmove.org", COLUMNS_DOC)
    t.cursor(3, 1)
    t.keys("C-c C-x C-c")
    t.feed("<M-Left>")
    t.eq(t.lines()[1], "#+COLUMNS: %EFFORT(Effort){:} %20ITEM", "moved left")
    t.feed("q")
  end,

  ["C-c C-x p after column view offers the current effort"] = function(t)
    t.open("cvprop.org", COLUMNS_DOC)
    t.cursor(3, 1)
    t.keys("C-c C-x C-c")
    t.keys("q")
    t.answer("Effort", "0:25")
    t.keys("C-c C-x p")
    t.eq(t.lines()[5], ":Effort:   0:25")
    t.eq(t.asked()[2].params.prompt, "Effort value [0:20]: ")
  end,
}
