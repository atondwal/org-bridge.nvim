-- Windows and tab pages around Emacs commands: one buffer in two windows,
-- :vsplit layouts, a second tab page, :only/:close/<C-w>o, floats, and the
-- agenda from tab 2. Emacs only gets the current tab's non-float windows;
-- org's folds are per buffer, so every window on a buffer shows the same.
local api = vim.api
local mirror = require("emacs.mirror")

local OTHER = "* X\nbody x\n* Y\nbody y\n"

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(vim.fn.bufnr(path)), (what or "") .. " Emacs agrees")
end

local function todo(t, lnum, key)
  t.cursor(lnum)
  t.answer(key or "t")
  t.keys("C-c C-t")
end

-- Keys as typed: 'foldopen' ignores keys that aren't.
local function type(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function folds_in(t, win)
  return api.nvim_win_call(win, t.folds)
end

-- winlayout() of a tab page with each window replaced by its file's name.
local function shape(tab)
  local function walk(node)
    if node[1] == "leaf" then
      return vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(node[2])), ":t")
    end
    return { node[1], vim.tbl_map(walk, node[2]) }
  end
  return walk(vim.fn.winlayout(vim.api.nvim_tabpage_get_number(tab)))
end

local function new_tab(t)
  vim.cmd("tabnew")
  t.after(function() vim.cmd("silent! tabonly!") end)
  return api.nvim_get_current_tabpage()
end

