-- Closing Emacs's buffers and windows with Vim commands (:q, :close, :bd,
-- :bw, :only, :tabclose) on capture, src edit, *Org Note*, *Edit Formulas*,
-- column view and the agenda, then using org again.
-- Expectations: emacs -Q --batch -l test/init.el, with kill-buffer for
-- :bd/:bw and delete-window for :q/:close.
local api = vim.api
local mirror = require("emacs.mirror")

local function agree(t, path, what)
  mirror.sync()
  local buf = vim.fn.bufnr(path)
  t.eq(t.emacs_lines(path), t.lines(buf), (what or "") .. " Emacs agrees")
end

local function name() return api.nvim_buf_get_name(0) end

local function capture_into(t, file)
  local inbox = t.file(file, "")
  t.eval(([[(setq org-capture-templates '(("t" "Task" entry (file %q) "* TODO %%?")))]]):format(inbox))
  t.after(function() t.eval([[(setq org-capture-templates '(("t" "Task" entry (file "inbox.org") "* TODO %?")))]]) end)
  return inbox
end

local function capture(t, text)
  t.answer("t")
  t.command("org-capture")
  assert(name():find("CAPTURE", 1, true), "in the capture buffer: " .. name())
  if text then api.nvim_feedkeys("a" .. text .. "\27", "x", false) end
end

local SRC = "* H\n#+begin_src python\n  x = 1\n#+end_src\n"
local TABLE = "| a | b |\n|---+---|\n| 1 |   |\n| 3 |   |\n#+TBLFM: $2=$1*2\n"

local function agenda_setup(t)
  local path = t.open("close_tasks.org", "* TODO Write report\n* TODO Call Bob\n")
  t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
  t.after(function() t.eval("(setq org-agenda-files nil)") end)
  return path, api.nvim_get_current_buf()
end

local function agenda_done_bob(t, path, file_buf)
  t.answer("t")
  t.command("org-agenda")
  assert(name():find("Org Agenda", 1, true), "agenda shown: " .. name())
  t.cursor(t.find_line("Call Bob"))
  t.answer("d")
  api.nvim_feedkeys("t", "x", false)
  t.eq(api.nvim_buf_get_lines(file_buf, 1, 2, false)[1], "* DONE Call Bob")
  agree(t, path, "after the agenda's t")
end

return {
  -- Emacs: kill-buffer on an untouched CAPTURE buffer leaves "* TODO " in
  -- the (modified) target; a second capture then appends "* TODO Second".
  -- The capture shares the target's modified flag, so :bd needs the !.
  [":bd! on an untouched capture buffer, then a second capture"] = function(t)
    t.open("cap_bd.org", "* A\n")
    local inbox = capture_into(t, "inbox_bd.org")
    capture(t)
    vim.cmd("stopinsert")
    vim.cmd("bdelete!")
    t.eq(t.eval("(seq-some (lambda (b) (string-prefix-p \"CAPTURE-\" (buffer-name b))) (buffer-list))"), "nil",
      "Emacs killed the capture buffer")
    agree(t, inbox, "after :bd")
    t.eq(t.lines(vim.fn.bufnr(inbox)), { "* TODO " }, "template left in the target, as in Emacs")
    capture(t, "Second")
    t.keys("C-c C-c")
    t.eq(t.lines(vim.fn.bufnr(inbox)), { "* TODO ", "* TODO Second" })
    agree(t, inbox, "after the second capture")
  end,

  -- Emacs: kill-buffer of a capture leaves its target modified (they share
  -- one modified flag), so org-save-all-org-buffers writes the target.
  [":bd! on a capture keeps the target modified in Emacs, so org saves it"] = function(t)
    t.open("cap_bdbang.org", "* A\n")
    local inbox = capture_into(t, "inbox_bdbang.org")
    capture(t, "Buy milk")
    vim.cmd("bdelete!")
    agree(t, inbox, "after :bd!")
    local ib = vim.fn.bufnr(inbox)
    t.eq(vim.bo[ib].modified, true, "Neovim's target is modified")
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(inbox)), "t", "Emacs's target is modified")
    t.command("org-save-all-org-buffers")
    t.eq(t.read_file(inbox), table.concat(t.lines(ib), "\n") .. "\n", "org-save-all-org-buffers wrote the target")
  end,

  -- Emacs: the capture buffer's text is the target's, so text typed there
  -- before kill-buffer stays: "* TODO Buy milk".
  [":bd! on a capture keeps the typed text in the target, as kill-buffer does"] = function(t)
    t.open("cap_typed.org", "* A\n")
    local inbox = capture_into(t, "inbox_typed.org")
    capture(t, "Buy milk")
    vim.cmd("bdelete!")
    agree(t, inbox, "after :bd!")
    t.eq(t.lines(vim.fn.bufnr(inbox)), { "* TODO Buy milk" })
  end,

  -- Emacs: C-x 0 on a capture leaves it in progress; a second capture is
  -- CAPTURE-2-..., and the target holds both "First" and "Second".
  [":q on a capture with typed text, then a second capture keeps both"] = function(t)
    t.open("cap_q.org", "* A\n")
    local inbox = capture_into(t, "inbox_q.org")
    capture(t, "First")
    vim.cmd("quit")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "capture window closed")
    capture(t, "Second")
    t.keys("C-c C-c")
    t.eq(t.lines(vim.fn.bufnr(inbox)), { "* TODO First", "* TODO Second" })
    agree(t, inbox)
    t.eq(vim.fn.fnamemodify(name(), ":t"), "cap_q.org", "back in the file")
  end,

  -- Emacs: C-x 1 in the capture window, C-c C-c finishes the capture and
  -- restores the one-window layout on the original file.
  ["<C-w>o in the capture window, then C-c C-c returns to the file"] = function(t)
    t.open("cap_only.org", "* A\n")
    local inbox = capture_into(t, "inbox_only.org")
    capture(t, "Milk")
    t.feed("<C-w>o")
    t.eq(#api.nvim_tabpage_list_wins(0), 1)
    t.keys("C-c C-c")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "cap_only.org", "back in the file")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "one window, as before the capture")
    t.eq(t.lines(vim.fn.bufnr(inbox)), { "* TODO Milk" })
    agree(t, inbox)
  end,

  -- Emacs: kill-buffer on a modified *Org Src* discards the edit; C-c '
  -- again asks nothing and edits "x = 1"; C-c ' writes "z = 3" back.
  [":bd! on a modified src edit buffer, then C-c ' starts afresh"] = function(t)
    local path = t.open("src_bd.org", SRC)
    t.cursor(3, 2)
    t.keys("C-c '")
    assert(name():find("Org Src", 1, true), "in the src buffer")
    api.nvim_buf_set_lines(0, -1, -1, false, { "y = 2" })
    vim.cmd("bdelete!")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "src_bd.org")
    t.eq(t.eval([[(seq-some (lambda (b) (string-prefix-p "*Org Src" (buffer-name b))) (buffer-list))]]), "nil",
      "Emacs killed the edit buffer")
    agree(t, path, "after :bd!")
    t.cursor(3, 2)
    t.keys("C-c '")
    t.eq(t.asked()[1], nil, "no 'return to existing edit buffer' question")
    t.eq(t.lines(), { "x = 1" })
    api.nvim_buf_set_lines(0, -1, -1, false, { "z = 3" })
    t.keys("C-c '")
    t.eq(t.lines(), { "* H", "#+begin_src python", "  x = 1", "  z = 3", "#+end_src" })
    agree(t, path)
  end,

  -- Emacs: a fresh *Org Src* is unmodified, so kill-buffer kills it
  -- without asking and the org text is unchanged.
  [":bd on an untouched src edit buffer closes it"] = function(t)
    local path = t.open("src_untouched.org", SRC)
    t.cursor(3, 2)
    t.keys("C-c '")
    assert(name():find("Org Src", 1, true), "in the src buffer")
    t.eq(t.eval("(buffer-modified-p)"), "nil", "Emacs: unmodified")
    t.eq(vim.bo.modified, false, "Neovim: unmodified")
    vim.cmd("bdelete")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "src_untouched.org")
    agree(t, path)
  end,

  -- Emacs: C-x 0 on a modified *Org Src*, then C-c ' on the block asks
  -- "Return to existing edit buffer"; y shows "x = 1\ny = 2", C-c ' writes it.
  [":close on a modified src edit window, then C-c ' returns to the edit"] = function(t)
    local path = t.open("src_close.org", SRC)
    t.cursor(3, 2)
    t.keys("C-c '")
    api.nvim_buf_set_lines(0, -1, -1, false, { "y = 2" })
    vim.cmd("close")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "src_close.org")
    t.cursor(3, 2)
    t.answer(true)
    t.keys("C-c '")
    t.eq(t.asked()[1].params.prompt, "Return to existing edit buffer ([n] will revert changes)? ")
    t.eq(t.lines(), { "x = 1", "y = 2" }, "the edit made before :close")
    t.keys("C-c '")
    t.eq(t.lines(), { "* H", "#+begin_src python", "  x = 1", "  y = 2", "#+end_src" })
    agree(t, path)
  end,

  -- Emacs: kill-buffer on *Org Note* stores nothing; C-c C-z again and
  -- C-c C-c store the second note only.
  [":bw on *Org Note*, then C-c C-z stores only the next note"] = function(t)
    local path = t.open("note_bw.org", "* Task\nbody\n")
    t.cursor(1)
    t.keys("C-c C-z")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "*Org Note*")
    api.nvim_buf_set_lines(0, -2, -1, false, { "lost" })
    vim.cmd("bwipeout!")
    t.eq(t.lines(), { "* Task", "body" }, "nothing stored")
    agree(t, path, "after :bw")
    t.cursor(1)
    t.keys("C-c C-z")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "*Org Note*", "note buffer again")
    api.nvim_buf_set_lines(0, -2, -1, false, { "kept" })
    t.keys("C-c C-c")
    local lines = t.lines()
    t.eq(#lines, 4, "one note: " .. vim.inspect(lines))
    assert(lines[2]:find("^%- Note taken on %["), lines[2])
    t.eq(lines[3], "  kept")
    agree(t, path)
  end,

  -- Emacs: C-x 0 on *Edit Formulas*, then C-c ' again shows the formulas;
  -- editing to $1*5 and C-c C-c installs it.
  [":q on the formula editor, then C-c ' again installs an edit"] = function(t)
    local path = t.open("fedit_q.org", TABLE)
    t.cursor(3, 6)
    t.keys("C-c '")
    t.eq(t.lines(), { "# Column Formulas", "$2 = $1*2" })
    vim.cmd("quit!")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "fedit_q.org")
    t.cursor(3, 6)
    t.keys("C-c '")
    t.eq(t.lines(), { "# Column Formulas", "$2 = $1*2" }, "editor again")
    api.nvim_buf_set_lines(0, 1, 2, false, { "$2 = $1*5" })
    t.keys("C-c C-c")
    t.eq(vim.fn.fnamemodify(name(), ":t"), "fedit_q.org", "back in the org buffer")
    t.eq(t.lines()[5], "#+TBLFM: $2=$1*5")
    agree(t, path)
  end,

  -- Emacs: org-columns marks the buffer modified (kill-buffer asks, hence
  -- :bd!); visiting the file again shows no columns; C-c C-t t gives "* TODO A".
  [":bd! of a buffer in column view, then :e edits it as text"] = function(t)
    local path = t.open("cols_bd.org", "* A\n:PROPERTIES:\n:Effort: 1:00\n:END:\n* B\n")
    t.cursor(1)
    t.keys("C-c C-x C-c")
    t.eq(mirror.state[api.nvim_get_current_buf()].kind, "menu", "column view takes keys")
    vim.cmd("bdelete!")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    local buf = api.nvim_get_current_buf()
    t.eq(mirror.state[buf].kind, "edit", "no column view after reopening")
    t.eq(t.eval(("(buffer-local-value 'org-columns-current-fmt (get-file-buffer %q))"):format(path)), "nil")
    t.cursor(1)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[1], "* TODO A")
    agree(t, path)
  end,

  -- Emacs: kill-buffer on *Org Agenda*; org-agenda again builds it and t d
  -- marks the task DONE.
  [":bw of the agenda, then the agenda again"] = function(t)
    local path, file_buf = agenda_setup(t)
    t.answer("t")
    t.command("org-agenda")
    vim.cmd("bwipeout")
    t.eq(t.eval([[(get-buffer "*Org Agenda*")]]), "nil", "Emacs killed the agenda")
    t.eq(#api.nvim_tabpage_list_wins(0), 1)
    agenda_done_bob(t, path, file_buf)
  end,

  [":tabclose of the agenda's tab, then the agenda in the first tab"] = function(t)
    local path, file_buf = agenda_setup(t)
    local first = api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    t.after(function() vim.cmd("silent! tabonly!") end)
    t.answer("t")
    t.command("org-agenda")
    vim.cmd("tabclose")
    t.eq(api.nvim_get_current_tabpage(), first)
    agenda_done_bob(t, path, file_buf)
    t.eq(api.nvim_get_current_tabpage(), first, "agenda opened in the first tab")
    t.eq(#api.nvim_tabpage_list_wins(first), 2, "file and agenda windows")
  end,
}
