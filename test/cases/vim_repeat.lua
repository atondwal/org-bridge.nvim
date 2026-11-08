-- Repetition over org keys: dot-repeat, counts, recorded macros and
-- :g/pattern/normal. Expected text: emacs -Q --batch -l test/init.el running
-- the same Emacs keys on each line (an undo boundary per command).
local api = vim.api
local mirror = require("emacs.mirror")

local THREE = "* A\n* B\n* C\n"

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- Feed keys as typed: q records only typed keys, and Neovim closes an undo
-- step only between typed keys.
local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

-- The plugin's real prompt handlers (the harness stubs them): Emacs's
-- questions read the next keys from typeahead, so a macro or :normal
-- answers C-c's second key and the TODO menu itself.
local function real_prompts()
  package.loaded["emacs.ui"] = nil
  require("emacs.ui")
end

return {
  -- Emacs: C-u 3 S-<right> on a heading is one TODO step (org-shiftright
  -- ignores the count), not three.
  ["3<S-Right> moves one TODO state, as C-u 3 S-right"] = function(t)
    local path = t.open("count_sright.org", THREE)
    t.cursor(2)
    feed("3<S-Right>")
    t.eq(t.lines(), { "* A", "* TODO B", "* C" })
    agree(t, path)
  end,

  ["2<M-Down> moves the subtree past two siblings, as C-u 2 M-down"] = function(t)
    local path = t.open("count_mdown.org", "* A\nbody a\n* B\nbody b\n* C\n")
    feed("2<M-Down>")
    t.eq(t.lines(), { "* B", "body b", "* C", "* A", "body a" })
    t.eq(api.nvim_win_get_cursor(0)[1], 4, "cursor follows the subtree")
    agree(t, path)
  end,

  -- Emacs's C-x z redoes the last command; . redoes the last org key that
  -- changed the text, with its menu answer (C-c C-t n), past keys that
  -- changed nothing (TAB); text typed after M-RET is Vim's insert, which
  -- . types again.
  [". after org keys redoes the last org change"] = function(t)
    local path = t.open("dot_org.org", "* A\nbody\n* B\n* C\n* D\n* E\n")
    real_prompts()
    t.cursor(2)
    feed("rZ")
    t.cursor(1)
    feed("<S-Right>")
    feed("<C-c><C-t>n")
    feed("<Tab>")
    t.eq(t.lines()[1], "* NEXT A", "org keys ran")
    t.cursor(3, 2)
    feed(".")
    t.eq(t.lines()[3], "* NEXT B", ". is C-c C-t n")
    t.cursor(4, 1)
    feed("<M-CR>New<Esc>")
    t.eq(t.lines()[5], "* New", "M-RET and a typed heading")
    t.cursor(6, 2)
    feed(".")
    t.eq(t.lines()[6], "* NewD", ". after M-RET types New again")
    agree(t, path)
  end,

  -- Vim: . after A New<Esc> appends " New" again; after cwX<Esc> it
  -- changes the next word to X.
  [". after typing on a heading repeats the typed text"] = function(t)
    local path = t.open("dot_heading.org", "* A\n* B\n* C\n* D\n")
    feed("A New<Esc>")
    t.cursor(2)
    feed(".")
    t.eq(t.lines()[2], "* B New", ". after A")
    t.cursor(3, 2)
    feed("cwX<Esc>")
    t.cursor(4, 2)
    feed(".")
    t.eq(t.lines(), { "* A New", "* B New", "* X", "* X" }, ". after cw")
    agree(t, path)
  end,

  [". after typing in a table cell repeats the typed text"] = function(t)
    t.skip("text typed in a table goes through Emacs, not Vim's redo register (PROGRESS.md)")
  end,

  -- Vim: 3A!<Esc> appends "!!!", as it does on a body line.
  ["3A!<Esc> on a heading inserts the text three times"] = function(t)
    local path = t.open("count_append.org", "* A\nbody\n")
    feed("3A!<Esc>")
    t.cursor(2)
    feed("3A!<Esc>")
    t.eq(t.lines(), { "* A!!!", "body!!!" })
    agree(t, path)
  end,

  -- Vim: . after o** x<Esc> opens another "** x" line below the cursor.
  [". after o and a typed heading opens another heading"] = function(t)
    t.skip("o's new line comes from Emacs's C-e RET, which . can't redo (PROGRESS.md)")
  end,

  -- Emacs: C-n C-c C-t t as a keyboard macro, run twice more.
  ["a macro j<C-c><C-t>t marks each next heading TODO"] = function(t)
    local path = t.open("macro_todo.org", "* top\n* A\n* B\n* C\n")
    real_prompts()
    feed("qaj<C-c><C-t>tq")
    t.eq(t.lines()[2], "* TODO A", "while recording")
    feed("2@a")
    t.eq(t.lines(), { "* top", "* TODO A", "* TODO B", "* TODO C" })
    agree(t, path)
  end,

  ["a macro mixing an edit and M-Down keeps both sides equal"] = function(t)
    local path = t.open("macro_mdown.org", "* A\n* B\n* C\n* D\n")
    feed("qaA!<Esc><M-Down>q")
    t.eq(t.lines(), { "* B", "* A!", "* C", "* D" }, "recorded")
    feed("@a")
    t.eq(t.lines(), { "* B", "* C", "* A!!", "* D" }, "@a")
    agree(t, path)
  end,

  -- Emacs: M-<down> C-e ! recorded, then C-u 5 C-x e stops at the first
  -- "Cannot move past superior level", as a failing Vim command stops @a.
  ["5@a stops at the first org key that fails"] = function(t)
    local path = t.open("macro_fail.org", THREE)
    feed("qa<M-Down>A!<Esc>q")
    feed("5@a")
    t.eq(t.lines(), { "* B", "* C", "* A!!" })
    agree(t, path)
  end,

  [":g/^** /normal <S-Right> marks each level-2 heading TODO"] = function(t)
    local path = t.open("g_sright.org", "* A\n** x\n** y\n* B\n** z\n")
    vim.cmd([[exe "g/^\\*\\* /normal \<S-Right>"]])
    t.eq(t.lines(), { "* A", "** TODO x", "** TODO y", "* B", "** TODO z" })
    agree(t, path)
  end,

  [":g/^- \\[/normal <C-c><C-c> checks each box and counts them"] = function(t)
    local path = t.open("g_check.org", "* T [/]\n- [ ] a\n- [ ] b\n- [ ] c\n")
    real_prompts()
    vim.cmd([[exe "g/^- \\[/normal \<C-c>\<C-c>"]])
    t.eq(t.lines(), { "* T [3/3]", "- [X] a", "- [X] b", "- [X] c" })
    agree(t, path)
  end,

  [". repeats S-right on another heading"] = function(t)
    local path = t.open("dot_sright.org", "* A\n* B\n")
    feed("<S-Right>")
    t.cursor(2)
    feed(".")
    t.eq(t.lines(), { "* TODO A", "* TODO B" })
    agree(t, path)
  end,

  [". after a Vim edit that followed an org key is Vim's ."] = function(t)
    local path = t.open("dot_after_vim.org", "* A\nbody\nmore\n")
    feed("<S-Right>")
    t.cursor(2)
    feed("x")
    t.cursor(3)
    feed(".")
    t.eq(t.lines(), { "* TODO A", "ody", "ore" })
    agree(t, path)
  end,

  -- With vim-repeat, its . replays the org key: we hand it the keys.
  ["with vim-repeat, an org change calls repeat#set"] = function(t)
    -- A stand-in vim-repeat: autoload functions must come from their file.
    local dir = t.WORK .. "/fake-repeat"
    vim.fn.mkdir(dir .. "/autoload", "p")
    vim.fn.writefile({ "function! repeat#set(seq, ...) abort", "  call add(g:emacs_test_repeat, a:seq)",
      "endfunction" }, dir .. "/autoload/repeat.vim")
    vim.g.emacs_test_repeat = {}
    vim.opt.rtp:prepend(dir)
    vim.fn["repeat#set"]("")
    vim.g.emacs_test_repeat = {}
    t.after(function()
      vim.cmd("delfunction repeat#set")
      vim.opt.rtp:remove(dir)
    end)
    t.open("dot_vimrepeat.org", "* A\n")
    feed("<S-Right>")
    t.eq(vim.g.emacs_test_repeat, { vim.api.nvim_replace_termcodes("<Plug>(emacs-repeat)", true, true, true) })
  end,
}
