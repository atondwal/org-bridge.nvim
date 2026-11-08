-- Plain lists: checkbox items, bullet cycling, renumbering, statistics
-- cookies, list-to-heading. Expected text comes from emacs -Q --batch
-- -l test/init.el, with transient-mark-mode on for the region cases.
local api = vim.api
local mirror = require("emacs.mirror")

-- Select with `motion`, then run `keys` with the selection as the region,
-- from an x-mode mapping the way a real Visual-mode key would.
local function visual(motion, keys)
  vim.keymap.set("x", "<F9>", function() mirror.exec({ keys = keys, visual = true }) end, { buffer = 0 })
  api.nvim_feedkeys(api.nvim_replace_termcodes(motion .. "<F9>", true, false, true), "x", false)
end

return {
  ["M-S-RET adds a checkbox item after a checkbox item and a plain one"] = function(t)
    t.open("mscheck.org", "* L\n- [ ] one\n- [ ] two\n")
    t.cursor(2, 8) -- last character: acts at end of line
    t.feed("<M-S-CR>")
    t.eq(t.lines(), { "* L", "- [ ] one", "- [ ] ", "- [ ] two" }, "checkbox list")
    t.feed("<Esc>")
    t.open("msplain.org", "* L\n- one\n- two\n")
    t.cursor(2, 4)
    t.feed("<M-S-CR>")
    t.eq(t.lines(), { "* L", "- one", "- [ ] ", "- two" }, "plain list")
  end,

  ["C-c - cycles the bullet of the whole list"] = function(t)
    t.open("cycle.org", "* L\n- one\n- two\n")
    t.cursor(2)
    local want = { { "+ one", "+ two" }, { "1. one", "2. two" }, { "1) one", "2) two" }, { "- one", "- two" } }
    for i, items in ipairs(want) do
      t.keys("C-c -")
      t.eq(t.lines(), { "* L", items[1], items[2] }, "step " .. i)
    end
    t.open("cyclesub.org", "* L\n- one\n  - sub\n- two\n")
    t.cursor(2)
    t.keys("C-c -")
    t.eq(t.lines(), { "* L", "+ one", "  - sub", "+ two" }, "sub-list keeps its bullet")
  end,

  ["M-RET in an ordered list renumbers the following items"] = function(t)
    t.open("ordret.org", "* L\n1. one\n2. two\n3. three\n")
    t.cursor(2, 5)
    t.feed("<M-CR>")
    t.eq(t.lines(), { "* L", "1. one", "2. ", "3. two", "4. three" })
    t.feed("<Esc>")
    t.open("ordindent.org", "* L\n1. one\n2. two\n3. three\n")
    t.cursor(3)
    t.keys("M-<right>")
    t.eq(t.lines(), { "* L", "1. one", "   1. two", "2. three" }, "M-right renumbers both levels")
    t.cursor(2)
    t.keys("M-<right>")
    t.eq(t.lines(), { "* L", "1. one", "   1. two", "2. three" }, "first item refuses M-right")
  end,

  ["M-down and M-up renumber an ordered list"] = function(t)
    t.open("ordmove.org", "* L\n1. one\n2. two\n3. three\n")
    t.cursor(2)
    t.keys("M-<down>")
    t.eq(t.lines(), { "* L", "1. two", "2. one", "3. three" }, "M-down")
    t.eq(api.nvim_win_get_cursor(0)[1], 3, "cursor follows the item")
    t.cursor(4)
    t.keys("M-<up>")
    t.eq(t.lines(), { "* L", "1. two", "2. three", "3. one" }, "M-up")
    t.open("ordline.org", "* L\n1. one\n2. two\n")
    t.cursor(2)
    t.keys("M-S-<down>")
    t.eq(t.lines(), { "* L", "2. two", "1. one" }, "M-S-down drags the line without renumbering")
  end,

  ["C-c C-c repairs numbering; C-u adds a checkbox, C-u C-u makes it [-]"] = function(t)
    t.open("ordfix.org", "* L\n1. one\n5. two\n")
    t.cursor(3)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "* L", "1. one", "2. two" })
    t.keys("C-c C-c", 4)
    t.eq(t.lines(), { "* L", "1. one", "2. [ ] two" }, "C-u adds a checkbox")
    t.open("halfbox.org", "* L\n- [ ] one\n- [ ] two\n")
    t.cursor(3)
    t.keys("C-c C-c", 16)
    t.eq(t.lines(), { "* L", "- [ ] one", "- [-] two" }, "C-u C-u marks it [-]")
  end,

  ["C-c C-c updates the item's [%] cookie, its checkbox and the heading's [/]"] = function(t)
    t.open("nestpct.org", "* T [/]\n- [ ] p [%]\n  - [ ] c1\n  - [X] c2\n- [ ] q\n")
    t.cursor(3)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "* T [1/2]", "- [X] p [100%]", "  - [X] c1", "  - [X] c2", "- [ ] q" })
  end,

  ["C-c C-x C-b toggles checkboxes, also on a Visual selection; C-c # recounts"] = function(t)
    t.open("cxcb.org", "* T [%]\n- [ ] a\n- [ ] b\n- [ ] c\n")
    t.cursor(3)
    t.keys("C-c C-x C-b")
    t.eq(t.lines(), { "* T [33%]", "- [ ] a", "- [X] b", "- [ ] c" })
    t.open("hash.org", "* T [/]\n- [X] a\n- [ ] b\n")
    t.keys("C-c #")
    t.eq(t.lines()[1], "* T [1/2]", "C-c # recounts a stale cookie")
    -- Expected: Emacs with the region over exactly the selected lines' text.
    t.open("boxv.org", "* T [/]\n- [ ] a\n- [ ] b\n- [ ] c\n")
    t.cursor(2)
    visual("Vj", "C-c C-x C-b")
    t.eq(t.lines(), { "* T [2/3]", "- [X] a", "- [X] b", "- [ ] c" }, "C-c C-x C-b on a selection")
    t.open("boxv2.org", "* T [/]\n- [ ] a\n- [X] b\n- [ ] c\n")
    t.cursor(2)
    visual("Vj", "C-c C-c")
    t.eq(t.lines(), { "* T [0/3]", "- [ ] a", "- [ ] b", "- [ ] c" }, "C-c C-c follows the first item")
  end,

  ["S-right and S-left cycle the bullet"] = function(t)
    t.open("sarrow.org", "* L\n- one\n- two\n")
    t.cursor(2)
    t.feed("<S-Right>")
    t.eq(t.lines(), { "* L", "+ one", "+ two" }, "S-right")
    t.feed("<S-Right>")
    t.eq(t.lines(), { "* L", "1. one", "2. two" }, "S-right twice")
    t.open("sleft.org", "* L\n- one\n- two\n")
    t.cursor(2)
    t.feed("<S-Left>")
    t.eq(t.lines(), { "* L", "1) one", "2) two" }, "S-left")
    t.feed("<S-Down>")
    t.eq(api.nvim_win_get_cursor(0)[1], 3, "S-down goes to the next item")
    t.eq(t.lines(), { "* L", "1) one", "2) two" }, "S-down changes nothing")
  end,

  ["C-c * turns the item at point into a heading"] = function(t)
    t.open("star.org", "* L\n- one\n- two\n")
    t.cursor(3)
    t.keys("C-c *")
    t.eq(t.lines(), { "* L", "- one", "** two" })
    t.open("subtree.org", "* L\n- one\n- two\n")
    t.cursor(2)
    t.keys("C-c C-*")
    t.eq(t.lines(), { "* L", "** one", "** two" }, "C-c C-* converts the whole list")
  end,

  ["C-c * on a Visual selection turns every item into a heading"] = function(t)
    -- Expected: Emacs with the region over exactly the selected lines' text.
    t.open("starv.org", "* L\n- one\n- two\n- three\n")
    t.cursor(2)
    visual("Vj", "C-c *")
    t.eq(t.lines(), { "* L", "** one", "** two", "- three" })
  end,

  ["C-c - on a Visual selection turns plain lines into items"] = function(t)
    t.open("dashv.org", "* L\nfoo\nbar\n")
    t.cursor(2)
    visual("Vj", "C-c -")
    t.eq(t.lines(), { "* L", "- foo", "- bar" })
  end,

  ["C-c ^ a sorts the list alphabetically"] = function(t)
    t.open("sort.org", "* L\n- c\n- a\n- b\n")
    t.cursor(2)
    t.answer("a")
    t.keys("C-c ^")
    t.eq(t.lines(), { "* L", "- a", "- b", "- c" })
  end,
}
