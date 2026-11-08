-- Footnotes: C-c C-x f inserts one or jumps between reference and definition,
-- C-c C-c jumps, C-c ' edits a definition, C-u C-c C-x f sorts, renumbers
-- and deletes.
local api = vim.api

local ONE = "* H\nsee[fn:1] here\n\n* Footnotes\n\n[fn:1] one\n"
local UNSORTED = "* H\na[fn:2] b[fn:1]\n\n* Footnotes\n\n[fn:1] one\n\n[fn:2] two\n"
local MENU = "Footnotes: [s]ort | [r]enumber fn:N | [S]=r+s | [n]ormalize | [d]elete"

local function cursor() return api.nvim_win_get_cursor(0) end

-- C-u C-c C-x f, answering the menu with key.
local function menu(t, key)
  t.answer(key)
  t.keys("C-c C-x f", 4)
  local q = t.asked()[1]
  t.eq({ q.method, q.params.prompt }, { "read_key", MENU })
end

return {
  ["C-c C-c on a reference jumps to its definition"] = function(t)
    t.open("ref.org", ONE)
    t.cursor(2, 5)
    t.keys("C-c C-c")
    t.eq(cursor(), { 6, 6 })
  end,

  ["C-c C-c and C-c C-x f on a definition jump to the reference"] = function(t)
    t.open("def.org", ONE)
    t.cursor(6, 2)
    t.keys("C-c C-c")
    t.eq(cursor(), { 2, 3 }, "C-c C-c")
    t.cursor(6, 2)
    t.keys("C-c C-x f")
    t.eq(cursor(), { 2, 3 }, "C-c C-x f")
    t.eq(t.lines(), vim.split(ONE, "\n", { plain = true, trimempty = true }), "text unchanged")
  end,

  ["C-c & after jumping to a definition returns to the reference"] = function(t)
    t.open("back.org", ONE)
    t.cursor(2, 5)
    t.keys("C-c C-c")
    t.keys("C-c &")
    t.eq(cursor(), { 2, 5 })
  end,

  ["C-c C-c from a definition lands after multibyte text"] = function(t)
    t.open("mb.org", "* H\nnaïve café[fn:1] x\n\n* Footnotes\n\n[fn:1] one\n")
    t.cursor(6, 1)
    t.keys("C-c C-c")
    t.eq(cursor(), { 2, #"naïve café" })
  end,

  ["C-c C-c on a reference opens the folded Footnotes section"] = function(t)
    t.open("fold.org", ONE .. "* Z\n")
    t.keys("<backtab>")
    t.cursor(1)
    t.keys("TAB")
    t.cursor(2, 5)
    t.keys("C-c C-c")
    t.eq(cursor(), { 6, 6 })
    t.eq(vim.fn.foldclosed(6), -1, "definition visible")
  end,

  -- Org 9.6 puts the new definition right under the Footnotes heading and
  -- leaves point after "[fn:2] ", ready to type the definition.
  ["C-c C-x f at end of line adds fn:2 to the Footnotes section"] = function(t)
    t.open("second.org", ONE)
    t.cursor(2)
    local seen
    vim.keymap.set("i", "<F12>", function() seen = { vim.fn.mode(), cursor() } end, { buffer = true })
    -- Insert-mode <C-c> asks for the rest of the key.
    t.answer("C-x", "f")
    t.feed("A<C-c><F12>")
    t.eq(t.lines(), { "* H", "see[fn:1] here[fn:2]", "", "* Footnotes", "[fn:2] ", "", "[fn:1] one" })
    t.eq(seen, { "i", { 5, 6 } })
  end,

  ["C-c C-c on an undefined reference offers to create the definition"] = function(t)
    t.open("undef.org", "* H\nsee[fn:9] here\n")
    t.cursor(2, 5)
    t.answer(true)
    t.keys("C-c C-c")
    local q = t.asked()[1]
    t.eq({ q.method, q.params.prompt }, { "confirm", "No definition for 9.  Create one? " })
    t.eq(t.lines(), { "* H", "see[fn:9] here", "", "* Footnotes", "", "[fn:9] " })
    t.eq(cursor(), { 6, 6 })
  end,

  -- Emacs proposes "2"; TAB on the emptied minibuffer offers the labels in use.
  ["confirmed labels complete from the existing ones"] = function(t)
    t.set("org-footnote-auto-label", "'confirm")
    t.open("cands.org", "* H\na[fn:1] b[fn:x] c\n\n* Footnotes\n\n[fn:1] one\n\n[fn:x] ex\n")
    t.cursor(2)
    local seen
    require("emacs.rpc").handlers.completing_read = function(p)
      seen = { p.initial, require("emacs.ui").complete("") }
      table.sort(seen[2])
      return "x"
    end
    t.answer("C-x", "f")
    t.feed("A<C-c>")
    t.eq(seen, { "2", { "1", "x" } })
    t.eq(t.lines()[2], "a[fn:1] b[fn:x] c[fn:x]", "existing label: only a reference")
  end,

  ["C-u C-c C-x f s sorts definitions by reference order"] = function(t)
    t.open("sort.org", UNSORTED)
    t.cursor(2)
    menu(t, "s")
    t.eq(t.lines(), { "* H", "a[fn:2] b[fn:1]", "", "* Footnotes", "", "[fn:2] two", "", "[fn:1] one" })
    t.eq(t.emacs_lines(api.nvim_buf_get_name(0)), t.lines(), "Emacs agrees")
  end,

  ["C-u C-c C-x f S renumbers, sorts and moves the section to the end"] = function(t)
    t.open("move.org", UNSORTED .. "* Z\n")
    t.cursor(1)
    menu(t, "S")
    t.eq(t.lines(), { "* H", "a[fn:1] b[fn:2]", "", "* Z", "", "* Footnotes", "", "[fn:1] two", "",
      "[fn:2] one" })
  end,

  ["C-u C-c C-x f d deletes the footnote at point"] = function(t)
    t.open("del.org", "* H\na[fn:1] b\n\n* Footnotes\n\n[fn:1] one\n")
    t.cursor(2, 2)
    menu(t, "d")
    t.eq(t.lines(), { "* H", "a b", "", "* Footnotes" })
    t.eq(cursor(), { 2, 1 })
  end,

  -- In Emacs the edit buffer *Edit footnote [1]* has buffer-file-name set to
  -- the org file; the org buffer keeps its text.
  [":w in a footnote edit buffer saves the org file with the edit"] = function(t)
    local path = t.open("edit-save.org", ONE)
    t.cursor(2, 5)
    t.keys("C-c '")
    api.nvim_buf_set_lines(0, -1, -1, false, { "more" })
    vim.cmd("silent write")
    t.eq(t.read_file(path), "* H\nsee[fn:1] here\n\n* Footnotes\n\n[fn:1] one\nmore\n")
    t.keys("C-c '")
  end,

  ["C-c ' on a reference edits its definition in a split"] = function(t)
    t.open("edit.org", ONE)
    local org = api.nvim_get_current_buf()
    t.cursor(2, 5)
    t.keys("C-c '")
    t.eq(#api.nvim_buf_get_lines(org, 0, -1, false), 6, "org buffer keeps its text")
    t.eq(api.nvim_get_current_buf() ~= org, true, "edit buffer is its own buffer")
    t.eq(t.lines(), { "[fn:1] one" })
    t.eq(cursor(), { 1, 7 })
    api.nvim_buf_set_lines(0, -1, -1, false, { "more" })
    t.cursor(1, 0)
    t.keys("C-c '")
    t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
    t.eq(t.lines(), { "* H", "see[fn:1] here", "", "* Footnotes", "", "[fn:1] one", "more" })
    t.eq(cursor(), { 2, 5 }, "point back on the reference")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "edit window closed")
  end,
}
