-- Stored links, table copy-down and recalc marks, tag sparse trees,
-- refile-copy, property pairs, clocking, the calendar and the agenda
-- restriction lock. Expected text comes from emacs -Q --batch -l test/init.el.
local api = vim.api

local TS = "%[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]"

local function store(t)
  t.set("org-stored-links", "nil")
  t.command("org-store-link")
end

-- Names of the buffers shown in this tab's windows.
local function shown()
  local out = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    out[#out + 1] = vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(win)), ":t")
  end
  return out
end

return {
  ["C-c M-l inserts the last stored link and drops it from the list"] = function(t)
    t.open("ln_a.org", "* Alpha\n* Target\nbody\n")
    t.cursor(2)
    store(t)
    t.open("ln_b.org", "* B\n\n")
    t.cursor(2)
    t.keys("C-c M-l")
    t.eq(t.lines(), { "* B", "[[file:ln_a.org::*Target][Target]]", "" })
    t.eq(api.nvim_win_get_cursor(0), { 3, 0 })
    t.eq(t.eval("org-stored-links"), "nil")
  end,

  ["C-c C-M-l inserts every stored link as a list, newest first"] = function(t)
    t.open("ln_all.org", "* One\n* Two\n")
    store(t)
    t.cursor(2)
    t.command("org-store-link")
    t.open("ln_c.org", "* C\n\n")
    t.cursor(2)
    t.keys("C-c C-M-l")
    t.eq(t.lines(), { "* C", "- [[file:ln_all.org::*Two][Two]]", "- [[file:ln_all.org::*One][One]]", "" })
    t.eq(api.nvim_win_get_cursor(0), { 4, 0 })
    t.eq(t.eval("org-stored-links"), "nil")
  end,

  ["S-RET fills an empty field from above, then copies down into a new row"] = function(t)
    t.open("copydown.org", "| a | b |\n|---+---|\n| 1 | x |\n|   |   |\n")
    t.cursor(4, 2)
    -- org-table-copy-increment: the copy is one more than the field above.
    t.feed("<S-CR>")
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 | x |", "| 2 |   |" }, "empty field filled")
    t.eq(api.nvim_win_get_cursor(0), { 4, 2 })
    t.feed("<S-CR>")
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 | x |", "| 2 |   |", "| 3 |   |" }, "new row")
    t.eq(api.nvim_win_get_cursor(0), { 5, 2 })
  end,

  ["C-# rotates the row's recalc mark"] = function(t)
    t.open("marks.org", "|   | a | b |\n|---+---+---|\n|   | 1 | 2 |\n")
    t.cursor(3, 6)
    t.keys("C-#")
    t.eq(t.lines()[3], "| # | 1 | 2 |")
    t.keys("C-#")
    t.eq(t.lines()[3], "| * | 1 | 2 |")
    t.eq(api.nvim_win_get_cursor(0), { 3, 6 })
  end,

  ["C-# in a table without a mark column adds one"] = function(t)
    t.open("marks_new.org", "| a | b |\n| 1 | 2 |\n")
    t.cursor(2, 2)
    t.keys("C-#")
    t.eq(t.lines(), { "|   | a | b |", "| # | 1 | 2 |" })
    t.eq(api.nvim_win_get_cursor(0), { 2, 6 })
  end,

  ["C-c \\ with a tag match folds every body"] = function(t)
    t.open("match.org", "* A :work:\na body\n** A1\na1 text\n* B\nb body\n** B1 :work:\nb1 text\n* C :home:\nc body\n")
    t.answer("work")
    t.keys("C-c \\")
    t.eq(t.asked()[1].params.prompt, "Match: ")
    -- Emacs hides lines 2 4 6 8 10: each heading shows, its body is hidden.
    t.eq(t.folds(), { "1-2", "3-4", "5-6", "7-8", "9-10" })
  end,

  ["C-c M-w copies the subtree under the target and keeps the original"] = function(t)
    t.open("refcopy.org", t.DOC)
    t.eval([[(setq org-refile-targets '((nil :maxlevel . 2)) org-refile-use-outline-path nil
                   org-refile-history nil)]])
    t.answer("B")
    t.keys("C-c M-w")
    t.eq(t.asked()[1].params.prompt, 'Copy subtree "A" to: ')
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body b", "** A", "body a", "*** A1", "text" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 0 })
  end,

  ["C-c C-x P sets a property from one \"Prop: value\" answer"] = function(t)
    local path = t.open("propval.org", "* H\nbody\n")
    t.answer("Owner: bob")
    t.keys("C-c C-x P")
    t.eq(t.asked()[1].params.prompt, 'Enter a "[Property]: [value]" pair: ')
    t.eq(t.lines(), { "* H", ":PROPERTIES:", ":Owner:    bob", ":END:", "body" })
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  ["C-c C-x TAB clocks in and C-c C-x C-o clocks out"] = function(t)
    local path = t.open("clocktab.org", "* A\nbody\n* B\n")
    t.after(function() t.eval("(when (org-clocking-p) (org-clock-out))") end)
    t.keys("C-c C-x TAB")
    local l = t.lines()
    t.eq(#l, 6, vim.inspect(l))
    assert(l[3]:find("^CLOCK: " .. TS .. "$"), l[3])
    t.eq({ l[1], l[2], l[4], l[5], l[6] }, { "* A", ":LOGBOOK:", ":END:", "body", "* B" })
    t.eq(t.eval("(org-clocking-p)"), "t")
    t.keys("C-c C-x C-o")
    assert(t.lines()[3]:find("^CLOCK: " .. TS .. "%-%-" .. TS .. " =>  0:00$"), t.lines()[3])
    t.eq(t.eval("(org-clocking-p)"), "nil")
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  -- Emacs shows *Calendar* beside the file, on the timestamp's date.
  ["C-c > shows the calendar on the date at point"] = function(t)
    t.open("gocal.org", "* A\nSCHEDULED: <2026-11-20 Fri>\n")
    t.cursor(2, 14)
    t.keys("C-c >")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Calendar*", "calendar focused")
    assert(vim.tbl_contains(shown(), "gocal.org"), "file still shown: " .. vim.inspect(shown()))
    assert(t.find_line("November 2026"), "month shown:\n" .. table.concat(t.lines(), "\n"))
    t.eq(t.eval("(with-current-buffer calendar-buffer (calendar-cursor-to-date))"), "(11 20 2026)")
    local line, col = unpack(vim.json.decode(vim.json.decode(t.eval(
      [[(with-current-buffer calendar-buffer (format "[%d,%d]" (line-number-at-pos) (current-column)))]]))))
    t.eq(api.nvim_win_get_cursor(0), { line, col }, "cursor on Emacs's point")
  end,

  ["C-c C-x < limits the agenda to the subtree, C-c C-x > lifts it"] = function(t)
    local path = t.open("lock.org", "* P\n** TODO one\n** TODO two\n* Q\n** TODO three\n")
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    t.after(function() t.eval("(org-agenda-remove-restriction-lock t)") end)
    t.keys("C-c C-x <")
    t.answer("t")
    t.command("org-agenda")
    t.eq(vim.list_slice(t.lines(), 3), { "  lock:       TODO one", "  lock:       TODO two" }, "locked")
    vim.cmd("wincmd p")
    t.keys("C-c C-x >")
    t.answer("t")
    t.command("org-agenda")
    t.eq(vim.list_slice(t.lines(), 3),
      { "  lock:       TODO one", "  lock:       TODO two", "  lock:       TODO three" }, "lifted")
  end,
}
