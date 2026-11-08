-- Agenda filters (\ _ ^ / < = |) and limits (~): Neovim hides the lines
-- Emacs makes invisible, and t on a line still left acts on its heading.
local api = vim.api

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function lines_of(path) return api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false) end

-- The global TODO list over a.org (open in Neovim) and b.org: line 3 Write
-- report :work:, 4 Call Bob :home:, 5 Plan trip :work:, 6 Book hotel
-- :home: (5 and 6 under the top headline Trip), 7 Pay rent :home:, 8 Read
-- book. Write report's effort is 0:30, Call Bob's 2:00.
local function todo_list(t)
  local a = t.open("a.org", table.concat({
    "* TODO Write report :work:", ":PROPERTIES:", ":Effort: 0:30", ":END:",
    "* TODO Call Bob :home:", ":PROPERTIES:", ":Effort: 2:00", ":END:",
    "* Trip", "** TODO Plan trip :work:", "** NEXT Book hotel :home:", "",
  }, "\n"))
  local b = t.file("b.org", "* TODO Pay rent :home:\n* TODO Read book\n")
  t.eval(([[(setq org-agenda-files (list %q %q))]]):format(a, b))
  t.answer("t")
  t.command("org-agenda")
  assert(api.nvim_buf_get_name(0):find("Org Agenda"), "agenda focused")
  return a, b
end

