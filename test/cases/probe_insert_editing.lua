-- Insert-mode editing that must match Emacs: typing in table fields (blank
-- after S-Tab and RET, widening, | for a new column, BS and Del), M-RET
-- and Tab on items, tags typed on a heading, and auto-fill. Expected text
-- is what the same keys do in emacs -Q --batch -l test/init.el, auto-fill
-- with fill-column = textwidth.
local api = vim.api

-- <F12> in insert mode records the cursor at that moment.
local seen = {}

-- Feed keys as typed; "x" ends insert mode when the keys run out.
local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function open(t, name, text)
  t.open(name, text)
  vim.keymap.set("i", "<F12>", function() seen[#seen + 1] = api.nvim_win_get_cursor(0) end, { buffer = true })
  seen = {}
end

-- Neovim's own org ftplugin (comments, formatoptions) with a textwidth.
local function ftplugin(textwidth)
  vim.cmd("runtime ftplugin/org.vim")
  vim.bo.textwidth = textwidth
end

local TABLE = "| a | b |\n| c | d |\n"

return {
  ["typing right after S-Tab replaces the previous field"] = function(t)
    open(t, "stab.org", TABLE)
    t.cursor(2, 2)
    feed("i<S-Tab>Z<Esc>")
    t.eq(t.lines(), { "| a | Z |", "| c | d |" })
  end,

  ["typing right after RET in a table replaces the field below"] = function(t)
    open(t, "ret.org", TABLE)
    t.cursor(1, 2)
    feed("i<CR>Z<F12><Esc>")
    t.eq(t.lines(), { "| a | b |", "| Z | d |" })
    t.eq(seen[1], { 2, 3 })
  end,

  ["RET on the last row adds a row and stays in the column"] = function(t)
    open(t, "retlast.org", TABLE)
    t.cursor(2, 6)
    feed("i<CR>Z<F12><Esc>")
    t.eq(t.lines(), { "| a | b |", "| c | d |", "|   | Z |" })
    t.eq(seen[1], { 3, 7 })
  end,

  -- Typing eats the field's padding first, then Tab widens the column.
  ["typing past a field's width widens its column on Tab"] = function(t)
    open(t, "widen.org", "| a | bb   |\n| c | d    |\n")
    t.cursor(1, 8)
    feed("ixyzw<F12><Tab><F12><Esc>")
    t.eq(t.lines(), { "| a | bbxyzw |", "| c | d      |" })
    t.eq(seen, { { 1, 12 }, { 2, 2 } })
  end,

  ["| typed inside a field splits it into two columns on Tab"] = function(t)
    open(t, "barmid.org", "| a b |\n")
    t.cursor(1, 4)
    feed("i|<Tab><F12><Esc>")
    t.eq(t.lines(), { "| a | b |", "|   |   |" })
    t.eq(seen[1], { 2, 2 })
  end,

  ["| typed at the end of a row adds a column on Tab"] = function(t)
    open(t, "barend.org", "| a |\n| b |\n")
    feed("Ax|<Tab><F12><Esc>")
    t.eq(t.lines(), { "| a | x |", "| b |   |" })
    t.eq(seen[1], { 2, 2 })
  end,

  -- org-delete-backward-char: the space before the field goes, the field
  -- is padded at its end so the column keeps its width.
  ["BS at the start of a field keeps the column's width"] = function(t)
    open(t, "bs.org", "| a | bbb |\n| c | d |\n")
    t.cursor(1, 6)
    feed("i<BS><F12><Esc>")
    t.eq(t.lines(), { "| a |bbb  |", "| c | d |" })
    t.eq(seen[1], { 1, 5 })
  end,

  ["Del before a field's separator deletes the padding"] = function(t)
    open(t, "del.org", "| a | bbb |\n| c | d |\n")
    t.cursor(1, 9)
    feed("i<Del><F12><Esc>")
    t.eq(t.lines(), { "| a | bbb|", "| c | d |" })
    t.eq(seen[1], { 1, 9 })
  end,

  ["M-RET inside an item's text splits the item"] = function(t)
    open(t, "mretsplit.org", "- one two\n")
    t.cursor(1, 5)
    feed("i<M-CR><F12>X<Esc>")
    t.eq(t.lines(), { "- one", "- Xtwo" })
    t.eq(seen[1], { 2, 2 })
  end,

  -- org-cycle-item-indentation: a second Tab with nowhere deeper to go
  -- puts the item back where it started.
  ["Tab twice on an empty item cycles it back to its level"] = function(t)
    open(t, "tabtwice.org", "- one\n- \n")
    t.cursor(2)
    feed("A<Tab><Tab><F12>x<Esc>")
    t.eq(t.lines(), { "- one", "- x" })
    t.eq(seen[1], { 2, 2 })
  end,

  ["M-S-RET after a typed checkbox item adds a checkbox item"] = function(t)
    open(t, "checkbox.org", "* L\n")
    feed("o- [ ] task<M-S-CR>next<Esc>")
    t.eq(t.lines(), { "* L", "- [ ] task", "- [ ] next" })
  end,

  -- org-self-insert-command realigns only tags after point.
  ["tags typed at the end of a heading stay as typed"] = function(t)
    open(t, "typedtags.org", "* Head\n")
    feed("A :tag:<Esc>")
    t.eq(t.lines(), { "* Head :tag:" })
  end,

  -- Emacs fills when a space or RET follows the word, not as it is typed.
  ["auto-fill leaves a long last word until a space follows it"] = function(t)
    open(t, "fillspace.org", "* H\n\n")
    ftplugin(12)
    t.cursor(2)
    feed("Aaaa bbb ccc ddd<Esc>")
    t.eq(t.lines(), { "* H", "aaa bbb ccc ddd" })
  end,

  -- org-fill-paragraph-with-timestamp-nobreak-p
  ["auto-fill never breaks inside a timestamp"] = function(t)
    open(t, "fillts.org", "* H\n\n")
    ftplugin(20)
    t.cursor(2)
    feed("Asee the <2026-11-08 Sun> now <Esc>")
    t.eq(t.lines(), { "* H", "see the", "<2026-11-08 Sun> now " })
  end,

  ["auto-fill continues a comment with its # prefix"] = function(t)
    open(t, "fillcomment.org", "* H\n\n")
    ftplugin(12)
    t.cursor(2)
    feed("A# aaa bbb ccc ddd eee <Esc>")
    t.eq(t.lines(), { "* H", "# aaa bbb", "# ccc ddd", "# eee " })
  end,

  ["auto-fill leaves fixed-width lines alone"] = function(t)
    open(t, "fillfixed.org", "* H\n\n")
    ftplugin(10)
    t.cursor(2)
    feed("A: aaa bbb ccc ddd <Esc>")
    t.eq(t.lines(), { "* H", ": aaa bbb ccc ddd " })
  end,
}
