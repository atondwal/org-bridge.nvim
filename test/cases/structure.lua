-- Structure editing: subtree moves, promote/demote, list items, headings
-- after a subtree, checkboxes and statistics cookies.

local function line() return vim.api.nvim_win_get_cursor(0)[1] end

return {
  ["M-down moves a subtree with its body and children"] = function(t)
    t.open("mdown.org", t.DOC)
    t.feed("<M-Down>")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a", "** A1", "text" })
    t.eq(line(), 3, "cursor follows the subtree")
    t.feed("<M-Up>")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body b" }, "M-up undoes it")
    t.eq(line(), 1)
    t.feed("2<M-Down>")
    -- Emacs refuses the whole move when the count overshoots.
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body b" }, "a count past the limit")
  end,

  ["a folded subtree stays folded when moved"] = function(t)
    t.open("mfold.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" }, "folded")
    t.keys("M-<down>")
    t.eq(t.lines()[3], "* A")
    t.eq(t.folds(), { "3-6" }, "fold moved with the subtree")
  end,

  ["M-down past the last sibling errors and changes nothing"] = function(t)
    t.open("mlast.org", t.DOC)
    t.cursor(5)
    t.feed("<M-Down>")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* B", "body b" })
    local msgs = vim.fn.execute("messages")
    assert(msgs:find("Cannot move past superior level", 1, true), "error shown: " .. msgs)
  end,

  ["M-left/M-right change one heading, M-S-left/right the subtree"] = function(t)
    t.open("promote.org", t.DOC)
    t.cursor(5)
    t.feed("<M-Right>")
    t.eq(t.lines()[5], "** B", "M-right demotes B")
    t.cursor(1)
    t.feed("<M-S-Right>")
    -- B is now A's child, so it moves with A's subtree.
    t.eq(t.lines(), { "** A", "body a", "*** A1", "text", "*** B", "body b" }, "M-S-right demotes A's subtree")
    t.cursor(3)
    t.feed("<M-Left>")
    t.eq(t.lines()[3], "** A1", "M-left promotes A1 alone")
    t.open("listdemote.org", "* L\n- one\n- two\n  - sub\n")
    t.cursor(3)
    t.feed("<M-S-Right>")
    t.eq(t.lines(), { "* L", "- one", "  - two", "    - sub" }, "list item with its sub-item")
  end,

  ["M-RET in a list adds an item, in normal and insert mode"] = function(t)
    t.open("item.org", "* L\n- one\n- two\n")
    -- Point before the item's text: Emacs inserts the new item above.
    t.cursor(3, 0)
    t.feed("<M-CR>")
    t.eq(t.lines(), { "* L", "- one", "- ", "- two" }, "normal mode")
    -- Emacs leaves point after "- "; normal mode clamps it onto the space.
    t.eq(vim.api.nvim_win_get_cursor(0), { 3, 1 })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "* L", "- one", "- two" })
    t.cursor(3)
    t.feed("A<M-CR>three<Esc>")
    t.eq(t.lines(), { "* L", "- one", "- two", "- three" }, "insert mode at end of line")
    -- Text typed in insert mode must reach Emacs before the command. o is
    -- C-e RET, which stays in the item: "- four" starts a sub-list.
    t.feed("o- four<M-CR>five<Esc>")
    t.eq(t.lines(), { "* L", "- one", "- two", "- three", "  - four", "  - five" }, "typed text synced")
  end,

  ["C-RET inserts a heading after the subtree"] = function(t)
    t.open("cret.org", t.DOC)
    t.cursor(2, 2)
    t.feed("<C-CR>")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* ", "* B", "body b" }, "normal mode")
    t.eq(line(), 5)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(t.DOC:sub(1, -2), "\n"))
    t.cursor(2)
    t.feed("A<C-CR>New<Esc>")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* New", "* B", "body b" }, "insert mode")
  end,

  ["C-c C-c toggles checkboxes and updates [/] and [%] cookies"] = function(t)
    t.open("check.org", "* Tasks [/] [%]\n- [ ] a\n- [ ] b\n")
    t.cursor(2)
    -- The normal-mode <C-c> mapping asks for the rest of the sequence.
    t.answer("C-c")
    t.feed("<C-c>")
    t.eq(t.lines(), { "* Tasks [1/2] [50%]", "- [X] a", "- [ ] b" })
    t.cursor(3)
    t.keys("C-c C-c")
    t.eq(t.lines()[1], "* Tasks [2/2] [100%]")
    t.cursor(2)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "* Tasks [1/2] [50%]", "- [ ] a", "- [X] b" }, "unchecking")
    -- A partly checked parent item counts as not done.
    t.open("nested.org", "* T [/]\n- [ ] parent [/]\n  - [ ] c1\n  - [ ] c2\n")
    t.cursor(3)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "* T [0/1]", "- [-] parent [1/2]", "  - [X] c1", "  - [ ] c2" }, "nested")
  end,

  ["insert mode: M-Down and C-c C-c work without leaving insert"] = function(t)
    t.open("imode.org", "* T [/]\n- [ ] a\n* U\n")
    t.cursor(2)
    t.answer("C-c")
    t.feed("A<C-c><Esc>")
    t.eq(t.lines()[1], "* T [1/1]", "checkbox from insert mode")
    t.cursor(1)
    t.feed("i<M-Down><Esc>")
    t.eq(t.lines(), { "* U", "* T [1/1]", "- [X] a" }, "subtree moved from insert mode")
  end,


  ["C-c @ marks the subtree as a Visual selection for the next command"] = function(t)
    t.open("mark.org", "* A\nbody\n** A1\n* B\n")
    t.keys("C-c @")
    vim.api.nvim_feedkeys("", "x", false) -- run the queued Visual-mode keys
    t.eq(vim.fn.mode(), "V")
    t.eq({ vim.fn.line("v"), vim.fn.line(".") }, { 1, 3 })
  end,

  ["subtree copy (C-c C-x M-w) lands in the unnamed register"] = function(t)
    t.open("copy.org", "* A\nbody\n* B\n")
    t.keys("C-c C-x M-w")
    t.eq(vim.fn.getreg('"'), "* A\nbody\n")
    t.eq(vim.fn.getregtype('"'), "V")
  end,

  ["M-right on a C-c @ selection demotes the whole subtree"] = function(t)
    t.open("demote.org", "* A\nbody\n** A1\n* B\n")
    t.keys("C-c @")
    t.feed("<M-Right>")
    t.eq(t.lines(), { "** A", "body", "*** A1", "* B" })
  end,

  -- Vim's own way to move a subtree: dd on its closed fold, p elsewhere.
  ["dd on a folded subtree and p elsewhere move it in Emacs too"] = function(t)
    t.open("ddfold.org", "* A\na body\n** A1\na1 body\n* B\nb body\n* C\nc body\n")
    t.cursor(1)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    vim.cmd("normal! dd")
    vim.cmd("normal! jp")
    require("emacs.mirror").sync()
    local moved = { "* B", "b body", "* A", "a body", "** A1", "a1 body", "* C", "c body" }
    t.eq(t.lines(), moved)
    t.eq(t.emacs_lines("ddfold.org"), moved)
    vim.cmd("normal! u")
    vim.cmd("normal! u")
    require("emacs.mirror").sync()
    t.eq(t.emacs_lines("ddfold.org"), { "* A", "a body", "** A1", "a1 body", "* B", "b body", "* C", "c body" })
  end,
}
