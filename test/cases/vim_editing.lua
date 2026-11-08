-- Vim-native edits on org structure (>>, J, gU, :s, block insert, cw,
-- xp/ddp, :m, :sort, registers, gv, <C-a>), with Emacs following.
-- Org-side expectations: emacs -Q --batch -l test/init.el.
local mirror = require("emacs.mirror")

-- Emacs's copy must match Neovim's after the debounced sync.
local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- Evaluate expr in path's Emacs buffer at the start of line n; prin1 text.
local function at_line(t, path, n, expr)
  return vim.json.decode(t.eval(([[(with-current-buffer (get-file-buffer %q)
    (save-excursion (goto-char (point-min)) (forward-line %d) (format "%%S" %s)))]]):format(path, n - 1, expr)))
end

return {
  -- Vim's >> is a raw shift: it never demotes. With -u NONE defaults
  -- (shiftwidth 8, noexpandtab) it inserts a tab.
  [">> shifts text; a shifted heading stops being a heading in Emacs"] = function(t)
    local path = t.open("shift.org", "* A\n- one\n- two\n* B\n")
    t.cursor(3)
    t.feed(">>")
    t.eq(t.lines()[3], "\t- two")
    agree(t, path, ">> on an item")
    t.eq(at_line(t, path, 3, "(org-list-get-parent (point-at-bol) (org-list-struct) (org-list-parents-alist (org-list-struct)))"),
      "5", "Emacs sees the shifted item as a child of - one")
    t.cursor(4)
    t.feed(">>")
    t.eq(t.lines()[4], "\t* B")
    agree(t, path, ">> on a heading")
    t.eq(at_line(t, path, 4, "(org-at-heading-p)"), "nil", "no longer a heading")
    t.feed("<<")
    t.eq(t.lines()[4], "* B", "<< restores it")
    agree(t, path, "<<")
    t.eq(at_line(t, path, 4, "(org-at-heading-p)"), "t")
  end,

  -- Emacs's M-^ on the body line gives the same text: tags are no longer
  -- at the end, so org reads them as title text.
  ["J joins a heading with its body; Emacs reads the tags as title"] = function(t)
    local path = t.open("join.org", "* A :tag:\nbody a\n* B\n")
    t.feed("J")
    t.eq(t.lines(), { "* A :tag: body a", "* B" })
    agree(t, path)
    t.eq(at_line(t, path, 1, "(list (org-get-tags) (org-no-properties (org-get-heading t t t t)))"), '(nil "A :tag: body a")')
  end,

  ["gU on a heading makes todo a TODO keyword and the tags uppercase"] = function(t)
    local path = t.open("case.org", "* todo a :work:\n* B\n")
    t.feed("gUU")
    t.eq(t.lines()[1], "* TODO A :WORK:")
    agree(t, path, "gUU")
    t.eq(at_line(t, path, 1, "(list (org-no-properties (org-get-todo-state)) (org-get-tags))"), '("TODO" ("WORK"))')
    t.feed("0w~")
    t.eq(t.lines()[1], "* tODO A :WORK:", "~ on the keyword")
    agree(t, path, "~")
    t.eq(at_line(t, path, 1, "(org-get-todo-state)"), "nil")
  end,

  [":s/TODO/DONE/ then C-c C-t on one heading; the agenda sees both"] = function(t)
    local path = t.open("subst.org", "* TODO A\n* TODO B\n* TODO C\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    vim.cmd("silent %s/TODO/DONE/")
    t.eq(t.lines(), { "* DONE A", "* DONE B", "* DONE C" })
    agree(t, path, ":s")
    t.cursor(2)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* DONE A", "* TODO B", "* DONE C" }, "C-c C-t on B")
    agree(t, path, "C-c C-t")
    local file_buf = vim.api.nvim_get_current_buf()
    t.answer("t")
    t.command("org-agenda")
    assert(t.find_line("TODO B"), "agenda lists B:\n" .. table.concat(t.lines(), "\n"))
    assert(not t.find_line("TODO A") and not t.find_line("TODO C"),
      "agenda omits A and C:\n" .. table.concat(t.lines(), "\n"))
    t.eq(vim.api.nvim_buf_get_lines(file_buf, 0, -1, false), { "* DONE A", "* TODO B", "* DONE C" })
  end,

  -- Emacs, TAB on the result of the block insert: | xa  | b | / | xcc | d |
  ["visual-block I in a table column, then TAB realigns"] = function(t)
    local path = t.open("block.org", "| a | b |\n| cc | d |\n")
    t.cursor(1, 2)
    t.feed("<C-v>jIx<Esc>")
    t.eq(t.lines(), { "| xa | b |", "| xcc | d |" }, "x inserted on both rows")
    agree(t, path, "block insert")
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| xa  | b |", "| xcc | d |" }, "TAB")
    agree(t, path, "TAB")
  end,

  -- Emacs, TAB after the cell reads "long": | long | bb | / | ccc  | d  |
  ["cw on a table cell, then TAB realigns"] = function(t)
    local path = t.open("cw.org", "| a | bb |\n| ccc | d |\n")
    t.cursor(1, 2)
    t.feed("cwlong<Esc>")
    t.eq(t.lines(), { "| long | bb |", "| ccc | d |" }, "cw")
    agree(t, path, "cw")
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| long | bb |", "| ccc  | d  |" }, "TAB")
    agree(t, path, "TAB")
  end,

  ["xp fixes a keyword and ddp swaps items inside a subtree"] = function(t)
    local path = t.open("swap.org", "* OTDO A\n- one\n- two\n* B\n")
    t.cursor(1, 2)
    t.feed("xp")
    t.eq(t.lines()[1], "* TODO A", "xp")
    agree(t, path, "xp")
    t.eq(at_line(t, path, 1, "(org-no-properties (org-get-todo-state))"), '"TODO"')
    t.cursor(2)
    t.feed("ddp")
    t.eq(t.lines(), { "* TODO A", "- two", "- one", "* B" }, "ddp")
    agree(t, path, "ddp")
  end,

  [":m moves a heading line; on a closed fold it moves the subtree"] = function(t)
    local path = t.open("move.org", t.DOC)
    vim.cmd("5m0")
    t.eq(t.lines(), { "* B", "* A", "body a", "** A1", "text", "body b" }, ":5m0 leaves the body")
    agree(t, path, ":5m0")
    vim.cmd("silent undo")
    agree(t, path, "u")
    t.cursor(1)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    vim.cmd("m$")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a", "** A1", "text" }, ":m$ on the fold")
    agree(t, path, ":m$")
    t.eq(t.folds(), { "3-6" }, "the moved subtree stays folded")
  end,

  -- Emacs's C-c ^ a on the same list gives the same order.
  [":sort on a list matches org-sort-list alphabetically"] = function(t)
    local path = t.open("sort.org", "* L\n- c\n- a\n- b\n")
    vim.cmd("2,4sort")
    t.eq(t.lines(), { "* L", "- a", "- b", "- c" })
    agree(t, path)
  end,

  ['"ayy on a closed fold yanks the subtree; "ap puts it'] = function(t)
    local path = t.open("reg.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    t.feed('"ayy')
    t.eq(vim.fn.getreg("a"), "* A\nbody a\n** A1\ntext\n")
    t.feed('G"ap')
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body b", "* A", "body a", "** A1", "text" })
    agree(t, path)
  end,

  -- No Emacs counterpart: Vim's gv reselects the last Visual area.
  ["gv after M-right on a Visual selection reselects the same lines"] = function(t)
    local path = t.open("gv.org", "* A\n* B\n* C\n")
    t.feed("Vj<M-Right>")
    t.eq(t.lines(), { "** A", "** B", "* C" }, "M-right demotes the region")
    agree(t, path)
    t.feed("<Esc>gg")
    t.feed("gv")
    t.eq(vim.fn.mode(), "V", "gv enters Visual")
    t.eq({ vim.fn.line("v"), vim.fn.line(".") }, { 1, 2 }, "the demoted lines")
  end,

  -- Emacs: a marker on A1 stays on A1 when M-S-right demotes the subtree.
  ["a mark on a line an Emacs command rewrote stays on that line"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("Neovim 0.9's nvim_buf_set_text drops the line's marks") end
    local path = t.open("marks.org", t.DOC)
    t.cursor(3)
    t.feed("mb")
    t.cursor(1)
    t.keys("M-S-<right>")
    t.eq(t.lines(), { "** A", "body a", "*** A1", "text", "* B", "body b" })
    agree(t, path)
    t.eq(vim.api.nvim_buf_get_mark(0, "b"), { 3, 0 }, "'b still on A1")
  end,

  -- Emacs's S-up on the day gives <2026-11-08 Sun>. Vim's <C-a> sees "-07"
  -- as a negative number.
  ["<C-a> on a timestamp's day is Vim arithmetic, not org's S-up"] = function(t)
    local path = t.open("inc.org", "* T\n<2026-11-07 Sat>\n")
    t.cursor(2, 9)
    t.feed("<C-a>")
    t.eq(t.lines()[2], "<2026-11-06 Sat>", "<C-a> decrements the 'negative' day")
    agree(t, path, "<C-a>")
    t.cursor(2, 9)
    t.feed("<S-Up>")
    t.eq(t.lines()[2], "<2026-11-07 Sat>", "S-up goes through Emacs")
    agree(t, path, "S-up")
  end,

  -- Emacs's markers follow a subtree M-down moves; Neovim's marks too.
  ["a mark in a subtree M-down moves follows its line"] = function(t)
    local path = t.open("mark_move.org", "* A\nbody a\n* B\nbody b\n")
    t.cursor(2)
    t.feed("ma")
    t.cursor(1)
    t.feed("<M-Down>")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a" })
    t.eq(vim.api.nvim_buf_get_mark(0, "a")[1], 4, "'a on body a")
    agree(t, path)
  end,
}
