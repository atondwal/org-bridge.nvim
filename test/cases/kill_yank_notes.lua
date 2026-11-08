-- Subtree cut/copy/paste and the kill ring vs Neovim's registers, org-yank
-- folding, C-c C-z notes (*Org Note*), C-c C-x d drawers, C-c C-, templates.
-- Expected text comes from emacs -Q --batch -l test/init.el.
local api = vim.api

local TREE = "* A\nbody\n** A1\ntext\n* B\nbody b\n"
local NOTE_LINE = "^%- Note taken on %[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%] \\\\$"

local function cursor() return api.nvim_win_get_cursor(0) end

return {
  ["C-c C-x C-w cuts the subtree into the unnamed register; p pastes it"] = function(t)
    t.open("cut.org", TREE)
    t.cursor(2) -- in the body: still the whole subtree
    t.keys("C-c C-x C-w")
    t.eq(t.lines(), { "* B", "body b" })
    t.eq({ vim.fn.getreg('"'), vim.fn.getregtype('"') }, { "* A\nbody\n** A1\ntext\n", "V" }, "register")
    t.cursor(2)
    t.feed("p")
    t.eq(t.lines(), { "* B", "body b", "* A", "body", "** A1", "text" }, "p")
  end,

  ["a count cuts that many sibling subtrees"] = function(t)
    t.open("cut2.org", "* A\nbody\n* B\n* C\n")
    t.keys("C-c C-x C-w", 2)
    t.eq(t.lines(), { "* C" })
    t.eq(vim.fn.getreg('"'), "* A\nbody\n* B\n")
  end,

  ["C-c C-x C-y after a copy pastes at the level of the heading it lands next to"] = function(t)
    t.open("paste.org", "* A\nbody\n* P\n** Q\nq\n")
    t.keys("C-c C-x M-w")
    t.cursor(4)
    t.keys("C-c C-x C-y")
    t.eq(t.lines(), { "* A", "body", "* P", "** A", "body", "** Q", "q" }, "on a heading: before it")
    t.eq(cursor(), { 4, 0 })
    t.open("pasteend.org", "* A\nbody\n* P\n** Q\nq\n")
    t.keys("C-c C-x M-w")
    t.cursor(5, 0)
    t.keys("C-c C-x C-y")
    t.eq(t.lines(), { "* A", "body", "* P", "** Q", "q", "** A", "body" }, "after q's body")
  end,

  ["a count to C-c C-x C-y sets the pasted level"] = function(t)
    t.open("paste3.org", "* A\nbody\n* P\n")
    t.keys("C-c C-x M-w")
    t.cursor(3, 2)
    t.feed("o<Esc>")
    t.keys("C-c C-x C-y", 3)
    t.eq(t.lines(), { "* A", "body", "* P", "", "*** A", "body" })
  end,

  -- Emacs pastes what its kill ring holds; in Emacs, copying those lines
  -- with M-w and pasting gives the same result as below.
  ["C-c C-x C-y pastes a subtree yanked in Neovim with yy"] = function(t)
    t.open("nvyank.org", "* N\nnv only\n* P\n** Q\nq\n")
    t.cursor(1)
    t.feed("2yy")
    t.cursor(5)
    t.keys("C-c C-x C-y")
    t.eq(t.lines(), { "* N", "nv only", "* P", "** Q", "q", "** N", "nv only" })
  end,

  -- From an empty line at eob, C-c C-x C-y pastes after it and C-y (org-yank)
  -- before it.
  ["a cut folded subtree comes back folded, by C-c C-x C-y and by C-y"] = function(t)
    local want = {
      ["C-c C-x C-y"] = { { "* B", "", "* A", "body", "** A1" }, { "3-5" } },
      ["C-y"] = { { "* B", "* A", "body", "** A1", "" }, { "2-4" } },
    }
    for _, key in ipairs({ "C-c C-x C-y", "C-y" }) do
      t.open("yfold" .. #key .. ".org", "* A\nbody\n** A1\n* B\n")
      t.cursor(1)
      t.keys("TAB")
      t.eq(t.folds(), { "1-3" }, key .. ": folded before the cut")
      t.keys("C-c C-x C-w")
      t.cursor(1, 2)
      t.feed("o<Esc>")
      t.keys(key)
      t.eq(t.lines(), want[key][1], key)
      t.eq(t.folds(), want[key][2], key .. ": pasted subtree folded")
    end
  end,

  ["C-c C-z opens *Org Note*; C-c C-c stores the note under the heading"] = function(t)
    local path = t.open("note.org", "* A\nbody\n")
    local org = api.nvim_get_current_buf()
    t.keys("C-c C-z")
    assert(api.nvim_buf_get_name(0):find("Org Note", 1, true), "note buffer: " .. api.nvim_buf_get_name(0))
    t.eq(t.lines(), { "# Insert note for this entry.", "# Finish with C-c C-c, or cancel with C-c C-k.", "" })
    t.eq(vim.bo.modifiable, true, "editable")
    api.nvim_buf_set_lines(0, 2, 3, false, { "my note" })
    t.keys("C-c C-c")
    t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
    local lines = t.lines()
    assert(lines[2]:find(NOTE_LINE), "note heading: " .. vim.inspect(lines))
    t.eq({ lines[1], lines[3], lines[4], #lines }, { "* A", "  my note", "body", 4 })
    t.eq(t.emacs_lines(path), lines, "Emacs agrees")
  end,

  ["C-c C-k in *Org Note* drops the note"] = function(t)
    t.open("notek.org", "* A\nbody\n")
    local org = api.nvim_get_current_buf()
    t.keys("C-c C-z")
    api.nvim_buf_set_lines(0, 2, 3, false, { "never mind" })
    t.keys("C-c C-k")
    t.eq(api.nvim_get_current_buf(), org)
    t.eq(t.lines(), { "* A", "body" })
  end,

  ["C-c C-x d asks for a drawer name and inserts it, empty or around the selection"] = function(t)
    t.open("drawer.org", "* H\ntext\n")
    t.cursor(2)
    t.answer("STUFF")
    t.keys("C-c C-x d")
    t.eq(t.asked()[1].params.prompt, "Drawer: ")
    t.eq(t.lines(), { "* H", ":STUFF:", "", ":END:", "text" })
    t.eq(cursor(), { 3, 0 }, "cursor inside")
    t.open("drawerv.org", "* H\nl1\nl2\n")
    t.cursor(2)
    t.answer("C-x", "d", "STUFF")
    t.feed("Vj<C-c>")
    t.eq(t.lines(), { "* H", ":STUFF:", "l1", "l2", ":END:" }, "region")
  end,

  ["C-c C-, s inserts a src block with the cursor after #+begin_src"] = function(t)
    t.open("tsrc.org", "* H\ntext\n")
    t.cursor(2)
    t.answer("s")
    t.keys("C-c C-,")
    t.eq(t.lines(), { "* H", "#+begin_src ", "#+end_src", "text" })
    t.eq(cursor()[1], 2)
    -- Emacs's point is after the space, column 12 (end of line).
    t.eq(t.eval("(current-column)"), "12", "Emacs point")
  end,

  ["with org-log-into-drawer a two-line note goes into LOGBOOK after the properties"] = function(t)
    t.set("org-log-into-drawer", "t")
    t.open("notedrawer.org", "* A\n:PROPERTIES:\n:ID: x\n:END:\nbody\n")
    t.keys("C-c C-z")
    api.nvim_buf_set_lines(0, 2, 3, false, { "line one", "line two" })
    t.keys("C-c C-c")
    local lines = t.lines()
    assert(lines[6] and lines[6]:find(NOTE_LINE), "note heading: " .. vim.inspect(lines))
    lines[6] = "NOTE"
    t.eq(lines, { "* A", ":PROPERTIES:", ":ID: x", ":END:", ":LOGBOOK:", "NOTE",
      "  line one", "  line two", ":END:", "body" })
  end,

  ["a later Emacs command leaves a Neovim yank in the unnamed register"] = function(t)
    t.open("keepreg.org", TREE)
    t.keys("C-c C-x C-w")
    t.feed("yy")
    t.keys("TAB")
    t.eq(vim.fn.getreg('"'), "* B\n")
  end,
}
