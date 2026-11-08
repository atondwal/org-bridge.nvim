-- Archiving, footnotes, structure templates, list bullets and numbering,
-- priorities.
local api = vim.api

local TIME = "%[?%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d%]?"

return {
  ["C-c C-x C-a archives to <file>_archive, which gets a saved Neovim buffer"] = function(t)
    local src = t.open("arch.org", "* Keep\n* TODO Old task :work:\nold body\n** Sub\n* Last\n")
    local archive = src .. "_archive"
    os.remove(archive)
    t.cursor(2)
    t.keys("C-c C-x C-a")
    t.eq(t.lines(), { "* Keep", "* Last" }, "source")
    t.eq(api.nvim_win_get_cursor(0)[1], 2, "point on the next heading")
    local buf = vim.fn.bufnr(archive)
    assert(buf ~= -1, "no Neovim buffer for " .. archive)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    assert(lines[9] and lines[9]:match("^:ARCHIVE_TIME: " .. TIME .. "$"), vim.inspect(lines))
    t.eq(lines, {
      "#    -*- mode: org -*-", "", "", "Archived entries from file " .. src, "", "",
      "* TODO Old task :work:", ":PROPERTIES:", lines[9], ":ARCHIVE_FILE: " .. src,
      ":ARCHIVE_CATEGORY: arch", ":ARCHIVE_TODO: TODO", ":END:", "old body", "** Sub",
    }, "archive mirror")
    t.eq(t.emacs_lines(archive), lines, "Emacs's copy")
    -- org-archive-subtree-save-file-p is from-org: Emacs saved the archive.
    t.eq(vim.bo[buf].modified, false, "archive saved")
    t.eq(t.read_file(archive), table.concat(lines, "\n") .. "\n", "archive on disk")
    t.eq(vim.bo.modified, true, "source left unsaved, as in Emacs")
    -- The archive stays an ordinary saveable mirror.
    api.nvim_buf_set_lines(buf, -1, -1, false, { "note" })
    api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
    t.eq(t.read_file(archive), table.concat(lines, "\n") .. "\nnote\n", "disk after :write")
    t.eq(t.eval(([[(buffer-modified-p (get-file-buffer %q))]]):format(archive)), "nil",
      "Emacs sees the save")
  end,

  ["a second C-c C-x C-a appends to the open archive buffer"] = function(t)
    local src = t.open("arch2.org", "* One\n* Two\n")
    local archive = src .. "_archive"
    os.remove(archive)
    t.keys("C-c C-x C-a")
    t.keys("C-c C-x C-a")
    t.eq(t.lines(), { "" }, "source empty")
    local buf = vim.fn.bufnr(archive)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    t.eq(vim.tbl_filter(function(l) return l:match("^%*") end, lines), { "* One", "* Two" })
    t.eq(t.emacs_lines(archive), lines, "Emacs's copy")
    t.eq(t.read_file(archive), table.concat(lines, "\n") .. "\n", "both saved")
  end,

  ["C-c C-x A moves the subtree under a folded Archive sibling"] = function(t)
    t.open("sibling.org", "* P\n** A\na body\n** B\n")
    t.cursor(2)
    t.keys("C-c C-x A")
    local lines = t.lines()
    assert(lines[6] and lines[6]:match("^:ARCHIVE_TIME: " .. TIME .. "$"), vim.inspect(lines))
    t.eq(lines, { "* P", "** B", t.aligned("** Archive", ":ARCHIVE:"), "*** A", ":PROPERTIES:",
      lines[6], ":END:", "a body" })
    t.eq(api.nvim_win_get_cursor(0)[1], 2)
    t.eq(t.folds(), { "3-8" }, "Archive sibling folded")
    t.keys("C-c C-x A")
    lines = t.lines()
    t.eq(lines[2], t.aligned("** Archive", ":ARCHIVE:"))
    t.eq(lines[8], "*** B", "B archived after A")
    t.eq(#lines, 11)
    t.eq(t.folds(), { "2-11" })
  end,

  ["C-c C-x f adds an auto-numbered footnote and jumps to its definition"] = function(t)
    t.open("fn.org", "* H\nSome text.\n")
    t.cursor(2)
    t.answer("C-x", "f")
    t.feed("A<C-c>")
    t.eq(t.lines(), { "* H", "Some text.[fn:1]", "", "* Footnotes", "", "[fn:1] " })
    t.eq(api.nvim_win_get_cursor(0)[1], 6, "at the definition")
    t.cursor(2, 11)
    t.keys("C-c C-x f")
    t.eq(api.nvim_win_get_cursor(0), { 6, 6 }, "on a reference, it goes to the definition")
  end,

  ["C-c C-x f asks for a label when org-footnote-auto-label says so"] = function(t)
    t.set("org-footnote-auto-label", "nil")
    t.open("fnlabel.org", "* H\nSome text.\n")
    t.cursor(2)
    t.answer("C-x", "f", "note")
    t.feed("A<C-c>")
    t.set("org-footnote-auto-label", "'confirm")
    t.open("fnconfirm.org", "* H\nA[fn:note] B.\n\n* Footnotes\n\n[fn:note] x\n")
    t.cursor(2)
    t.answer("C-x", "f", "note")
    t.feed("A<C-c>")
    local q = t.asked()[3]
    t.eq({ q.method, q.params.prompt, q.params.candidates }, { "completing_read",
      "Label (leave empty for anonymous): ", {} })
    q = t.asked()[6]
    -- Emacs proposes the next free number as initial input.
    t.eq({ q.method, q.params.initial }, { "completing_read", "1" }, "confirm proposes 1")
    t.eq(t.lines(), { "* H", "A[fn:note] B.[fn:note]", "", "* Footnotes", "", "[fn:note] x" },
      "existing label: only a reference")
    vim.cmd("buffer fnlabel.org")
    t.eq(t.lines(), { "* H", "Some text.[fn:note]", "", "* Footnotes", "", "[fn:note] " })
  end,

  ["C-c C-, shows the template menu and inserts #+begin_quote"] = function(t)
    t.open("tmpl.org", "* H\nquoted text\n")
    t.cursor(2)
    t.answer("q")
    t.keys("C-c C-,")
    local q = t.asked()[1]
    t.eq({ q.method, q.params.prompt }, { "read_key", "Key: " })
    assert(q.params.context and q.params.context:find("[q]     quote", 1, true),
      "menu shown: " .. vim.inspect(q.params))
    t.eq(t.lines(), { "* H", "#+begin_quote", "#+end_quote", "quoted text" })
    t.eq(api.nvim_win_get_cursor(0)[1], 3)
    t.eq(#api.nvim_list_wins(), 1, "menu window gone")
    -- With lines selected, the block wraps them.
    t.open("tmplregion.org", "* H\nl1\nl2\n")
    t.cursor(2)
    t.answer("C-,", "q")
    t.feed("Vj<C-c>")
    t.eq(t.lines(), { "* H", "#+begin_quote", "l1", "l2", "#+end_quote" }, "region")
  end,

  ["S-right/S-left cycle list bullets; numbered lists renumber"] = function(t)
    t.open("bullets.org", "* L\n- one\n- two\n  - sub\n")
    t.cursor(2)
    t.feed("<S-Right>")
    t.eq(t.lines(), { "* L", "+ one", "+ two", "  - sub" })
    t.feed("<S-Right>")
    t.eq(t.lines(), { "* L", "1. one", "2. two", "   - sub" }, "numbered, sub-item reindented")
    t.feed("<S-Right>")
    t.eq(t.lines(), { "* L", "1) one", "2) two", "   - sub" })
    t.feed("<S-Left>")
    t.eq(t.lines(), { "* L", "1. one", "2. two", "   - sub" })
    t.open("renum.org", "* L\n1. a\n2. b\n3. c\n")
    t.cursor(2)
    t.feed("<M-Down>")
    t.eq(t.lines(), { "* L", "1. b", "2. a", "3. c" }, "M-down renumbers")
    t.eq(api.nvim_win_get_cursor(0)[1], 3)
    api.nvim_buf_set_lines(0, 0, -1, false, { "* L", "1. a", "5. b", "9. c" })
    t.cursor(2)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "* L", "1. a", "2. b", "3. c" }, "C-c C-c repairs numbering")
    t.cursor(4)
    t.feed("A<M-CR>new<Esc>")
    t.eq(t.lines(), { "* L", "1. a", "2. b", "3. c", "4. new" }, "M-RET numbers the new item")
  end,

  ["S-up/S-down set heading priorities"] = function(t)
    t.open("prio.org", "* A\n* TODO B\n")
    -- No priority yet: both directions start at the default, B.
    t.feed("<S-Up>")
    t.eq(t.lines()[1], "* [#B] A")
    t.feed("<S-Up>")
    t.eq(t.lines()[1], "* [#A] A")
    t.cursor(2)
    t.feed("<S-Down>")
    t.eq(t.lines(), { "* [#A] A", "* TODO [#B] B" })
    t.feed("<S-Down>")
    t.eq(t.lines()[2], "* TODO [#C] B")
  end,
}
