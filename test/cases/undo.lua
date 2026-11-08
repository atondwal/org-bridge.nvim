-- Undo across both sides: Neovim's u and <C-r> after Emacs commands, Emacs's
-- C-_ after Emacs commands and Neovim edits, typing in tables, folding.
-- Expected C-_ results: emacs -Q --batch with an undo boundary per command.
local mirror = require("emacs.mirror")

local DOC_LINES = { "* A", "body a", "** A1", "text", "* B", "body b" }
local TABLE = "| a | bb |\n| ccc | d |\n"

-- Neovim's u / <C-r>, then the debounced sync so Emacs has the result.
local function undo() vim.cmd("silent undo"); mirror.sync() end
local function redo() vim.cmd("silent redo"); mirror.sync() end

-- Enter Insert mode with `cmd` and type `chars`, pausing after each one as
-- a person would: keys typed on a table line reach Emacs on the event loop.
-- Fed as typed ("t"): Neovim closes an undo step only between typed keys.
local function type_slowly(t, cmd, chars)
  -- Emacs's 10 s undo-boundary timer, if it fires mid-word, splits the
  -- word's undo step (as in Emacs); keep it out of the measured typing.
  t.eval([[(when (timerp undo-auto-current-boundary-timer)
             (cancel-timer undo-auto-current-boundary-timer)
             (setq undo-auto-current-boundary-timer nil))]])
  vim.keymap.set("i", "<F11>", function() vim.wait(50) end, { buffer = true })
  local keys = cmd .. chars:gsub(".", "%0<F11>") .. "<Esc>"
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function agree(t, path, what) t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees") end