-- Lines Emacs hides in path, 1-based.
local HIDDEN_EXPR = [[(with-current-buffer (get-file-buffer %q)
  (save-excursion (goto-char (point-min))
    (let ((n 1) out)
      (while (not (eobp))
        (when (invisible-p (point)) (push n out))
        (forward-line 1) (setq n (1+ n)))
      (concat "[" (mapconcat #'number-to-string (nreverse out) ",") "]"))))]]

local function emacs_hidden(t, path) return vim.json.decode(vim.json.decode(t.eval(HIDDEN_EXPR:format(path)))) end

return {
  -- Emacs: C-s text RET in the lower window reveals A's body for the
  -- buffer; TAB on B in the upper window leaves it shown (hidden: 6 only).
  ["a fold a search opened in window B stays open after TAB in window A"] = function(t)
    local path = t.open("ws_search.org", t.DOC)
    local a = api.nvim_get_current_win()
    t.keys("TAB")
    vim.cmd("belowright split")
    local b = api.nvim_get_current_win()
    t.eq(t.folds(), { "1-4" })
    type("/text<CR>")
    t.eq(api.nvim_win_get_cursor(b)[1], 4)
    t.eq(t.folds(), {}, "search opened the fold in B")
    api.nvim_set_current_win(a)
    t.cursor(5)
    t.keys("TAB")
    t.eq(emacs_hidden(t, path), { 6 }, "Emacs hides only B's body")
    t.eq(folds_in(t, b), { "5-6" }, "window B")
    t.eq(folds_in(t, a), { "5-6" }, "window A")
  end,

  ["TAB in window A folds the subtree window B's cursor is in; B's cursor stays"] = function(t)
    local path = t.open("ws_fold.org", t.DOC)
    local a = api.nvim_get_current_win()
    vim.cmd("belowright split")
    local b = api.nvim_get_current_win()
    t.cursor(4, 2)
    api.nvim_set_current_win(a)
    t.cursor(1)
    t.keys("TAB")
    t.eq(folds_in(t, a), { "1-4" }, "window A")
    t.eq(folds_in(t, b), { "1-4" }, "window B")
    t.eq(api.nvim_win_get_cursor(b), { 4, 2 }, "B's cursor")
    t.eq(api.nvim_get_current_win(), a)
    agree(t, path)
  end,

  ["a command in window A keeps window B's other org file, cursor and folds"] = function(t)
    local other = t.open("ws_other.org", OTHER)
    t.keys("TAB")
    local b = api.nvim_get_current_win()
    t.cursor(3, 2)
    vim.cmd("aboveleft split")
    local path = t.open("ws_main.org", t.DOC)
    local a = api.nvim_get_current_win()
    todo(t, 5)
    t.eq(t.lines()[5], "* TODO B")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(b)), ":t"), "ws_other.org")
    t.eq(api.nvim_win_get_cursor(b), { 3, 2 }, "B's cursor")
    t.eq(folds_in(t, b), { "1-2" }, "B's folds")
    t.eq(api.nvim_get_current_win(), a)
    agree(t, path)
    agree(t, other, "other file")
  end,

  [":vsplit side by side: a command on the right keeps the layout"] = function(t)
    t.open("ws_left.org", OTHER)
    vim.cmd("belowright vsplit")
    local path = t.open("ws_right.org", t.DOC)
    vim.cmd("belowright split")
    t.open("ws_lower.org", OTHER)
    vim.cmd("wincmd k")
    local tab = api.nvim_get_current_tabpage()
    local before = shape(tab)
    t.eq(before, { "row", { "ws_left.org", { "col", { "ws_right.org", "ws_lower.org" } } } })
    local widths = vim.tbl_map(api.nvim_win_get_width, api.nvim_tabpage_list_wins(tab))
    todo(t, 1)
    t.eq(t.lines()[1], "* TODO A")
    t.eq(shape(tab), before, "layout")
    t.eq(vim.tbl_map(api.nvim_win_get_width, api.nvim_tabpage_list_wins(tab)), widths, "widths")
    agree(t, path)
  end,

  [":vsplit of one buffer: TAB on the left folds both, the right keeps its cursor"] = function(t)
    local path = t.open("ws_vsame.org", t.DOC)
    vim.cmd("vsplit")
    local left = api.nvim_get_current_win()
    vim.cmd("wincmd l")
    local right = api.nvim_get_current_win()
    t.cursor(6, 3)
    api.nvim_set_current_win(left)
    t.cursor(1)
    t.keys("<backtab>")
    t.eq(folds_in(t, left), { "1-4", "5-6" })
    t.eq(folds_in(t, right), { "1-4", "5-6" })
    t.eq(api.nvim_win_get_cursor(right), { 6, 3 })
    t.eq(#api.nvim_tabpage_list_wins(0), 2)
    agree(t, path)
  end,

  ["a command in tab 2, then back to tab 1: tab 1's layout and text survive"] = function(t)
    local path = t.open("ws_tab1.org", t.DOC)
    vim.cmd("vsplit")
    vim.cmd("split")
    local other = t.open("ws_tab1b.org", OTHER)
    local tab1 = api.nvim_get_current_tabpage()
    local cur1 = api.nvim_get_current_win()
    local before = shape(tab1)
    local tab2 = new_tab(t)
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    vim.cmd("split")
    vim.cmd("silent edit " .. vim.fn.fnameescape(other))
    local before2 = shape(tab2)
    vim.cmd("wincmd j")
    todo(t, 5)
    t.eq(t.lines()[5], "* TODO B")
    t.eq(api.nvim_get_current_tabpage(), tab2, "still in tab 2")
    t.eq(shape(tab2), before2, "tab 2 layout")
    vim.cmd("tabprevious")
    t.eq(shape(tab1), before, "tab 1 layout")
    t.eq(api.nvim_get_current_win(), cur1, "tab 1's current window")
    agree(t, path)
    -- Now a command in tab 1; tab 2 must survive it too.
    todo(t, 3)
    t.eq(t.lines()[3], "* TODO Y")
    t.eq(shape(tab1), before, "tab 1 layout after its own command")
    t.eq(shape(tab2), before2, "tab 2 layout after tab 1's command")
    agree(t, other)
  end,

  ["TAB in tab 2 folds the same buffer's window in tab 1"] = function(t)
    local path = t.open("ws_tabfold.org", t.DOC)
    local w1 = api.nvim_get_current_win()
    new_tab(t)
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    t.cursor(1)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    vim.cmd("tabprevious")
    t.eq(api.nvim_get_current_win(), w1)
    t.eq(t.folds(), { "1-4" }, "tab 1's window")
    t.eq(emacs_hidden(t, path), { 2, 3, 4 })
  end,

  ["<C-w>o, :close and :only between commands keep what Neovim left"] = function(t)
    local other = t.open("ws_only_b.org", OTHER)
    vim.cmd("split")
    local path = t.open("ws_only_a.org", t.DOC)
    vim.cmd("vsplit")
    todo(t, 1)
    t.eq(#api.nvim_tabpage_list_wins(0), 3)
    t.feed("<C-w>o")
    todo(t, 5)
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "after <C-w>o")
    t.eq(t.lines()[5], "* TODO B")
    vim.cmd("split")
    vim.cmd("silent edit " .. vim.fn.fnameescape(other))
    vim.cmd("split")
    vim.cmd("close")
    todo(t, 1)
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "after :close")
    t.eq(t.lines()[1], "* TODO X")
    vim.cmd("only")
    t.keys("TAB")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "after :only")
    t.eq(t.folds(), { "1-2" })
    agree(t, path)
    agree(t, other)
  end,

  ["a help float open during a command stays open and floating"] = function(t)
    local path = t.open("ws_float.org", t.DOC)
    local win = api.nvim_get_current_win()
    local fbuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(fbuf, 0, -1, false, { "help text" })
    local float = api.nvim_open_win(fbuf, false,
      { relative = "editor", row = 1, col = 10, width = 20, height = 3, style = "minimal" })
    t.after(function() if api.nvim_win_is_valid(float) then api.nvim_win_close(float, true) end end)
    todo(t, 1)
    t.keys("TAB")
    t.eq(t.lines()[1], "* TODO A")
    assert(api.nvim_win_is_valid(float), "float still open")
    t.eq(api.nvim_win_get_config(float).relative, "editor", "still floating")
    t.eq(api.nvim_win_get_buf(float), fbuf, "float's buffer")
    t.eq(api.nvim_get_current_win(), win)
    t.eq(t.folds(), { "1-4" })
    agree(t, path)
  end,

  -- An org buffer shown in a float (a preview plugin, say): the command
  -- acts there, and the window under it keeps its own file.
  ["a command in a float on an org file leaves the window under it alone"] = function(t)
    local under = t.open("ws_under.org", OTHER)
    local base = api.nvim_get_current_win()
    local path = t.file("ws_infloat.org", t.DOC)
    local fbuf = vim.fn.bufadd(path)
    vim.fn.bufload(fbuf)
    local float = api.nvim_open_win(fbuf, true,
      { relative = "editor", row = 1, col = 10, width = 40, height = 6 })
    t.after(function() if api.nvim_win_is_valid(float) then api.nvim_win_close(float, true) end end)
    assert(mirror.id(fbuf), "float's buffer attached")
    todo(t, 5)
    t.eq(api.nvim_buf_get_lines(fbuf, 4, 5, false)[1], "* TODO B", "float's file changed")
    t.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(base), 0, -1, false), vim.split(OTHER:sub(1, -2), "\n"),
      "under's text")
    t.eq(api.nvim_win_get_buf(base), vim.fn.bufnr(under), "window under keeps its file")
    t.eq(api.nvim_get_current_win(), float, "still in the float")
    agree(t, path)
  end,

  -- Emacs only sees tab 1's windows while there; the agenda in tab 2 is
  -- outside that layout and must not be closed or moved.
  ["the agenda in tab 2 survives a command in tab 1, then r rebuilds it"] = function(t)
    local path = t.open("ws_agenda.org", "* TODO Write report\n* TODO Call Bob\n")
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    t.after(function() t.eval("(setq org-agenda-files nil)") end)
    local file_buf = api.nvim_get_current_buf()
    local tab1 = api.nvim_get_current_tabpage()
    local tab2 = new_tab(t)
    t.answer("t")
    t.command("org-agenda")
    local agenda = api.nvim_get_current_buf()
    assert(api.nvim_buf_get_name(agenda):find("Org Agenda"), "agenda in tab 2")
    local tab2_wins = #api.nvim_tabpage_list_wins(tab2)
    vim.cmd("tabprevious")
    todo(t, 2, "d")
    t.eq(t.lines()[2], "* DONE Call Bob")
    t.eq(#api.nvim_tabpage_list_wins(tab1), 1, "tab 1 keeps one window")
    t.eq(api.nvim_win_get_buf(api.nvim_tabpage_list_wins(tab1)[1]), file_buf)
    t.eq(#api.nvim_tabpage_list_wins(tab2), tab2_wins, "tab 2's windows")
    assert(#vim.fn.win_findbuf(agenda) == 1, "agenda window still there")
    vim.cmd("tabnext")
    api.nvim_set_current_win(vim.fn.win_findbuf(agenda)[1])
    t.feed("r")
    t.eq(api.nvim_get_current_tabpage(), tab2)
    -- The TODO list drops DONE entries.
    t.eq(t.find_line("Call Bob"), nil, "rebuilt agenda")
    assert(t.find_line("Write report"), "agenda still lists the open task")
    t.eq(#api.nvim_tabpage_list_wins(tab2), tab2_wins, "tab 2's windows after r")
    agree(t, path)
  end,
}
