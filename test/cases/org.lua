return {
  ["TAB cycles a subtree through folded, children, all"] = function(t)
    t.open("cycle.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" }, "folded")
    t.keys("TAB")
    t.eq(t.folds(), { "3-4" }, "children")
    t.keys("TAB")
    t.eq(t.folds(), {}, "subtree")
  end,

  ["S-TAB cycles the whole buffer"] = function(t)
    t.open("global.org", t.DOC)
    t.keys("<backtab>")
    t.eq(t.folds(), { "1-4", "5-6" }, "overview")
  end,

  ["C-c C-t with fast selection reads a key shown with its menu"] = function(t)
    t.open("todo.org", t.DOC)
    t.cursor(5)
    t.answer("n")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* NEXT B")
    local q = t.asked()[1]
    t.eq(q.method, "read_key")
    assert(q.params.context and q.params.context:find("%[n%] NEXT"), "menu shown: " .. vim.inspect(q))
  end,

  ["Neovim edits reach Emacs before a command"] = function(t)
    t.open("edit.org", t.DOC)
    vim.api.nvim_buf_set_lines(0, 4, 5, false, { "* Renamed" })
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO Renamed")
  end,

  ["S-<right> on a timestamp moves it a day"] = function(t)
    t.open("date.org", "* Meeting <2026-11-07 Sat>\n")
    t.cursor(1, 15)
    t.keys("<S-right>")
    t.eq(t.lines()[1], "* Meeting <2026-11-08 Sun>")
  end,

  ["TAB in a table realigns it"] = function(t)
    t.open("table.org", "| a | bbbbb |\n|-\n| ccc | d |\n")
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| a   | bbbbb |", "|-----+-------|", "| ccc | d     |" })
  end,

  ["a count is a numeric prefix argument"] = function(t)
    t.open("prefix.org", t.DOC)
    t.keys("C-c C-n", 2)
    t.eq(vim.api.nvim_win_get_cursor(0)[1], 5)
  end,

  ["scheduling reads a date string"] = function(t)
    t.open("sched.org", "* Task\n")
    t.answer("2026-12-01")
    t.keys("C-c C-s")
    t.eq(t.lines()[2], "SCHEDULED: <2026-12-01 Tue>")
  end,

  ["Escape quits a prompt without changes"] = function(t)
    t.open("quit.org", "* Task\n")
    t.answer(t.QUIT)
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* Task" })
  end,

  ["link brackets are concealed only when conceal is on"] = function(t)
    local mirror = require("emacs.mirror")
    local ns = vim.api.nvim_create_namespace("emacs")
    local function conceals()
      mirror.state[vim.api.nvim_get_current_buf()].spans = nil
      mirror.refresh_spans(vim.api.nvim_get_current_buf())
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
        if m[4].conceal then out[#out + 1] = { m[3], m[4].end_col } end
      end
      return out
    end
    t.open("link.org", "see [[https://example.com][example]] here\n")
    t.config("conceal", false)
    t.eq(conceals(), {}, "conceal = false")
    t.config("conceal", true)
    t.eq(conceals(), { { 4, 27 }, { 34, 36 } }, "conceal = true")
  end,

  ["narrowing keeps the whole file in Neovim"] = function(t)
    t.open("narrow.org", t.DOC)
    t.cursor(5)
    t.keys("C-x n s")
    t.eq(#t.lines(), 6)
    t.eq(t.eval([[(with-current-buffer "narrow.org" (buffer-narrowed-p))]]), "t")
  end,

  ["Neovim fold keys drive Emacs's folding"] = function(t)
    t.open("zkeys.org", t.DOC)
    vim.api.nvim_feedkeys("zM", "x", false)
    t.eq(t.folds(), { "1-4", "5-6" }, "zM")
    vim.api.nvim_feedkeys("zR", "x", false)
    t.eq(t.folds(), {}, "zR")
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.folds(), {}, "still open after a later command")
  end,

  ["M-RET with the cursor on the last character adds a heading below"] = function(t)
    t.open("eol.org", "* Heading\n")
    t.cursor(1, 8)
    t.keys("M-RET")
    t.eq(t.lines(), { "* Heading", "* " })
  end,

  ["gq fills a paragraph with org's fill, keeping the heading"] = function(t)
    t.open("fill.org", "* Heading\n" .. string.rep("word ", 30) .. "\n")
    vim.cmd("normal! 2Ggqip")
    local lines = t.lines()
    t.eq(lines[1], "* Heading")
    assert(#lines >= 3 and #lines[2] <= 70, "filled at fill-column 70: " .. vim.inspect(lines))
  end,

  ["C-u before an Emacs key is the universal argument"] = function(t)
    t.open("cu.org", "* Task\nSCHEDULED: <2026-12-01 Tue>\n")
    t.answer("C-s") -- the rest of C-c C-s, read by Emacs
    t.feed("<C-u><C-c>")
    -- C-u C-c C-s removes the schedule.
    t.eq(t.lines(), { "* Task" })
  end,

  ["C-u alone scrolls as in Neovim"] = function(t)
    t.open("scroll.org", string.rep("line\n", 200))
    vim.cmd("normal! G")
    local before = vim.fn.line(".")
    t.feed("<C-u>")
    assert(vim.fn.line(".") < before, "scrolled without waiting for 'timeoutlen'")
    vim.wait(vim.o.timeoutlen + 200)
  end,

  ["C-u before an Emacs key leaves the cursor where it was"] = function(t)
    t.open("cu-view.org", string.rep("line\n", 100) .. "* Task\nSCHEDULED: <2026-12-01 Tue>\n")
    t.cursor(101)
    t.answer("C-s")
    t.feed("<C-u><C-c>")
    t.eq({ vim.fn.line("."), t.lines()[102] }, { 101, nil })
  end,

  ["C-j from a terminal (<NL>) reaches Emacs as C-j"] = function(t)
    t.eq(require("emacs.keys").to_emacs("<NL>"), "C-j")
  end,

  ["zo on a folded drawer opens the drawer"] = function(t)
    t.open("drawer.org", "* Task\n:LOGBOOK:\nCLOCK: [2026-11-07 Sat 05:02]--[2026-11-07 Sat 05:10] =>  0:08\n:END:\nbody\n")
    t.eq(t.folds(), { "2-4" }, "drawer folded at startup")
    t.cursor(2)
    t.feed("zo")
    t.eq(t.folds(), {}, "drawer open")
  end,

  ["BS on a table line goes through Emacs and keeps the columns"] = function(t)
    t.open("bs.org", "| abc | x |\n| d   | y |\n")
    t.cursor(1, 4) -- on "c": append after it, then delete it
    t.feed("a<BS><Esc>")
    t.eq(t.lines()[1], "| ab  | x |")
  end,

  -- Emacs's preloaded Lisp is native code; it reaches the input primitives
  -- only through trampolines.
  ["a native-compiled reader (read-regexp) asks Neovim"] = function(t)
    t.open("native.org", "* A\n")
    t.answer("DONE")
    t.eq(t.eval([[(list (subr-native-elisp-p (symbol-function 'read-regexp)) (read-regexp "Mark: "))]]),
      '(t "DONE")')
  end,

  ["text hidden without an ellipsis folds without one"] = function(t)
    t.open("noell.org", "* A\nx\ny\n")
    t.eval([[(with-current-buffer "noell.org"
      (add-to-invisibility-spec 'nvbtest)
      (put-text-property 4 (point-max) 'invisible 'nvbtest))]])
    t.command("ignore")
    t.eq(t.folds(), { "1-3" })
    t.eq(vim.fn.foldtextresult(1), "* A")
  end,

  ["an overlay's before-string is drawn in Neovim"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    t.open("before.org", "* A\nbody\n")
    t.eval([[(with-current-buffer "before.org"
      (overlay-put (make-overlay 5 5) 'before-string "@1 "))]])
    t.command("ignore")
    local found
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("emacs"), { 1, 0 }, { 1, -1 }, { details = true })) do
      if m[4].virt_text and m[4].virt_text[1][1] == "@1 " then found = m[3] end
    end
    t.eq(found, 0)
  end,

  ["multi-line overlay text (agenda entry text) is drawn as lines below"] = function(t)
    t.open("ml.org", "* A\nbody\n")
    t.eval([[(with-current-buffer "ml.org"
      (overlay-put (make-overlay 4 4) 'after-string "\n  first\n  second"))]])
    t.command("ignore")
    local lines
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("emacs"), 0, -1, { details = true })) do
      if m[4].virt_lines then lines = vim.tbl_map(function(l) return l[1][1] end, m[4].virt_lines) end
    end
    t.eq(lines, { "  first", "  second" })
  end,
}