return {
  -- Emacs hides lines 3, 5 and 8.
  ["\\ TAB asks for a tag, and t on a shown line marks its heading DONE"] = function(t)
    local a = todo_list(t)
    t.answer("TAB", "home")
    press("\\")
    t.eq(t.asked()[3].params.prompt, "Tag: ")
    t.eq(t.eval("org-agenda-tag-filter"), '("+home")')
    t.eq(t.folds(), { "2-3", "4-5", "7-8" })
    t.cursor(t.find_line("Book hotel"))
    t.answer("d")
    press("t")
    t.eq(lines_of(a)[11], t.aligned("** DONE Book hotel", ":home:"))
    t.eq(lines_of(a)[10], "** TODO Plan trip :work:")
    t.eq(t.folds(), { "2-3", "4-5", "7-8" }, "filter kept after t")
  end,

  -- Emacs hides lines 4, 6, 7 and 8.
  ["\\ . filters by the tags of the line at point"] = function(t)
    todo_list(t)
    t.cursor(t.find_line("Write report"))
    t.answer(".")
    press("\\")
    t.eq(t.eval("org-agenda-tag-filter"), '("+work")')
    t.eq(t.folds(), { "3-4", "5-8" })
  end,

  -- Emacs hides lines 4, 6 and 7, then shows them all again.
  ["\\ - excludes a tag, and \\ \\ turns the tag filter off"] = function(t)
    todo_list(t)
    t.answer("-", "TAB", "home")
    press("\\")
    t.eq(t.eval("org-agenda-tag-filter"), '("-home")')
    t.eq(t.folds(), { "3-4", "5-7" })
    t.answer("\\")
    press("\\")
    t.eq(t.folds(), {})
  end,

  -- Effort < 1:00 keeps only Write report (0:30): Emacs hides lines 4-8.
  ["_ < 4 keeps entries under 1:00, and _ _ removes the effort filter"] = function(t)
    todo_list(t)
    t.answer("<", "4")
    press("_")
    t.eq(t.eval("org-agenda-effort-filter"), '("+<1:00")')
    t.eq(t.folds(), { "3-8" })
    t.answer("_")
    press("_")
    t.eq(t.folds(), {})
  end,

  -- Emacs hides lines 3, 4, 7 and 8, then shows them again.
  ["^ keeps the top headline's entries, t acts there, and ^ again clears it"] = function(t)
    local a = todo_list(t)
    t.cursor(t.find_line("Plan trip"))
    press("^")
    t.eq(t.eval("org-agenda-top-headline-filter"), '"Trip"')
    t.eq(t.folds(), { "2-4", "6-8" })
    t.cursor(t.find_line("Book hotel"))
    t.answer("d")
    press("t")
    t.eq(lines_of(a)[11], t.aligned("** DONE Book hotel", ":home:"))
    t.eq(lines_of(a)[1], "* TODO Write report :work:")
    press("^")
    t.eq(t.folds(), {})
  end,

  -- A prefix argument hides the top headline's entries: lines 5 and 6.
  ["4^ hides the top headline's entries instead"] = function(t)
    todo_list(t)
    t.cursor(t.find_line("Plan trip"))
    press("4^")
    t.eq(t.folds(), { "4-6" })
  end,

  -- Emacs hides lines 4, 6, 7 and 8.
  ["/ +work then t on Plan trip changes Plan trip"] = function(t)
    local a = todo_list(t)
    t.answer("+work")
    press("/")
    t.eq(t.folds(), { "3-4", "5-8" })
    t.cursor(t.find_line("Plan trip"))
    t.answer("d")
    press("t")
    t.eq(lines_of(a)[10], t.aligned("** DONE Plan trip", ":work:"))
    t.eq(lines_of(a)[11], "** NEXT Book hotel :home:")
  end,

  -- Tag and category filters stack (Emacs hides 3-6 and 8); | drops both.
  ["/ then < stack, and | removes every filter"] = function(t)
    todo_list(t)
    t.answer("+home")
    press("/")
    t.cursor(t.find_line("Pay rent"))
    press("<")
    t.eq(t.folds(), { "2-6", "7-8" })
    press("|")
    t.eq(t.folds(), {})
    t.eq(t.eval("(list org-agenda-tag-filter org-agenda-category-filter)"), "(nil nil)")
  end,

  -- b.org is only an agenda file; t gives Neovim its buffer.
  ["= then t on Pay rent changes b.org"] = function(t)
    local _, b = todo_list(t)
    t.answer([[Bob\|rent]])
    press("=")
    t.eq(t.folds(), { "2-3", "4-6", "7-8" })
    t.cursor(t.find_line("Pay rent"))
    t.answer("d")
    press("t")
    t.eq(lines_of(b), { t.aligned("* DONE Pay rent", ":home:"), "* TODO Read book" })
  end,

  -- org-agenda-next-line skips invisible lines: Call Bob (4) to Book hotel (6).
  ["n and p step over filtered lines"] = function(t)
    todo_list(t)
    t.answer("TAB", "home")
    press("\\")
    t.cursor(t.find_line("Call Bob"))
    press("n")
    t.eq(api.nvim_win_get_cursor(0)[1], 6)
    press("n")
    t.eq(api.nvim_win_get_cursor(0)[1], 7)
    press("pp")
    t.eq(api.nvim_win_get_cursor(0)[1], 4)
  end,

  ["r keeps the tag filter"] = function(t)
    todo_list(t)
    t.answer("TAB", "home")
    press("\\")
    press("r")
    t.eq(t.folds(), { "2-3", "4-5", "7-8" })
  end,

  -- The limit rebuilds the list with fewer entries rather than hiding lines.
  ["~ e 2 limits the list to two entries"] = function(t)
    todo_list(t)
    t.answer("e", "2")
    press("~")
    t.eq(t.asked()[3].params.prompt, "How many entries? ")
    t.eq(#t.lines(), 4)
    assert(t.lines()[4]:find("TODO Call Bob"), t.lines()[4])
    t.eq(t.folds(), {})
  end,

  -- Only Write report has an effort, 0:30, within 60 minutes.
  ["~ E 60 limits the list by total effort"] = function(t)
    todo_list(t)
    t.answer("E", "60")
    press("~")
    t.eq(#t.lines(), 3)
    assert(t.lines()[3]:find("TODO Write report"), t.lines()[3])
  end,
}
