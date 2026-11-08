-- Narrowing (C-x n s/b/w) and sorting (C-c ^ on entries, lists, tables).
-- Neovim always shows the whole file; Emacs keeps the restriction.
-- Expectations come from the same keys in `emacs -Q --batch -l test/init.el`.

-- Accessible region in Emacs as "first-last" lines (last = point-max's line).
local function restriction(t, path)
  return vim.json.decode(t.eval(([[(with-current-buffer (get-file-buffer %q)
    (format "%%d-%%d" (line-number-at-pos (point-min) t) (line-number-at-pos (point-max) t)))]]):format(path)))
end

local function narrowed(t, path)
  return t.eval(([[(with-current-buffer (get-file-buffer %q) (if (buffer-narrowed-p) "yes" "no"))]]):format(path))
end

local function cursor() return vim.api.nvim_win_get_cursor(0) end

local KIDS = "* Top\n** delta\n** Alpha\n** charlie\n** bravo\n* Other\n"

-- Open content, put the cursor at line/col and run C-c ^ answering key.
local function sort(t, name, content, line, col, key)
  local path = t.open(name, content)
  t.cursor(line, col)
  t.answer(key)
  t.keys("C-c ^")
  return path
end

-- The prompt of the index'th input request.
local function prompt(t, index) return t.asked()[index].params.prompt end

return {
  ["C-x n s keeps the whole file in Neovim and narrows Emacs"] = function(t)
    local path = t.open("nshow.org", t.DOC)
    t.cursor(5)
    t.keys("C-x n s")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body b" })
    t.eq(narrowed(t, path), [["yes"]])
    t.eq(restriction(t, path), "5-7")
    t.keys("C-x n w")
    t.eq(narrowed(t, path), [["no"]])
  end,

  ["M-down stops at the restriction, and moves after C-x n w"] = function(t)
    local path = t.open("nmdown.org", t.DOC)
    t.keys("C-x n s")
    t.keys("M-<down>")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body b" })
    local msgs = vim.fn.execute("messages")
    assert(msgs:find("Cannot move past superior level or buffer limit", 1, true), "error shown: " .. msgs)
    t.keys("C-x n w")
    t.keys("M-<down>")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a", "** A1", "text" })
    t.eq(t.emacs_lines(path), t.lines())
    t.eq(cursor()[1], 3)
  end,

  ["C-c C-t and C-RET inside a restriction"] = function(t)
    local path = t.open("ntodo.org", t.DOC)
    t.keys("C-x n s")
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* DONE A", "body a", "** A1", "text", "* B", "body b" })
    t.eq(t.emacs_lines(path), t.lines())
    t.eq(restriction(t, path), "1-4", "still narrowed to A")
    path = t.open("ncret.org", t.DOC)
    t.keys("C-x n s")
    t.cursor(2)
    t.keys("C-<return>")
    -- Emacs inserts at the restriction's end and leaves an empty line before * B.
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* ", "", "* B", "body b" })
    t.eq(t.emacs_lines(path), t.lines())
    t.eq(cursor()[1], 5)
  end,

  ["S-TAB in a narrowed subtree folds only the restriction"] = function(t)
    t.open("nstab.org", t.DOC)
    t.keys("C-x n s")
    t.keys("<backtab>")
    t.eq(t.folds(), { "1-4" })
  end,

  ["Neovim edits outside or across a restriction reach Emacs"] = function(t)
    local path = t.open("nedit.org", t.DOC)
    t.cursor(5)
    t.keys("C-x n s")
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { "body AA" })
    t.cursor(6)
    t.keys("C-x n s") -- syncs the edits; B moved down a line
    t.eq(restriction(t, path), "6-8")
    t.keys("C-x n w")
    t.eq(t.emacs_lines(path), { "new", "* A", "body AA", "** A1", "text", "* B", "body b" })

    path = t.open("ndelete.org", "* A\nbody a\n* B\nbody b\n")
    t.cursor(3)
    t.keys("C-x n s")
    vim.api.nvim_buf_set_lines(0, 2, 4, false, {})
    t.keys("C-x n w")
    t.eq(t.emacs_lines(path), { "* A", "body a" }, "the whole restriction deleted")

    path = t.open("njoin.org", t.DOC)
    t.keys("C-x n s")
    t.cursor(4)
    t.feed("J")
    t.keys("C-x n w")
    t.eq(t.emacs_lines(path), { "* A", "body a", "** A1", "text * B", "body b" }, "joined across the edge")
  end,

  ["C-x n b narrows to the block around point, or says there is none"] = function(t)
    local path = t.open("nblock.org", "* H\ntext\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\nafter\n")
    t.cursor(4)
    t.keys("C-x n b")
    t.eq(restriction(t, path), "3-5")
    t.keys("M-<")
    t.eq(cursor()[1], 3, "M-< stops at the block's first line")
    path = t.open("nnoblock.org", "* H\n#+begin_example\nx\n#+end_example\n")
    t.keys("C-x n b")
    t.eq(narrowed(t, path), [["no"]])
    local msgs = vim.fn.execute("messages")
    assert(msgs:find("Not in a block", 1, true), "error shown: " .. msgs)
  end,

  ["C-c ^ a, A and C-u C-c ^ a sort children by name"] = function(t)
    sort(t, "salpha.org", KIDS, 1, 0, "a")
    t.eq(t.lines(), { "* Top", "** Alpha", "** bravo", "** charlie", "** delta", "* Other" })
    t.eq(t.asked()[1].method, "read_key")
    assert(prompt(t, 1):find("Sort children:", 1, true), prompt(t, 1))
    sort(t, "srev.org", KIDS, 1, 0, "A")
    t.eq(t.lines(), { "* Top", "** delta", "** charlie", "** bravo", "** Alpha", "* Other" })
    t.open("scase.org", "* Top\n** banana\n** Apple\n** apple\n** Banana\n")
    t.answer("a")
    t.keys("C-c ^", 4)
    t.eq(t.lines(), { "* Top", "** apple", "** Apple", "** banana", "** Banana" }, "case-sensitive")
  end,

  ["C-c ^ sorts by TODO order, priority, timestamp and property"] = function(t)
    sort(t, "stodo.org", "* Top\n** DONE d\n** x\n** TODO t\n** NEXT n\n", 1, 0, "o")
    t.eq(t.lines(), { "* Top", "** TODO t", "** NEXT n", "** x", "** DONE d" })
    sort(t, "spri.org", "* Top\n** [#C] c\n** none\n** [#A] a\n** [#B] b\n", 1, 0, "p")
    -- No cookie counts as the default priority B; the sort is stable.
    t.eq(t.lines(), { "* Top", "** [#A] a", "** none", "** [#B] b", "** [#C] c" })
    sort(t, "stime.org", "* Top\n** x\n<2026-03-01 Sun>\n** y\n<2026-01-05 Mon>\n** z\n", 1, 0, "t")
    t.eq(t.lines(), { "* Top", "** y", "<2026-01-05 Mon>", "** x", "<2026-03-01 Sun>", "** z" })
    t.open("sprop.org", "* Top\n** b\n:PROPERTIES:\n:P: 2\n:END:\n** a\n:PROPERTIES:\n:P: 10\n:END:\n")
    t.answer("r", "P")
    t.keys("C-c ^")
    t.eq(t.asked()[#t.asked()].method, "completing_read")
    -- Property values compare as text: "10" < "2".
    t.eq(t.lines(), { "* Top", "** a", ":PROPERTIES:", ":P: 10", ":END:", "** b", ":PROPERTIES:", ":P: 2", ":END:" })
  end,

  ["C-c ^ on top-level entries, a Visual selection, bodies and folds"] = function(t)
    sort(t, "stop.org", "#+TITLE: x\n* b\n* c\n* a\n", 1, 0, "a")
    t.eq(t.lines(), { "#+TITLE: x", "* a", "* b", "* c" }, "before the first heading")
    t.open("sregion.org", "* z\n* c\n* b\n* a\n* y\n")
    t.cursor(2)
    t.answer("^", "a")
    t.feed("Vjj<C-c>")
    t.eq(t.lines(), { "* z", "* a", "* b", "* c", "* y" }, "Visual selection")
    assert(prompt(t, 3):find("Sort region:", 1, true), prompt(t, 3))
    sort(t, "sbody.org", "* Top\nintro\n** b\nbb\n** a\naa\n", 1, 0, "a")
    t.eq(t.lines(), { "* Top", "intro", "** a", "aa", "** b", "bb" }, "parent body stays")
    t.open("sfold.org", "* Top\n** b\nbb\n** a\naa\n** c\ncc\n")
    t.cursor(2)
    t.keys("TAB")
    t.cursor(4)
    t.keys("TAB")
    t.eq(t.folds(), { "2-3", "4-5" }, "folded before sorting")
    t.cursor(1)
    t.answer("a")
    t.keys("C-c ^")
    t.eq(t.lines(), { "* Top", "** a", "aa", "** b", "bb", "** c", "cc" })
    t.eq(t.folds(), {}, "Emacs shows the sorted children")
  end,

  ["C-c ^ in a narrowed subtree sorts its children"] = function(t)
    local path = t.open("snarrow.org", "* Top\n** b\n** a\n* Z\n** d\n** c\n")
    t.keys("C-x n s")
    t.answer("a")
    t.keys("C-c ^")
    t.keys("C-x n w")
    -- Emacs adds the empty line after the last child.
    t.eq(t.lines(), { "* Top", "** a", "** b", "", "* Z", "** d", "** c" })
    t.eq(t.emacs_lines(path), t.lines())
  end,

  ["C-c ^ sorts plain lists"] = function(t)
    sort(t, "slist.org", "* L\n- pear\n- apple\n  - sub\n- fig\n", 2, 0, "a")
    t.eq(t.lines(), { "* L", "- apple", "  - sub", "- fig", "- pear" }, "sub-items move with their item")
    assert(prompt(t, 1):find("Sort plain list:", 1, true), prompt(t, 1))
    sort(t, "slistn.org", "* L\n- 10 x\n- 9 y\n- 100 z\n", 3, 0, "N")
    t.eq(t.lines(), { "* L", "- 100 z", "- 10 x", "- 9 y" }, "numeric, reversed")
    t.eq(cursor(), { 2, 0 })
    sort(t, "slistx.org", "* L\n- [ ] a\n- [X] b\n- [ ] c\n", 2, 0, "x")
    t.eq(t.lines(), { "* L", "- [ ] a", "- [ ] c", "- [X] b" }, "checked last")
  end,

  ["C-c ^ in a table sorts rows by the cursor's column"] = function(t)
    local tbl = "| n | w |\n|---+---|\n| 3 | c |\n| 10 | a |\n| 2 | b |\n"
    sort(t, "stnum.org", tbl, 3, 2, "n")
    t.eq(t.lines(), { "| n | w |", "|---+---|", "| 2 | b |", "| 3 | c |", "| 10 | a |" })
    assert(prompt(t, 1):find("Sort Table:", 1, true), prompt(t, 1))
    sort(t, "stalpha.org", tbl, 4, 7, "a")
    t.eq(t.lines(), { "| n | w |", "|---+---|", "| 10 | a |", "| 2 | b |", "| 3 | c |" }, "second column")
    sort(t, "sthline.org", "| a |\n|---|\n| z |\n| y |\n|---|\n| c |\n| b |\n", 4, 2, "a")
    t.eq(t.lines(), { "| a |", "|---|", "| y |", "| z |", "|---|", "| c |", "| b |" }, "between hlines only")
    t.eq(cursor(), { 4, 2 })
    -- On the first bar there is no current column: Emacs asks for one.
    t.open("stcol.org", "| n | w |\n| 3 | c |\n| 1 | a |\n")
    t.cursor(2, 0)
    t.answer("2", "a")
    t.keys("C-c ^")
    t.eq(t.lines(), { "| 1 | a |", "| 3 | c |", "| n | w |" })
  end,

  ["an org key outside the restriction is refused, and C-x n w still widens"] = function(t)
    t.open("outside.org", "* A\nbody a\n** A1\ntext\n* B\nbody b\n")
    t.keys("C-x n s")
    t.cursor(5)
    vim.cmd("messages clear")
    t.keys("C-c C-t")
    assert(vim.fn.execute("messages"):find("outside the narrowed region", 1, true), "refused")
    t.eq(t.lines()[3], "** A1", "A1 untouched")
    t.keys("C-x n w")
    t.cursor(5)
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* DONE B")
  end,
}
