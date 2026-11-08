-- Insert-mode keys: Tab/S-Tab in tables, M-RET, C-c sequences, and text
-- typed just before a command. Insert-mode point and Emacs point agree:
-- both sit between characters.
local api = vim.api

-- <F12> in insert mode records the mode and cursor at that moment. <F11>
-- is a pause in typing: fed keys never fire TextChangedI (typeahead is
-- never empty), so it fires it and waits out the debounced sync.
local seen = {}
local function install_probes(t)
  vim.keymap.set("i", "<F12>", function()
    seen[#seen + 1] = { mode = vim.fn.mode(), cursor = api.nvim_win_get_cursor(0) }
  end, { buffer = true })
  vim.keymap.set("i", "<F11>", function()
    api.nvim_exec_autocmds("TextChangedI", { buffer = 0 })
    vim.wait(400)
    seen[#seen + 1] = { emacs = t.emacs_text(vim.fn.expand("%:t")) }
  end, { buffer = true })
end

-- Feed keys as typed. "x" ends insert mode when the keys run out; "x!"
-- would wait for more keys, reading stdin, and kill headless Neovim.
local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function open(t, name, text)
  t.open(name, text)
  install_probes(t)
  seen = {}
end

-- The n-th <F12> reading: insert mode at { line, byte column }.
local function at(t, n, want, what)
  t.eq(seen[n], { mode = "i", cursor = want }, what)
end

return {
  ["Tab and S-Tab move between cells and stay in insert mode"] = function(t)
    open(t, "itab.org", "| a | b |\n| c | d |\n")
    t.cursor(1, 3)
    feed("i<Tab><F12><Tab><F12><S-Tab><F12><S-Tab><S-Tab><F12><Esc>")
    at(t, 1, { 1, 6 }, "Tab: before b")
    at(t, 2, { 2, 2 }, "Tab wraps to the next row's first cell")
    at(t, 3, { 1, 6 }, "S-Tab goes back to b")
    -- Emacs: user-error "Cannot move to previous table field", point kept.
    at(t, 4, { 1, 2 }, "S-Tab stops in the first cell, still inserting")
    t.eq(t.lines(), { "| a | b |", "| c | d |" })
  end,

  ["Tab in the last cell adds a row, before an hline too"] = function(t)
    open(t, "irow.org", "| a | b |\n|---+---|\n")
    t.cursor(1, 7)
    feed("i<Tab><F12><Esc>")
    t.eq(t.lines(), { "| a | b |", "|   |   |", "|---+---|" })
    at(t, 1, { 2, 2 })
  end,

  ["Tab after a multibyte cell lands on the next cell's byte column"] = function(t)
    open(t, "iutf.org", "| é | b |\n")
    t.cursor(1, 4)
    feed("i<Tab><F12><Esc>")
    -- "| é | " is 7 bytes.
    at(t, 1, { 1, 7 })
  end,

  ["typing right after Tab replaces the cell, as org-table-auto-blank-field"] = function(t)
    open(t, "iblank.org", "| a | bbb |\n| c | d |\n")
    t.cursor(1, 3)
    -- Emacs: TAB X Y TAB gives "| a | XY |" / "| c | d  |", point (1 2).
    feed("i<Tab>XY<Tab><F12><Esc>")
    t.eq(t.lines(), { "| a | XY |", "| c | d  |" })
    at(t, 1, { 2, 2 })
  end,

  ["M-RET at the end of a heading or item keeps inserting"] = function(t)
    open(t, "imret.org", "* Head\n- one\n")
    feed("A<M-CR><F12>New<Esc>")
    t.eq(t.lines(), { "* Head", "* New", "- one" })
    at(t, 1, { 2, 2 }, "after the stars, past the last column")
    t.cursor(3)
    feed("A<M-CR>two<M-CR><F12><Esc>")
    t.eq(t.lines(), { "* Head", "* New", "- one", "- two", "- " })
    at(t, 2, { 5, 2 })
  end,

  ["C-c sequences from insert mode keep point and insert mode"] = function(t)
    open(t, "icc.org", "* Head\n- [ ] a\n* H \n")
    t.answer("C-t", "t")
    feed("A<C-c><F12>X<Esc>")
    at(t, 1, { 1, 11 }, "C-c C-t: end of the heading")
    t.eq(t.lines()[1], "* TODO HeadX")
    t.cursor(2)
    t.answer("C-c")
    feed("A<C-c><F12><Esc>")
    t.eq(t.lines()[2], "- [X] a")
    at(t, 2, { 2, 7 }, "C-c C-c")
    t.cursor(3)
    t.answer(".", "2026-11-07")
    feed("A<C-c> X<Esc>")
    t.eq(t.lines()[3], "* H <2026-11-07 Sat> X", "typing continues after the timestamp")
  end,

  ["text typed just before a command reaches Emacs once"] = function(t)
    open(t, "ityped.org", "* A\n")
    -- No pause between typing and Tab: the debounced sync has not run.
    feed("o| x | y<Tab>z<Tab><Esc>")
    t.eq(t.lines(), { "* A", "| x | y |", "| z |   |" })
    t.eq(t.emacs_text("ityped.org"), "* A\n| x | y |\n| z |   |\n", "Emacs agrees")
  end,

  ["a sync mid-insert does not duplicate text typed after it"] = function(t)
    open(t, "imid.org", "* A\n- one\n")
    t.cursor(2)
    feed("A two<F11> three<M-CR>four<F11><Esc>")
    t.eq(seen[1], { emacs = "* A\n- one two\n" }, "the pause synced")
    t.eq(t.lines(), { "* A", "- one two three", "- four" })
    t.eq(seen[2], { emacs = "* A\n- one two three\n- four\n" }, "Emacs agrees")
  end,

  ["Insert-mode RET keeps its place among keys typed after it"] = function(t)
    t.open("cr.org", "* A\n")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("o* Inbox<CR>** b<CR>notes<Esc>", true, false, true), "xt", false)
    t.eq(t.lines(), { "* A", "* Inbox", "** b", "notes" })
  end,
}