return {
  ["u after M-RET removes the new heading in one step"] = function(t)
    local path = t.open("u_mret.org", t.DOC)
    t.cursor(5, 2)
    t.keys("M-RET")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "* ", "body b" }, "M-RET")
    undo()
    t.eq(t.lines(), DOC_LINES, "u")
    agree(t, path)
  end,

  ["u undoes C-c C-t and <C-r> redoes it"] = function(t)
    local path = t.open("u_todo.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    undo()
    t.eq(t.lines(), DOC_LINES, "u")
    agree(t, path, "after u")
    redo()
    t.eq(t.lines()[5], "* TODO B", "<C-r>")
    agree(t, path, "after <C-r>")
  end,

  ["u after TAB in a table restores the unaligned table in one step"] = function(t)
    local path = t.open("u_tab.org", TABLE)
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| a   | bb |", "| ccc | d  |" }, "TAB realigns")
    undo()
    t.eq(t.lines(), { "| a | bb |", "| ccc | d |" }, "u")
    agree(t, path)
  end,

  ["u after M-up puts the subtree back; <C-r> moves it again"] = function(t)
    local path = t.open("u_mup.org", t.DOC)
    t.cursor(5)
    t.keys("M-<up>")
    local moved = { "* B", "body b", "* A", "body a", "** A1", "text" }
    t.eq(t.lines(), moved, "M-up")
    undo()
    t.eq(t.lines(), DOC_LINES, "u")
    agree(t, path, "after u")
    redo()
    t.eq(t.lines(), moved, "<C-r>")
    agree(t, path, "after <C-r>")
  end,

  ["C-_ undoes only the last Emacs command; a second C-_ continues"] = function(t)
    local path = t.open("e_todo2.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.answer("n")
    t.keys("C-c C-t")
    t.keys("C-_")
    t.eq(t.lines()[5], "* TODO B", "first C-_")
    t.keys("C-_")
    t.eq(t.lines(), DOC_LINES, "second C-_")
    agree(t, path)
  end,

  ["C-_ after moving the cursor redoes what the last C-_ undid"] = function(t)
    t.open("e_redo.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.keys("C-_")
    t.eq(t.lines()[5], "* B", "C-_")
    -- Emacs: C-f between the two breaks the undo chain. (C-_ left point at
    -- line 5 column 2, so move elsewhere.)
    t.cursor(6, 1)
    t.keys("C-_")
    t.eq(t.lines()[5], "* TODO B", "C-_ again")
  end,

  ["C-_ after TAB folds undoes the change before the fold"] = function(t)
    local path = t.open("e_fold.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.keys("TAB")
    t.keys("C-_")
    t.eq(t.lines(), DOC_LINES)
    agree(t, path)
  end,

  ["C-_ on a freshly opened file leaves the text alone"] = function(t)
    local path = t.open("e_fresh.org", t.DOC)
    pcall(t.keys, "C-_") -- Emacs: "No further undo information"
    t.eq(t.lines(), DOC_LINES)
    agree(t, path)
  end,

  ["C-_ undoes a Neovim edit"] = function(t)
    local path = t.open("e_nvim.org", t.DOC)
    t.cursor(6)
    t.feed("Axy<Esc>")
    t.eq(t.lines()[6], "body bxy", "typed")
    t.keys("C-_")
    t.eq(t.lines(), DOC_LINES, "C-_")
    agree(t, path)
  end,

  ["C-_ after a Neovim edit and C-c C-t undoes only C-c C-t, then the edit"] = function(t)
    local path = t.open("e_mixed.org", t.DOC)
    t.cursor(6)
    t.feed("Axy<Esc>")
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B", "C-c C-t on the body's heading")
    t.keys("C-_")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body bxy" }, "first C-_")
    t.keys("C-_")
    t.eq(t.lines(), DOC_LINES, "second C-_")
    agree(t, path)
  end,

  ["a word typed in a table cell is one u, as in plain text"] = function(t)
    local path = t.open("u_tabletype.org", "| a | b |\n* H\nab\n")
    t.cursor(1, 3)
    type_slowly(t, "i", "xyz")
    t.eq(t.lines()[1], "| axyz | b |", "typed in the cell")
    t.cursor(3, 1)
    type_slowly(t, "a", "xyz")
    t.eq(t.lines()[3], "abxyz", "typed in plain text")
    undo()
    t.eq(t.lines(), { "| axyz | b |", "* H", "ab" }, "one u: the plain word")
    undo()
    t.eq(t.lines(), { "| a | b |", "* H", "ab" }, "second u: the table word")
    agree(t, path)
  end,

  -- Emacs: x y z C-f q q C-_ removes only "qq" (the motion ends amalgamation).
  ["two Insert sessions in a table are two u steps"] = function(t)
    local path = t.open("u_table2.org", "| a | b |\n")
    t.cursor(1, 3)
    type_slowly(t, "i", "xyz")
    t.cursor(1, 9)
    type_slowly(t, "i", "qq")
    t.eq(t.lines(), { "| axyz | qqb |" }, "typed")
    undo()
    t.eq(t.lines(), { "| axyz | b |" }, "one u")
    agree(t, path)
  end,

  ["u after typing in a table keeps the C-c C-t before it"] = function(t)
    local path = t.open("u_todotable.org", "* H\n| a | b |\n")
    t.answer("t")
    t.keys("C-c C-t")
    t.cursor(2, 3)
    type_slowly(t, "i", "xyz")
    t.eq(t.lines(), { "* TODO H", "| axyz | b |" }, "typed")
    undo()
    t.eq(t.lines(), { "* TODO H", "| a | b |" }, "one u")
    agree(t, path)
  end,

  ["C-_ after typing in a table cell removes the whole word"] = function(t)
    local path = t.open("e_tabletype.org", "| a | b |\n")
    t.cursor(1, 3)
    type_slowly(t, "i", "xyz")
    t.keys("C-_")
    t.eq(t.lines(), { "| a | b |" })
    agree(t, path)
  end,

  ["folding adds no undo step: u after C-c C-t and TAB undoes C-c C-t"] = function(t)
    local path = t.open("u_fold.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.keys("TAB")
    t.eq(t.folds(), { "5-6" }, "folded")
    undo()
    t.eq(t.lines(), DOC_LINES, "one u")
    t.eq(vim.fn.undotree().seq_cur, 0, "at the oldest change")
    agree(t, path)
  end,
}
