-- Vim navigation state across Emacs commands: marks, the jumplist, the
-- changelist, fold motions, search into folds, scrolling, gv and splits.
-- Where Emacs has an equivalent (markers, window-point, the mark ring), the
-- expectation is what emacs -Q --batch does with the same commands.
local api = vim.api
local mirror = require("emacs.mirror")

-- Keys as typed: 'foldopen' ignores keys that aren't.
local function type(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function line() return api.nvim_win_get_cursor(0)[1] end

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- Lines inside closed Neovim folds, minus each fold's first (shown) line.
local function vim_hidden()
  local out = {}
  for l = 1, vim.fn.line("$") do
    local fs = vim.fn.foldclosed(l)
    if fs ~= -1 and fs ~= l then out[#out + 1] = l end
  end
  return out
end

-- Lines Emacs hides, as a JSON list of line numbers (t.eval JSON-encodes
-- the string, hence the second decode).
local HIDDEN_EXPR = [[(with-current-buffer (get-file-buffer %q)
  (save-excursion (goto-char (point-min))
    (let ((n 1) out)
      (while (not (eobp))
        (when (invisible-p (point)) (push n out))
        (forward-line 1) (setq n (1+ n)))
      (concat "[" (mapconcat #'number-to-string (nreverse out) ",") "]"))))]]

local function emacs_hidden(t, path) return vim.json.decode(vim.json.decode(t.eval(HIDDEN_EXPR:format(path)))) end

local function folds_agree(t, path, what)
  t.eq(vim_hidden(), emacs_hidden(t, path), (what or "") .. " Emacs hides the same lines")
end

local REFILE = "* A\nbody a\n** A1\ntext\n* B\nbody b\n** B1\n"

return {
  -- Emacs: a marker on A follows A when M-up moves B above it (3:0).
  ["a mark on text M-up moves past follows that text, as Emacs's marker does"] = function(t)
    local path = t.open("nav_mark.org", t.DOC)
    t.cursor(1)
    t.feed("ma")
    t.cursor(5)
    t.feed("<M-Up>")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a", "** A1", "text" })
    agree(t, path)
    t.feed("`a")
    t.eq(api.nvim_get_current_line(), "* A", "`a lands on the heading it was set on")
  end,

  -- Emacs: a marker on B moves to line 1 when C-c C-w moves A under B.
  ["a mark below a refiled subtree follows its text"] = function(t)
    local path = t.open("nav_refile.org", REFILE)
    t.eval([[(setq org-refile-targets '((nil :maxlevel . 2)) org-refile-use-outline-path nil
                   org-refile-history nil)]])
    t.cursor(6, 2)
    t.feed("mb")
    t.cursor(1)
    t.answer("B")
    t.keys("C-c C-w")
    t.eq(t.lines(), { "* B", "body b", "** B1", "** A", "body a", "*** A1", "text" })
    agree(t, path)
    t.feed("`b")
    t.eq(api.nvim_get_current_line(), "body b", "`b follows B's body")
    t.eq(api.nvim_win_get_cursor(0), { 2, 2 })
  end,

  -- gg records a jump at "body b"; Emacs's M-< pushes a mark there, which
  -- stays on "body b" (now line 2) when M-down moves A below it. (:edit's
  -- own jumplist entry is line 1, so the test must not expect line 1.)
  ["<C-o> after M-down returns to the text the jump was made from"] = function(t)
    local path = t.open("nav_jump.org", t.DOC)
    t.cursor(6)
    t.feed("gg")
    t.feed("<M-Down>")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a", "** A1", "text" })
    t.eq(line(), 3, "cursor follows A")
    agree(t, path)
    t.feed("<C-o>")
    t.eq(api.nvim_get_current_line(), "body b", "<C-o> goes back to B's body")
  end,

  -- Emacs pushes the mark ring (C-c & goes back); a Vim user expects the
  -- jump to be on the jumplist too.
  ["C-c C-j is a jump: <C-o> and C-c & both go back"] = function(t)
    local path = t.open("nav_goto.org", "* A\n** A1\n* B\n** B1\n")
    t.eval("(require 'org-goto)")
    t.set("org-goto-interface", "'outline-path-completion")
    t.set("org-refile-history", "nil")
    t.cursor(2)
    t.answer("B/B1")
    t.keys("C-c C-j")
    t.eq(line(), 4)
    t.keys("C-c &")
    t.eq(line(), 2, "C-c &, as in Emacs")
    t.answer("B/B1")
    t.keys("C-c C-j")
    t.feed("<C-o>")
    t.eq(line(), 2, "<C-o>")
    agree(t, path)
  end,

  ["g; visits the line an Emacs command changed"] = function(t)
    local path = t.open("nav_change.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    t.cursor(1)
    t.feed("g;")
    t.eq(line(), 5, "g;")
    agree(t, path)
  end,

  ["zj/zk move between Emacs folds; zc/zo/za/zv keep both sides' folds equal"] = function(t)
    local path = t.open("nav_folds.org", "* A\nbody a\n** A1\ntext\n* B\nbody b\n** B1\nb1\n")
    t.cursor(3)
    t.keys("TAB")
    t.cursor(7)
    t.keys("TAB")
    t.eq(t.folds(), { "3-4", "7-8" })
    t.cursor(1)
    t.feed("zj")
    t.eq(line(), 3, "zj to the A1 fold")
    t.feed("zj")
    t.eq(line(), 7, "zj to the B1 fold")
    t.feed("zk")
    t.eq(vim.fn.foldclosed(line()), 3, "zk back into the A1 fold")
    -- zc on body a: org-fold-hide-subtree hides A's subtree.
    t.cursor(2)
    t.feed("zc")
    t.eq(t.folds(), { "1-4", "7-8" }, "zc")
    folds_agree(t, path, "zc")
    t.feed("zo")
    folds_agree(t, path, "zo")
    t.cursor(7)
    t.feed("za")
    folds_agree(t, path, "za")
    -- zv on a line inside a closed fold: Emacs's org-reveal at that line
    -- shows it.
    t.cursor(5)
    t.feed("zM")
    t.cursor(8)
    t.feed("zv")
    t.eq(vim.fn.foldclosed(8), -1, "zv shows the cursor line")
    folds_agree(t, path, "zv")
    agree(t, path)
  end,

  -- Neovim's 'foldopen' opens a fold a search lands in; Emacs's C-s text RET
  -- reveals it for good (line 4 stays visible through a later org-todo). The next Emacs command must not fold it again.
  ["/ into a folded subtree stays open after the next Emacs command"] = function(t)
    local path = t.open("nav_search.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    type("/text<CR>")
    t.eq(line(), 4)
    t.eq(t.folds(), {}, "search opened the fold")
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    t.eq(t.folds(), {}, "fold still open after C-c C-t")
    folds_agree(t, path)
    t.feed("gg")
    t.feed("n")
    t.eq(line(), 4, "n after an Emacs command")
    agree(t, path)
  end,

  ["# into a folded body, then TAB elsewhere, keeps the found line visible"] = function(t)
    local path = t.open("nav_star.org", "* A\nbody x\n* B\nbody y\n* C\nbody\n")
    t.keys("TAB")
    t.eq(t.folds(), { "1-2" })
    t.cursor(6, 0)
    type("#")
    t.eq(line(), 4)
    type("#")
    t.eq(line(), 2, "# reaches A's folded body")
    t.cursor(5)
    t.keys("TAB")
    t.cursor(2)
    t.eq(vim.fn.foldclosed(2), -1, "line 2 still visible")
    folds_agree(t, path)
    agree(t, path)
  end,

  -- Emacs leaves point on "word" (1:58) after C-c C-t inserts TODO.
  ["the cursor stays on its word after C-c C-t on a long concealed line"] = function(t)
    local head = "* see [[https://example.com/a/very/long/path][desc]] word"
    local path = t.open("nav_conceal.org", head .. "\n")
    vim.wo.conceallevel = 2
    t.cursor(1, head:find("word") - 1)
    t.answer("t")
    t.keys("C-c C-t")
    local new = "* TODO see [[https://example.com/a/very/long/path][desc]] word"
    t.eq(t.lines(), { new })
    t.eq(api.nvim_win_get_cursor(0), { 1, new:find("word") - 1 })
    agree(t, path)
  end,

  ["zt and zz scrolling survive C-c C-t and TAB"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("Neovim 0.9 moves the view when folds are rebuilt") end
    local doc = {}
    for i = 1, 80 do doc[#doc + 1] = ("* H%d\nbody %d"):format(i, i) end
    local path = t.open("nav_scroll.org", table.concat(doc, "\n") .. "\n")
    t.cursor(61)
    t.feed("zt")
    local top = vim.fn.line("w0")
    t.eq(top, 61)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(vim.fn.line("w0"), top, "zt kept after C-c C-t")
    t.feed("zz")
    local view = vim.fn.winsaveview()
    t.keys("TAB")
    t.eq(vim.fn.winsaveview().topline, view.topline, "zz kept after TAB")
    agree(t, path)
  end,

  -- Emacs: markers on A (the region gv would restore) follow A to line 3.
  ["gv after M-up reselects the text that was selected"] = function(t)
    local path = t.open("nav_gv.org", t.DOC)
    t.cursor(1)
    t.feed("Vj<Esc>")
    t.cursor(5)
    t.feed("<M-Up>")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a", "** A1", "text" })
    agree(t, path)
    t.feed("gv<Esc>")
    t.eq({ vim.fn.line("'<"), vim.fn.line("'>") }, { 3, 4 }, "gv selects A and its body")
  end,

  -- Emacs: the other window's point follows its text (body b, 2:3).
  ["the other window on the same buffer keeps its place when this one runs M-down"] = function(t)
    local path = t.open("nav_split.org", t.DOC)
    vim.cmd("split")
    local other = api.nvim_get_current_win()
    api.nvim_win_set_cursor(other, { 6, 3 })
    vim.cmd("wincmd j")
    local this = api.nvim_get_current_win()
    assert(this ~= other)
    t.cursor(1)
    t.feed("<M-Down>")
    t.eq(t.lines(), { "* B", "body b", "* A", "body a", "** A1", "text" })
    t.eq(api.nvim_win_get_cursor(this), { 3, 0 }, "this window follows A")
    t.eq(api.nvim_win_get_cursor(other), { 2, 3 }, "other window follows body b")
    agree(t, path)
    vim.cmd("only")
  end,
}
