-- C-c ' on a source block: the *Org Src* edit buffer as an editable mirror.
local api = vim.api

local DOC = table.concat({
  "* H",
  "#+begin_src python",
  "  x = 1",
  "  print(x)",
  "#+end_src",
  "",
}, "\n")

-- Open DOC and start editing its block with the cursor on "print(x)".
local function edit_block(t, name)
  local path = t.open(name, DOC)
  local org = api.nvim_get_current_buf()
  t.cursor(4, 4)
  t.keys("C-c '")
  return path, org
end

local function is_src(buf) return api.nvim_buf_get_name(buf):find("Org Src", 1, true) ~= nil end

return {
  ["C-c ' opens the block body in an editable split"] = function(t)
    local _, org = edit_block(t, "src_open.org")
    assert(is_src(0), "src buffer focused: " .. api.nvim_buf_get_name(0))
    t.eq(t.lines(), { "x = 1", "print(x)" }, "body without its indentation")
    t.eq(vim.bo.modifiable, true, "editable")
    t.eq(api.nvim_win_get_cursor(0), { 2, 2 }, "cursor follows the block's indentation")
    t.eq(#vim.fn.win_findbuf(org), 1, "org window kept (reorganize-frame splits)")
  end,

  ["C-c ' again writes Neovim's edit back, indented, and closes the split"] = function(t)
    local _, org = edit_block(t, "src_exit.org")
    api.nvim_buf_set_lines(0, -1, -1, false, { "y = 2" })
    t.keys("C-c '")
    t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "edit window closed")
    t.eq(t.lines(), { "* H", "#+begin_src python", "  x = 1", "  print(x)", "  y = 2", "#+end_src" })
    t.eq(vim.bo[org].modified, true)
    for _, b in ipairs(api.nvim_list_bufs()) do
      assert(not is_src(b), "src buffer wiped")
    end
  end,

  ["exiting maps the cursor back into the block"] = function(t)
    local _, org = edit_block(t, "src_cursor.org")
    vim.bo[org].modified = false
    t.cursor(2, 3)
    t.keys("C-c '")
    t.eq(api.nvim_win_get_cursor(0), { 4, 5 })
    t.eq(vim.bo[org].modified, false, "no change, no modification")
  end,

  ["C-c C-k discards the edit"] = function(t)
    local _, org = edit_block(t, "src_abort.org")
    api.nvim_buf_set_lines(0, -1, -1, false, { "y = 2" })
    t.keys("C-c C-k")
    t.eq(api.nvim_get_current_buf(), org)
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "edit window closed")
    t.eq(t.lines(), vim.split(DOC, "\n", { plain = true, trimempty = true }))
    t.eq(api.nvim_win_get_cursor(0), { 3, 0 }, "Emacs leaves point at the body start")
  end,

  ["C-x C-s in the edit buffer writes the org file through Neovim"] = function(t)
    local path, org = edit_block(t, "src_save.org")
    local src = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(0, -1, -1, false, { "z = 3" })
    t.keys("C-x C-s")
    t.eq(api.nvim_get_current_buf(), src, "still editing")
    t.eq(vim.fn.readfile(path)[5], "  z = 3", "file written")
    t.eq(vim.bo[org].modified, false)
    t.keys("C-c '")
    t.eq(api.nvim_get_current_buf(), org)
    t.eq(api.nvim_buf_get_lines(org, 4, 5, false)[1], "  z = 3")
  end,

  ["<C-c> ' typed in Neovim opens and closes the edit buffer"] = function(t)
    t.open("src_keymap.org", DOC)
    local org = api.nvim_get_current_buf()
    t.cursor(3)
    t.answer("'")
    vim.api.nvim_feedkeys("\3", "x", false)
    assert(is_src(0), "src buffer focused: " .. api.nvim_buf_get_name(0))
    t.answer("'")
    vim.api.nvim_feedkeys("\3", "x", false)
    t.eq(api.nvim_get_current_buf(), org)
  end,

  ["C-c ' on a block already being edited returns to its edit buffer"] = function(t)
    local _, org = edit_block(t, "src_reenter.org")
    local src = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(0, -1, -1, false, { "y = 2" })
    api.nvim_set_current_win(vim.fn.win_findbuf(org)[1])
    t.cursor(4, 4)
    t.answer(true)
    t.keys("C-c '")
    t.eq(t.asked()[1].params.prompt, "Return to existing edit buffer ([n] will revert changes)? ")
    t.eq(api.nvim_get_current_buf(), src)
    t.eq(t.lines(), { "x = 1", "print(x)", "y = 2" }, "edit kept")
    t.eq(#api.nvim_tabpage_list_wins(0), 2)
    t.keys("C-c C-k")
  end,

  ["Emacs's src buffer holds Neovim's text before the exit runs"] = function(t)
    edit_block(t, "src_sync.org")
    vim.api.nvim_feedkeys("ggA  # one\27", "x", false)
    require("emacs.mirror").sync()
    t.eq(t.emacs_text("*Org Src src_sync.org[ python ]*"), "x = 1  # one\nprint(x)\n")
    t.keys("C-c C-k")
  end,

  ["the edit buffer shows Emacs's exit hint as its winbar"] = function(t)
    edit_block(t, "src_hint.org")
    assert(vim.wo.winbar:find("C-c '", 1, true), "winbar: " .. vim.wo.winbar)
  end,

  [":w in the edit buffer saves through Emacs"] = function(t)
    local path = edit_block(t, "src_w.org")
    api.nvim_buf_set_lines(0, -1, -1, false, { "w = 4" })
    vim.cmd("write")
    t.eq(vim.fn.readfile(path)[5], "  w = 4", "file written")
    t.eq(vim.bo.modified, false)
  end,
}
