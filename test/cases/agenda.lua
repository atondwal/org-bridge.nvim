local api = vim.api

local function setup(t)
  local path = t.open("tasks.org", "* TODO Write report\nSCHEDULED: <2026-11-07 Sat>\n* TODO Call Bob\n")
  t.eval(([[(setq org-agenda-files (list %q) org-directory %q)]]):format(path, t.WORK))
  return path, api.nvim_get_current_buf()
end

return {
  ["org-agenda opens the agenda in a split mirror"] = function(t)
    local _, file_buf = setup(t)
    t.answer("t")
    t.command("org-agenda")
    local name = api.nvim_buf_get_name(0)
    assert(name:find("Org Agenda"), "agenda focused: " .. name)
    assert(t.find_line("Call Bob"), "agenda lists tasks:\n" .. table.concat(t.lines(), "\n"))
    t.eq(#vim.fn.win_findbuf(file_buf), 1, "file window kept")
    t.eq(vim.bo.modifiable, false)
  end,

  ["t in the agenda changes the task in the file mirror"] = function(t)
    local _, file_buf = setup(t)
    t.answer("t")
    t.command("org-agenda")
    t.cursor(t.find_line("Call Bob"))
    t.answer("d")
    vim.api.nvim_feedkeys("t", "x", false)
    t.eq(api.nvim_buf_get_lines(file_buf, 2, 3, false)[1], "* DONE Call Bob")
    assert(t.find_line("DONE Call Bob"), "agenda redrawn")
  end,

  ["RET in the agenda shows the task in the agenda's window"] = function(t)
    local _, file_buf = setup(t)
    t.answer("t")
    t.command("org-agenda")
    local agenda = api.nvim_get_current_buf()
    t.cursor(t.find_line("Call Bob"))
    vim.api.nvim_feedkeys("\r", "x", false)
    t.eq(api.nvim_get_current_buf(), file_buf)
    t.eq(api.nvim_win_get_cursor(0)[1], 3)
    t.eq(#vim.fn.win_findbuf(agenda), 0, "agenda replaced, as in Emacs")
  end,

  ["q in the agenda closes its window"] = function(t)
    local _, file_buf = setup(t)
    t.answer("t")
    t.command("org-agenda")
    local agenda = api.nvim_get_current_buf()
    vim.api.nvim_feedkeys("q", "x", false)
    t.eq(#vim.fn.win_findbuf(agenda), 0)
    t.eq(api.nvim_get_current_buf(), file_buf)
  end,

  ["capture files a task through the capture buffer"] = function(t)
    local _, _ = setup(t)
    local inbox = t.file("inbox.org", "")
    t.answer("t")
    t.command("org-capture")
    assert(api.nvim_buf_get_name(0):find("CAPTURE"), "capture buffer focused: " .. api.nvim_buf_get_name(0))
    t.eq(vim.bo.modifiable, true)
    vim.api.nvim_feedkeys("aBuy milk\27", "x", false)
    t.keys("C-c C-c")
    assert(not api.nvim_buf_get_name(0):find("CAPTURE"), "capture closed")
    local ib = vim.fn.bufnr(inbox)
    assert(ib > 0, "inbox has a Neovim buffer")
    t.eq(api.nvim_buf_get_lines(ib, 0, -1, false), { "* TODO Buy milk" })
  end,

  ["capture's %a links to the line of a file Emacs doesn't mirror"] = function(t)
    local inbox = t.file("inbox.org", "")
    local notes = t.open("notes.txt", "first\nsecond line\n")
    t.cursor(2)
    t.eval(([[(setq org-capture-templates '(("a" "Annotated" entry (file %q) "* %%?\n%%a")))]]):format(inbox))
    t.after(function() t.eval([[(setq org-capture-templates '(("t" "Task" entry (file "inbox.org") "* TODO %?")))]]) end)
    t.answer("a")
    t.command("org-capture")
    t.eq(t.lines()[2], "[[file:" .. notes .. "::second line]]")
    t.keys("C-c C-k")
    -- Mirrored later (:set ft=org), Emacs's copy takes edits.
    vim.bo.filetype = "org"
    t.eq(t.eval([[(buffer-local-value 'buffer-read-only (get-file-buffer "]] .. notes .. [["))]]), "nil")
  end,

  ["org-save-all-org-buffers writes files through Neovim"] = function(t)
    local path, buf = setup(t)
    t.cursor(3)
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(vim.bo[buf].modified, true)
    t.command("org-save-all-org-buffers")
    t.eq(vim.bo[buf].modified, false)
    t.eq(vim.fn.readfile(path)[3], "* DONE Call Bob")
  end,

  -- A file Emacs opened for the agenda gets a Neovim buffer; loading it must
  -- not count as a reload, which would move the agenda's markers.
  ["agenda entries still point at their headings after :wa"] = function(t)
    local work = t.open("work.org", "* TODO Write report\nSCHEDULED: <2026-11-07 Sat>\n")
    local home = t.file("home.org", "* TODO Water plants\nSCHEDULED: <2026-11-07 Sat>\n* TODO Pay bill\nSCHEDULED: <2026-11-07 Sat>\n* Notes\n")
    t.eval(([[(setq org-agenda-files (list %q %q))]]):format(work, home))
    t.answer("a")
    t.command("org-agenda")
    -- Changing a home.org entry from the agenda gives home.org a buffer.
    t.cursor(t.find_line("Water plants"))
    t.keys("S-<right>")
    vim.cmd("silent! wall")
    t.cursor(t.find_line("Pay bill"))
    t.answer("d")
    vim.api.nvim_feedkeys("t", "x", false)
    local lines = api.nvim_buf_get_lines(vim.fn.bufnr(home), 0, -1, false)
    t.eq(lines[3], "* DONE Pay bill")
    t.eq(lines[5], "* Notes")
  end,

  ["a second capture gets its own buffer"] = function(t)
    setup(t)
    local inbox = t.file("inbox.org", "")
    for _, item in ipairs({ "First", "Second" }) do
      t.answer("t")
      t.command("org-capture")
      assert(api.nvim_buf_get_name(0):find("CAPTURE"), "capture buffer: " .. api.nvim_buf_get_name(0))
      vim.api.nvim_feedkeys("a" .. item .. "\27", "x", false)
      t.keys("C-c C-c")
      vim.cmd("silent! wall")
    end
    t.eq(vim.fn.readfile(inbox), { "* TODO First", "* TODO Second" })
  end,

  -- Emacs's windows follow Neovim's: Emacs gets Neovim's layout before
  -- each command, so the two never drift apart.
  ["a command in another window leaves the agenda window alone"] = function(t)
    local _, file_buf = setup(t)
    t.answer("t")
    t.command("org-agenda")
    local agenda = api.nvim_get_current_buf()
    api.nvim_set_current_win(vim.fn.win_findbuf(file_buf)[1])
    t.cursor(1)
    t.answer("+1")
    t.keys("C-c C-s")
    t.eq(#vim.fn.win_findbuf(agenda), 1, "agenda window kept")
  end,

  ["TAB in the agenda reuses the other window"] = function(t)
    local path = setup(t)
    local other = t.file("other.org", "* TODO Elsewhere\n")
    t.eval(([[(setq org-agenda-files (list %q %q))]]):format(path, other))
    t.answer("t")
    t.command("org-agenda")
    local agenda = api.nvim_get_current_win()
    t.cursor(t.find_line("Elsewhere"))
    t.feed("<Tab>")
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "two windows")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "other.org")
    assert(api.nvim_win_is_valid(agenda), "agenda window still there")
  end,

  ["a split closed in Neovim stays closed after the next command"] = function(t)
    local _, file_buf = setup(t)
    t.answer("t")
    t.command("org-agenda")
    vim.cmd("only")
    t.eq(#api.nvim_tabpage_list_wins(0), 1)
    t.feed("r") -- rebuild the agenda
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "no window came back")
  end,
}
