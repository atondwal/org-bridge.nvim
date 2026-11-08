local api = vim.api

local function doc(t) return t.DOC .. "** B1\n" end

-- Also clears refile history, whose newest entry would be the prompt's default.
local function targets(t, extra)
  t.eval(([[(setq org-refile-targets '((nil :maxlevel . 2) %s) org-refile-use-outline-path nil
                  org-refile-history nil)]])
    :format(extra or ""))
end

local function buf_for(path)
  local buf = vim.fn.bufnr(path)
  assert(buf ~= -1, "no Neovim buffer for " .. path)
  return buf
end

return {
  ["C-c C-w offers the headings and moves the subtree under the target"] = function(t)
    t.open("same.org", doc(t))
    targets(t)
    t.answer("B")
    t.keys("C-c C-w")
    local q = t.asked()[1]
    t.eq(q.method, "completing_read")
    t.eq(q.params.prompt, 'Refile subtree "A" to: ')
    t.eq(q.params.candidates, { "A", "A1", "B", "B1" })
    t.eq(q.params.require_match, true)
    t.eq(t.lines(), { "* B", "body b", "** B1", "** A", "body a", "*** A1", "text" })
    t.eq(api.nvim_win_get_cursor(0)[1], 1, "point stays where the subtree was")
  end,

  ["refiling a level-2 heading keeps it a child of the new parent"] = function(t)
    t.open("child.org", doc(t))
    targets(t)
    t.cursor(3)
    t.answer("B")
    t.keys("C-c C-w")
    t.eq(t.lines(), { "* A", "body a", "* B", "body b", "** B1", "** A1", "text" })
    t.eq(api.nvim_win_get_cursor(0)[1], 3)
  end,

  ["Escape at the refile prompt changes nothing"] = function(t)
    t.open("cancel.org", doc(t))
    targets(t)
    t.answer(t.QUIT)
    t.keys("C-c C-w")
    t.eq(t.lines(), vim.split(doc(t), "\n", { plain = true, trimempty = true }))
  end,

  ["refile with outline paths accepts a full path"] = function(t)
    t.open("olpath.org", doc(t))
    targets(t)
    t.set("org-refile-use-outline-path", "t")
    t.answer("B/B1")
    t.keys("C-c C-w")
    t.eq(t.lines(), { "* B", "body b", "** B1", "*** A", "body a", "**** A1", "text" })
  end,

  ["refile into a file not open in Neovim gives it a saveable buffer"] = function(t)
    local dest = t.file("dest.org", "* Inbox\n* Projects\n** P1\n")
    t.open("src.org", "* Move me\nmoved body\n* Stay\n")
    targets(t, ([[(%q :maxlevel . 2)]]):format(dest))
    t.answer("Projects (dest.org)")
    t.keys("C-c C-w")
    t.eq(t.asked()[1].params.candidates,
      { "Move me", "Stay", "Inbox (dest.org)", "Projects (dest.org)", "P1 (dest.org)" })
    t.eq(t.lines(), { "* Stay" }, "source")
    local buf = buf_for(dest)
    local want = { "* Inbox", "* Projects", "** P1", "** Move me", "moved body" }
    t.eq(api.nvim_buf_get_lines(buf, 0, -1, false), want, "dest mirror")
    t.eq(vim.bo[buf].modified, true, "dest unsaved, as in Emacs")
    t.eq(t.read_file(dest), "* Inbox\n* Projects\n** P1\n", "disk untouched before :write")
    api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
    t.eq(t.read_file(dest), table.concat(want, "\n") .. "\n", "disk after :write")
    t.eq(t.eval([[(buffer-modified-p (get-file-buffer "]] .. dest .. [["))]]), "nil",
      "Emacs sees the save")
  end,

  ["refile into a file already open in Neovim updates its buffer"] = function(t)
    local dest = t.open("open-dest.org", "* Inbox\n")
    local dest_buf = api.nvim_get_current_buf()
    t.open("open-src.org", "* Task\nbody\n* Other\n")
    targets(t, ([[(%q :maxlevel . 1)]]):format(dest))
    t.answer("Inbox (open-dest.org)")
    t.keys("C-c C-w")
    t.eq(t.lines(), { "* Other" })
    t.eq(api.nvim_buf_get_lines(dest_buf, 0, -1, false), { "* Inbox", "** Task", "body" })
    t.eq(vim.bo[dest_buf].modified, true)
  end,

  ["C-u C-c C-w jumps to a target in another file"] = function(t)
    local dest = t.file("jump.org", "* Inbox\n* Projects\n** P1\n")
    t.open("jump-src.org", "* Here\n")
    targets(t, ([[(%q :maxlevel . 2)]]):format(dest))
    t.answer("P1 (jump.org)")
    t.keys("C-c C-w", 4)
    t.eq(t.asked()[1].params.prompt, "Goto: ")
    t.eq(api.nvim_buf_get_name(0), dest)
    t.eq(api.nvim_win_get_cursor(0)[1], 3)
    t.eq(vim.bo.modified, false)
  end,
  ["a file Emacs refiled into keeps the same text in Emacs and Neovim"] = function(t)
    local dest = t.file("sync-dest.org", "* Inbox\n* Projects\n")
    t.open("sync-src.org", "* Move me\n* Stay\n")
    targets(t, ([[(%q :maxlevel . 1)]]):format(dest))
    t.answer("Projects (sync-dest.org)")
    t.keys("C-c C-w")
    local want = "* Inbox\n* Projects\n** Move me\n"
    t.eq(t.emacs_text(dest), want, "Emacs's copy")
    vim.cmd("buffer " .. buf_for(dest))
    t.cursor(3)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* Inbox", "* Projects", "** TODO Move me" })
  end,

  ["refile that saves (org-save-all-org-buffers after refile) writes the target file"] = function(t)
    local dest = t.file("autosave-dest.org", "* Inbox\n")
    t.open("autosave-src.org", "* Task\n* Other\n")
    targets(t, ([[(%q :maxlevel . 1)]]):format(dest))
    t.eval("(advice-add 'org-refile :after #'org-save-all-org-buffers)")
    t.after(function() t.eval("(advice-remove 'org-refile #'org-save-all-org-buffers)") end)
    t.answer("Inbox (autosave-dest.org)")
    t.keys("C-c C-w")
    t.eq(t.read_file(dest), "* Inbox\n** Task\n")
    t.eq(t.emacs_text(dest), "* Inbox\n** Task\n", "Emacs's copy")
  end,
}
