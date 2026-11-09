-- Buffer lifecycle vs Emacs's copy: :bd/:bw, :e!, files changed on disk,
-- :saveas/:file, windows and tabpages, :wa in a src edit, unnamed org buffers.
-- Expected text: emacs -Q --batch -l test/init.el; else both sides agree.
local api = vim.api
local mirror = require("emacs.mirror")

local DOC_LINES = { "* A", "body a", "** A1", "text", "* B", "body b" }

local function agree(t, buffer, what)
  t.eq(t.emacs_lines(buffer), t.lines(), (what or "") .. " Emacs agrees")
end

local function lines_of(s) return vim.split(s, "\n", { plain = true, trimempty = true }) end

-- Write `content` to path as another program would, with a newer mtime.
local function write_behind(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  local later = os.time() + 5
  vim.loop.fs_utime(path, later, later)
end

-- :enew with "* A\n* B" in org-mode, no file; returns the buffer.
local function new_org_buffer(t)
  vim.cmd("enew")
  api.nvim_buf_set_lines(0, 0, -1, false, { "* A", "* B" })
  vim.cmd("setf org")
  local buf = api.nvim_get_current_buf()
  assert(mirror.id(buf), "attached")
  return buf
end

local function todo_b(t)
  t.cursor(5)
  t.answer("t")
  t.keys("C-c C-t")
end

return {
  [":bd! of an edited buffer then :e shows the disk text in both"] = function(t)
    local path = t.open("bd_edited.org", t.DOC)
    api.nvim_buf_set_lines(0, 4, 5, false, { "* Unsaved" })
    mirror.sync()
    vim.cmd("bdelete!")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    t.eq(t.lines(), DOC_LINES, "Neovim reread the file")
    agree(t, path)
    todo_b(t)
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path, "after C-c C-t")
  end,

  [":bw of an Emacs-edited, saved buffer then reopening keeps the change"] = function(t)
    local path = t.open("bw_saved.org", t.DOC)
    todo_b(t)
    vim.cmd("silent write")
    vim.cmd("bwipeout")
    t.eq(t.eval(("(get-file-buffer %q)"):format(path)), "nil", "Emacs killed its buffer")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
    t.cursor(5)
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* DONE B")
    agree(t, path, "after a second C-c C-t")
  end,

  [":e! after an Emacs command reverts both sides to the file"] = function(t)
    local path = t.open("reload_cmd.org", t.DOC)
    todo_b(t)
    vim.cmd("edit!")
    t.eq(t.lines(), DOC_LINES, "Neovim")
    mirror.sync()
    agree(t, path)
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(path)), "nil", "Emacs unmodified")
    todo_b(t)
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path, "after C-c C-t")
  end,

  -- Emacs: revert-buffer after the file changes on disk, then C-c C-t t on
  -- line 2 gives "* X\n* TODO Y\n", no question asked; C-x C-s writes it.
  [":checktime reload of a file changed on disk, then an Emacs command and save"] = function(t)
    local path = t.open("ondisk.org", t.DOC)
    vim.o.autoread = true
    t.after(function() vim.o.autoread = false end)
    write_behind(path, "* X\n* Y\n")
    vim.cmd("checktime")
    t.eq(t.lines(), { "* X", "* Y" }, "Neovim reloaded")
    t.cursor(2)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* X", "* TODO Y" })
    agree(t, path)
    t.eq(t.asked()[2], nil, "only the TODO key was asked for")
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* X\n* TODO Y\n", "file on disk")
    t.eq(vim.bo.modified, false)
  end,

  -- Emacs: write-file new.org, C-c C-t t, C-x C-s: new.org has TODO B and
  -- the old file is untouched.
  [":saveas, then an Emacs command and an Emacs save, write the new file"] = function(t)
    local old = t.open("saveas_old.org", t.DOC)
    local new = t.WORK .. "/saveas_new.org"
    vim.cmd("silent saveas " .. vim.fn.fnameescape(new))
    todo_b(t)
    t.keys("C-x C-s")
    t.eq(t.read_file(new), "* A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "new file")
    t.eq(t.read_file(old), t.DOC, "old file")
    t.eq(vim.bo.modified, false, "Neovim saved")
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(new)), "nil", "Emacs saved")
  end,

  -- Emacs: set-visited-file-name renamed.org leaves the buffer modified;
  -- C-c C-t t then C-x C-s writes renamed.org, the old file is untouched.
  [":file rename, then an Emacs command and an Emacs save, write the new name"] = function(t)
    local old = t.open("file_old.org", t.DOC)
    local new = t.WORK .. "/file_renamed.org"
    vim.cmd("silent file " .. vim.fn.fnameescape(new))
    t.eq(t.eval(("(buffer-file-name (nvb--buffer %d))"):format(mirror.id(api.nvim_get_current_buf()))), ("%q"):format(new),
      "Emacs visits the new name")
    todo_b(t)
    t.keys("C-x C-s")
    t.eq(t.read_file(new), "* A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "new file")
    t.eq(t.read_file(old), t.DOC, "old file")
  end,

  -- Emacs: two windows on a buffer; C-c C-t t in the lower one (point on
  -- * B) changes B, then C-c C-t n in the upper one (point at bob) changes A.
  ["two windows on one buffer: each command acts at its own window's cursor"] = function(t)
    local path = t.open("twowin.org", t.DOC)
    local top = api.nvim_get_current_win()
    t.cursor(1)
    vim.cmd("belowright split")
    local bottom = api.nvim_get_current_win()
    todo_b(t)
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* TODO B", "body b" }, "lower window")
    t.eq(api.nvim_win_get_cursor(top)[1], 1, "upper window's cursor stays")
    api.nvim_set_current_win(top)
    t.answer("n")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* NEXT A", "body a", "** A1", "text", "* TODO B", "body b" }, "upper window")
    t.eq(api.nvim_win_get_cursor(bottom)[1], 5, "lower window's cursor stays")
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "both windows kept")
    agree(t, path)
  end,

  ["the agenda in a second tabpage leaves the first tabpage's windows alone"] = function(t)
    local path = t.open("tabs.org", "* TODO Write report\n* TODO Call Bob\n")
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    t.after(function() t.eval("(setq org-agenda-files nil)") end)
    local file_buf = api.nvim_get_current_buf()
    vim.cmd("split")
    local first_tab = api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    t.after(function() vim.cmd("silent! tabonly!") end)
    t.answer("t")
    t.command("org-agenda")
    t.eq(api.nvim_get_current_tabpage() ~= first_tab, true, "agenda in the second tabpage")
    t.cursor(t.find_line("Call Bob"))
    t.answer("d")
    api.nvim_feedkeys("t", "x", false)
    t.eq(api.nvim_buf_get_lines(file_buf, 1, 2, false)[1], "* DONE Call Bob")
    t.eq(t.emacs_lines(path), t.lines(file_buf), "Emacs agrees")
    local wins = api.nvim_tabpage_list_wins(first_tab)
    t.eq(#wins, 2, "first tabpage keeps both windows")
    for _, w in ipairs(wins) do t.eq(api.nvim_win_get_buf(w), file_buf, "first tabpage shows the file") end
  end,

  -- Emacs: in *Org Src*, C-x C-s writes the block back and saves the org file.
  [":wa with a modified src edit buffer writes the edit into the org file"] = function(t)
    local path = t.open("src_wa.org", "* H\n#+begin_src python\n  x = 1\n#+end_src\n")
    t.cursor(3, 2)
    t.keys("C-c '")
    assert(api.nvim_buf_get_name(0):find("Org Src", 1, true), "in the src buffer")
    api.nvim_buf_set_lines(0, -1, -1, false, { "y = 2" })
    vim.cmd("silent wall")
    t.eq(t.read_file(path), "* H\n#+begin_src python\n  x = 1\n  y = 2\n#+end_src\n", "file on disk")
    t.eq(vim.bo.modified, false, "src buffer saved")
  end,

  -- Emacs: in an org-mode buffer with no file, C-c C-t t on line 1 gives
  -- "* TODO A"; after write-file, C-c C-t t on line 2 and C-x C-s write
  -- "* TODO A\n* TODO B\n".
  [":enew + setf org mirrors an unnamed buffer; after :w Emacs saves to the file"] = function(t)
    local buf = new_org_buffer(t)
    t.cursor(1)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* TODO A", "* B" })
    local name = t.eval(("(buffer-name (nvb--buffer %d))"):format(mirror.id(buf)))
    agree(t, vim.json.decode(name))
    local path = t.WORK .. "/enew_saved.org"
    vim.cmd("silent write " .. vim.fn.fnameescape(path))
    t.cursor(2)
    t.answer("t")
    t.keys("C-c C-t")
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* TODO A\n* TODO B\n", "Emacs's save wrote the file")
    agree(t, path)
  end,

  -- Emacs: write-file keeps the buffer and its undo list, so C-_ after it
  -- undoes the C-c C-t from before: "* A\n* B\n".
  ["C-_ after :w of an unnamed org buffer undoes the command before it"] = function(t)
    new_org_buffer(t)
    t.cursor(1)
    t.answer("t")
    t.keys("C-c C-t")
    vim.cmd("silent write " .. vim.fn.fnameescape(t.WORK .. "/enew_undo.org"))
    t.keys("C-_")
    t.eq(t.lines(), { "* A", "* B" })
  end,

  -- Emacs: the agenda's t d marks the task DONE in its file buffer.
  ["with 'nohidden', a file unloaded by :e gets the agenda's change"] = function(t)
    vim.o.hidden = false
    t.after(function() vim.o.hidden = true end)
    local path = t.open("hidden_a.org", "* TODO Call Bob\n")
    local file_buf = api.nvim_get_current_buf()
    t.eval(([[(setq org-agenda-files (list %q))]]):format(path))
    t.after(function() t.eval("(setq org-agenda-files nil)") end)
    t.open("hidden_b.org", "* B\n")
    t.eq(api.nvim_buf_is_loaded(file_buf), false, "unloaded")
    t.answer("t")
    t.command("org-agenda")
    t.cursor(t.find_line("Call Bob"))
    t.answer("d")
    api.nvim_feedkeys("t", "x", false)
    vim.cmd("only")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    t.eq(t.lines(), { "* DONE Call Bob" })
    agree(t, path)
  end,

  -- As vc-git stages a resolved conflict on save. Emacs: C-x C-s runs
  -- after-save-hook once the file is written; a hook's error is shown
  -- after the save, the buffer unmodified.
  [":w and C-x C-s run after-save-hook; a failing hook leaves the file saved"] = function(t)
    local path = t.open("after_save.org", "* A\n")
    t.eval([[(progn (setq nvb-test-saves 0)
      (add-hook 'after-save-hook (lambda () (cl-incf nvb-test-saves) (setq nvb-test-saved (buffer-substring-no-properties 1 (point-max)))) nil t))]])
    t.cursor(1)
    t.feed("A!<Esc>")
    vim.cmd("silent write")
    t.eq(t.eval("nvb-test-saved"), '"* A!\n"', "the hook sees the text written")
    t.answer("t")
    t.keys("C-c C-t")
    t.keys("C-x C-s")
    t.eq(t.eval("nvb-test-saves"), "2")
    t.eval([[(add-hook 'after-save-hook (lambda () (error "Hook failed")) nil t)]])
    t.feed("A!<Esc>")
    vim.cmd("messages clear")
    -- An error message, which vim.cmd raises.
    local _, err = pcall(vim.cmd, "silent write")
    local shown = tostring(err) .. vim.fn.execute("messages")
    assert(shown:find("Emacs: Hook failed", 1, true), shown)
    t.eq(t.read_file(path), "* TODO A!!\n")
    t.eq({ vim.bo.modified, t.eval("(buffer-modified-p)") }, { false, "nil" })
  end,
}
