-- Typing in Insert mode on org lines: speed commands, RET, TAB, tags,
-- auto-fill and o. Expected text is what the same keys do in emacs -Q
-- --batch -l test/init.el (electric-indent-mode on, as in Emacs).
local api = vim.api

-- <F12> in insert mode records the mode and cursor at that moment.
local seen = {}

-- Feed keys as typed; "x" ends insert mode when the keys run out.
local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function open(t, name, text)
  t.open(name, text)
  vim.keymap.set("i", "<F12>", function()
    seen[#seen + 1] = { mode = vim.fn.mode(), cursor = api.nvim_win_get_cursor(0) }
  end, { buffer = true })
  seen = {}
end

-- The options a user's Neovim gives org files: Neovim's own org ftplugin.
local function ftplugin(textwidth)
  vim.cmd("runtime ftplugin/org.vim")
  vim.bo.textwidth = textwidth or 0
end

local SPEED = "* A\nbody\n* B\n"

return {
  ["speed commands n and p at the start of a heading move, not type"] = function(t)
    t.set("org-use-speed-commands", "t")
    open(t, "speednp.org", SPEED)
    t.cursor(1, 0)
    feed("in<F12><Esc>")
    t.eq(t.lines(), { "* A", "body", "* B" }, "n types nothing")
    t.eq(seen[1], { mode = "i", cursor = { 3, 0 } }, "n: next heading")
    feed("ip<F12><Esc>")
    t.eq(t.lines(), { "* A", "body", "* B" }, "p types nothing")
    t.eq(seen[2], { mode = "i", cursor = { 1, 0 } }, "p: previous heading")
  end,

  ["speed command t at the start of a heading runs org-todo"] = function(t)
    t.set("org-use-speed-commands", "t")
    open(t, "speedt.org", SPEED)
    t.cursor(1, 0)
    t.answer("t")
    feed("it<Esc>")
    t.eq(t.lines(), { "* TODO A", "body", "* B" })
  end,

  ["a speed key away from the start of a heading is typed"] = function(t)
    t.set("org-use-speed-commands", "t")
    open(t, "speedmid.org", SPEED)
    t.cursor(1, 2)
    feed("in<Esc>")
    t.eq(t.lines(), { "* nA", "body", "* B" })
  end,

  ["RET on a list item indents the new line to the item's text"] = function(t)
    open(t, "retitem.org", "* L\n- one\n")
    ftplugin()
    t.cursor(2)
    feed("A<CR>x<Esc>")
    t.eq(t.lines(), { "* L", "- one", "  x" })
  end,

  ["o on a list item opens a line indented like Emacs's C-e RET"] = function(t)
    open(t, "oitem.org", "* L\n- one\n")
    ftplugin()
    t.cursor(2)
    feed("otwo<Esc>")
    t.eq(t.lines(), { "* L", "- one", "  two" })
  end,

  -- Vim's . would only append "two": the new line came from Emacs.
  ["after o, . opens another line and types the same keys"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("on_key reports typed keys from 0.10") end
    local twice = {}
    for _, keys in ipairs({ "otwo<CR>three<Esc>otwo<CR>three<Esc>", "otwo<CR>three<Esc>." }) do
      open(t, "odot.org", "* L\n- one\n")
      t.cursor(2)
      feed(keys)
      twice[#twice + 1] = t.lines()
      vim.cmd("bwipeout!")
    end
    t.eq(twice[2], twice[1])
    t.eq(#twice[1], 6, "two lines added twice: " .. vim.inspect(twice[1]))
  end,

  ["RET inside a tagged heading keeps the tags on the heading"] = function(t)
    open(t, "rettags.org", t.aligned("* Head", ":tag:") .. "\n")
    t.cursor(1, 4)
    feed("i<CR><F12><Esc>")
    t.eq(t.lines(), { t.aligned("* He", ":tag:"), "ad" })
    t.eq(seen[1], { mode = "i", cursor = { 2, 0 } })
  end,

  ["RET at the end of a heading indents with org-adapt-indentation t"] = function(t)
    t.set("org-adapt-indentation", "t")
    open(t, "retadapt.org", "* Head\n")
    ftplugin()
    feed("A<CR>x<Esc>")
    t.eq(t.lines(), { "* Head", "  x" })
  end,

  ["RET on a link follows it with org-return-follows-link"] = function(t)
    t.set("org-return-follows-link", "t")
    open(t, "retlink.org", "* A\n[[*B]]\n* B\n")
    t.cursor(2, 3)
    feed("i<CR><F12><Esc>")
    t.eq(t.lines(), { "* A", "[[*B]]", "* B" }, "no newline")
    t.eq(seen[1], { mode = "i", cursor = { 3, 0 } }, "at heading B")
  end,

  ["Tab on an empty item indents it; on a heading it folds"] = function(t)
    open(t, "tabitem.org", "* L\n- one\n- \n")
    t.cursor(3)
    feed("A<Tab><F12>x<Esc>")
    t.eq(t.lines(), { "* L", "- one", "  - x" }, "empty item")
    t.eq(seen[1], { mode = "i", cursor = { 3, 4 } })
    open(t, "tabhead.org", SPEED)
    feed("A<Tab><F12><Esc>")
    t.eq(t.lines(), { "* A", "body", "* B" }, "heading text")
    t.eq(seen[1], { mode = "i", cursor = { 1, 3 } })
    t.eq(t.folds(), { "1-2" }, "subtree folded")
  end,

  ["typing in a heading keeps aligned tags in their column"] = function(t)
    open(t, "typetags.org", t.aligned("* Head", ":tag:") .. "\n")
    t.cursor(1, 4)
    feed("ixy<Esc>")
    t.eq(t.lines(), { t.aligned("* Hexyad", ":tag:") }, "realigned")
    -- After the tags nothing is realigned.
    open(t, "typeafter.org", t.aligned("* Head", ":tag:") .. "\n")
    feed("Ax<Esc>")
    t.eq(t.lines(), { t.aligned("* Head", ":tag:") .. "x" }, "after the tags")
  end,

  ["u after typing in a tagged heading undoes the text and the realign together"] = function(t)
    local before = t.aligned("* Head", ":tag:")
    open(t, "typeundo.org", before .. "\n")
    t.cursor(1, 4)
    feed("ixy<Esc>")
    t.eq(t.lines(), { t.aligned("* Hexyad", ":tag:") }, "realigned")
    vim.cmd("normal! u")
    t.eq(t.lines(), { before })
  end,

  ["C-c C-t from insert mode inside a heading keeps point on its text"] = function(t)
    open(t, "icct.org", "* Head\n")
    t.cursor(1, 4)
    t.answer("C-t", "t")
    feed("i<C-c><F12>X<Esc>")
    t.eq(seen[1], { mode = "i", cursor = { 1, 9 } })
    t.eq(t.lines(), { "* TODO HeXad" })
  end,

  ["auto-fill wraps items and body text but never a heading"] = function(t)
    t.set("org-adapt-indentation", "t")
    open(t, "fillitem.org", "* L\n- \n")
    ftplugin(12)
    t.cursor(2)
    feed("Aaaa bbb ccc ddd eee fff<Esc>")
    t.eq(t.lines(), { "* L", "- aaa bbb", "  ccc ddd", "  eee fff" }, "item")
    open(t, "fillbody.org", "* H\n  \n")
    ftplugin(12)
    t.cursor(2)
    feed("Aaaa bbb ccc ddd<Esc>")
    t.eq(t.lines(), { "* H", "  aaa bbb", "  ccc ddd" }, "body")
    open(t, "fillhead.org", "* \n")
    ftplugin(12)
    feed("Aaaa bbb ccc ddd eee<Esc>")
    t.eq(t.lines(), { "* aaa bbb ccc ddd eee" }, "heading")
  end,
}
