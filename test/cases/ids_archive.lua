-- Cross-file structure: org-id links between files (C-c l, the locations
-- file), refile across three agenda files, and archiving to other files.
-- Expected results: emacs -Q --batch -l test/init.el with the same commands.
local api = vim.api
local mirror = require("emacs.mirror")

local TIME = "%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d"

-- Neovim's buffer for path, which must exist.
local function buf_for(path)
  local buf = vim.fn.bufnr(path)
  assert(buf ~= -1, "no Neovim buffer for " .. path)
  return buf
end

local function buf_lines(path) return api.nvim_buf_get_lines(buf_for(path), 0, -1, false) end

-- Emacs's copy of each path equals Neovim's.
local function agree(t, ...)
  mirror.sync()
  for _, path in ipairs({ ... }) do
    t.eq(t.emacs_lines(path), buf_lines(path), vim.fn.fnamemodify(path, ":t") .. ": Emacs agrees")
  end
end

-- org-id state for this test only, with the locations file under t.WORK.
local function ids(t)
  local file = t.WORK .. "/id-locations"
  t.set("org-id-locations-file", ("%q"):format(file))
  t.set("org-id-locations", "nil")
  t.set("org-id-files", "nil")
  return file
end

-- The archive drawer org-archive-subtree adds: lines[at] is ARCHIVE_TIME.
local function drawer(lines, at, src)
  assert(lines[at] and lines[at]:match("^:ARCHIVE_TIME: " .. TIME .. "$"), vim.inspect(lines))
  return { ":PROPERTIES:", lines[at], ":ARCHIVE_FILE: " .. src,
    ":ARCHIVE_CATEGORY: " .. vim.fn.fnamemodify(src, ":t:r"), ":END:" }
end

return {
  -- Emacs: A comes back from disk, unmodified, in the other window, on "* Target".
  ["an id: link stored with C-c l opens its file again after that file is wiped"] = function(t)
    ids(t)
    t.eval([[(global-set-key (kbd "C-c l") #'org-store-link)]])
    t.after(function() t.eval([[(global-unset-key (kbd "C-c l"))]]) end)
    t.set("org-stored-links", "nil")
    t.set("org-id-link-to-org-use-id", "t")
    local a = t.open("ida_a.org", "* Alpha\n* Target\nbody\n")
    t.cursor(2)
    t.keys("C-c l")
    local id = t.lines()[4]:match("^:ID:%s+(%S+)$")
    assert(id, vim.inspect(t.lines()))
    agree(t, a)
    vim.cmd("silent write")
    vim.cmd("bwipeout")
    local b = t.open("ida_b.org", "* B\n")
    t.cursor(1, 2)
    t.feed("o<Esc>")
    t.answer("id:" .. id, "Target")
    t.keys("C-c C-l")
    t.eq(t.lines(), { "* B", "[[id:" .. id .. "][Target]]" })
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), a, "followed into A")
    t.eq(api.nvim_win_get_cursor(0), { 2, 0 }, "on * Target")
    t.eq(vim.bo.modified, false, "A as on disk")
    t.eq(t.lines(), { "* Alpha", "* Target", ":PROPERTIES:", ":ID:       " .. id, ":END:", "body" })
    t.eq(#vim.fn.win_findbuf(buf_for(b)), 1, "B still shown")
    agree(t, a, b)
  end,

  ["C-c C-o on an id: link finds the file through org-id-locations-file"] = function(t)
    local file = ids(t)
    local d = t.file("idloc_t.org", "* One\n* Two\n:PROPERTIES:\n:ID: loc-1\n:END:\n")
    t.file("id-locations", ("((%q \"loc-1\"))\n"):format(d))
    local s = t.open("idloc_s.org", "* S\n[[id:loc-1][two]]\n")
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), d)
    t.eq(api.nvim_win_get_cursor(0), { 2, 0 })
    t.eq(vim.bo.modified, false)
    t.eq(t.read_file(file), ("((%q \"loc-1\"))\n"):format(d), "locations file untouched")
    agree(t, d, s)
  end,

  -- Emacs: the id is found again in the archive file, shown on its heading.
  ["an id: link to an archived entry follows it into the archive file"] = function(t)
    ids(t)
    local src = t.open("aid_src.org", "* Keep\n* Gone\n:PROPERTIES:\n:ID: aid-1\n:END:\ngone body\n")
    local archive = src .. "_archive"
    os.remove(archive)
    t.set("org-agenda-files", ("'(%q)"):format(src))
    t.set("org-archive-location", '"%s_archive::"')
    t.eval(("(org-id-update-id-locations (list %q) t)"):format(src))
    t.cursor(2)
    t.keys("C-c C-x C-a")
    t.eq(t.lines(), { "* Keep" })
    local s = t.open("aid_link.org", "* L\n[[id:aid-1][gone]]\n")
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), archive)
    t.eq(api.nvim_win_get_cursor(0)[1], 7, "on * Gone")
    t.eq(t.lines()[7], "* Gone")
    t.eq(vim.bo.modified, false, "archive saved")
    agree(t, src, archive, s)
  end,

  ["refile across three agenda files offers each file's headings to level 2"] = function(t)
    local a = t.file("r3_a.org", "* Task A\nbody a\n* Keep A\n")
    local b = t.file("r3_b.org", "* Proj B\n** Sub B\n*** Deep B\n")
    local c = t.file("r3_c.org", "* Inbox C\n* Later C\n")
    t.set("org-agenda-files", ("'(%q %q %q)"):format(a, b, c))
    t.set("org-refile-targets", "'((org-agenda-files :maxlevel . 2))")
    t.set("org-refile-history", "nil")
    vim.cmd("silent edit " .. b)
    vim.cmd("silent edit " .. a)
    t.answer("Later C (r3_c.org)")
    t.keys("C-c C-w")
    t.eq(t.asked()[1].params.candidates, { "Task A", "Keep A", "Proj B (r3_b.org)", "Sub B (r3_b.org)",
      "Inbox C (r3_c.org)", "Later C (r3_c.org)" })
    t.eq(t.lines(), { "* Keep A" }, "A")
    t.eq(buf_lines(c), { "* Inbox C", "* Later C", "** Task A", "body a" }, "C")
    t.eq(t.read_file(c), "* Inbox C\n* Later C\n", "C on disk until :write")
    -- From the buffer the refile gave C, on to B.
    vim.cmd("buffer " .. buf_for(c))
    t.cursor(1)
    t.answer("Sub B (r3_b.org)")
    t.keys("C-c C-w")
    t.eq(t.lines(), { "* Later C", "** Task A", "body a" }, "C")
    t.eq(buf_lines(b), { "* Proj B", "** Sub B", "*** Deep B", "*** Inbox C" }, "B")
    t.eq(vim.bo[buf_for(b)].modified, true, "B unsaved, as in Emacs")
    agree(t, a, b, c)
  end,

  -- Emacs saves the archive buffer, the unsaved line included.
  ["C-c C-x C-s into an archive open in Neovim with unsaved edits saves them too"] = function(t)
    local archive = t.open("ao_arch.org", "* Earlier\n")
    api.nvim_buf_set_lines(0, -1, -1, false, { "unsaved note" })
    local src = t.open("ao_src.org", "* Old\nold body\n* New\n")
    t.set("org-archive-location", ("%q"):format(archive .. "::"))
    t.keys("C-c C-x C-s")
    t.eq(t.lines(), { "* New" }, "source")
    local lines = buf_lines(archive)
    local want = vim.list_extend({ "* Earlier", "unsaved note", "", "* Old" }, drawer(lines, 6, src))
    t.eq(lines, vim.list_extend(want, { "old body" }), "archive")
    t.eq(vim.bo[buf_for(archive)].modified, false, "archive saved")
    t.eq(t.read_file(archive), table.concat(lines, "\n") .. "\n", "on disk")
    agree(t, src, archive)
  end,

  ["#+ARCHIVE: with %s archives next to the file under a %s heading"] = function(t)
    local src = t.open("kw_src.org", "#+ARCHIVE: kw_%s_done::* From %s\n* Task\n* Other\n")
    local archive = t.WORK .. "/kw_kw_src.org_done"
    os.remove(archive)
    t.cursor(2)
    t.keys("C-c C-x C-s")
    t.eq(t.lines(), { "#+ARCHIVE: kw_%s_done::* From %s", "* Other" })
    local lines = buf_lines(archive)
    local want = { "#    -*- mode: org -*-", "", "", "Archived entries from file " .. src, "", "",
      "* From kw_src.org", "", "** Task" }
    t.eq(lines, vim.list_extend(want, drawer(lines, 11, src)), "archive")
    t.eq(t.read_file(archive), table.concat(lines, "\n") .. "\n", "on disk")
    agree(t, src, archive)
  end,

  -- Emacs asks y-or-n-p once per DONE child and archives d1 and d2.
  ["C-u C-c C-x C-s asks about each DONE child and archives those"] = function(t)
    local src = t.open("ad_src.org", "* P\n** DONE d1\n** TODO t1\n** DONE d2\n")
    local archive = src .. "_archive"
    os.remove(archive)
    t.set("org-archive-location", '"%s_archive::"')
    t.answer("y", "y")
    t.keys("C-c C-x C-s", 4)
    local prompts = vim.tbl_map(function(q) return q.params.prompt end, t.asked())
    t.eq(#prompts, 2, "two questions: " .. vim.inspect(t.asked()))
    assert(prompts[1]:find("Move subtree to archive? (no open TODO items)", 1, true), vim.inspect(prompts))
    t.eq(t.lines(), { "* P", "** TODO t1" }, "source")
    local heads = vim.tbl_filter(function(l) return l:match("^%*") end, buf_lines(archive))
    t.eq(heads, { "* DONE d1", "* DONE d2" }, "archive headings")
    t.eq(t.read_file(archive), table.concat(buf_lines(archive), "\n") .. "\n", "on disk")
    agree(t, src, archive)
  end,

  -- Emacs leaves the archive modified; org-save-all-org-buffers then writes it.
  ["with org-archive-subtree-save-file-p nil the archive waits for a save"] = function(t)
    local src = t.open("ns_src.org", "* Go\n* Stay\n")
    local archive = t.WORK .. "/ns_arch.org"
    os.remove(archive)
    t.set("org-archive-location", ("%q"):format(archive .. "::"))
    t.eval("(require 'org-archive)")
    t.set("org-archive-subtree-save-file-p", "nil")
    t.keys("C-c C-x C-s")
    local buf = buf_for(archive)
    t.eq(vim.bo[buf].modified, true, "archive unsaved")
    t.eq(vim.fn.filereadable(archive), 0, "nothing on disk yet")
    agree(t, src, archive)
    t.command("org-save-all-org-buffers")
    t.eq(vim.bo[buf].modified, false, "archive saved")
    t.eq(vim.bo.modified, false, "source saved")
    t.eq(t.read_file(archive), table.concat(buf_lines(archive), "\n") .. "\n", "archive on disk")
    t.eq(t.read_file(src), "* Stay\n", "source on disk")
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(archive)), "nil", "Emacs sees the save")
  end,

  -- Interactive Emacs (the batch reference binds noninteractive nil, as the
  -- bridge does) visits the new file writable; save-buffer then asks
  -- "Directory `newdir/' does not exist; create? " and y creates it.
  ["archiving into a missing directory asks to create it, then saves there"] = function(t)
    local src = t.open("nd_src.org", "* Go\n* Stay\n")
    local archive = t.WORK .. "/newdir/nd.org"
    t.set("org-archive-location", ("%q"):format(archive .. "::"))
    t.answer("y")
    t.keys("C-c C-x C-s")
    local q = t.asked()[1]
    assert(q and q.params.prompt:find("does not exist; create?", 1, true), vim.inspect(t.asked()))
    t.eq(t.lines(), { "* Stay" }, "source")
    t.eq(t.read_file(archive), table.concat(buf_lines(archive), "\n") .. "\n", "archive on disk")
    agree(t, src, archive)
  end,

  ["C-c C-x A on a top-level heading makes a folded top-level Archive sibling"] = function(t)
    local src = t.open("sib_top.org", "* One\none body\n* Two\n")
    t.keys("C-c C-x A")
    local lines = t.lines()
    assert(lines[5] and lines[5]:match("^:ARCHIVE_TIME: " .. TIME .. "$"), vim.inspect(lines))
    t.eq(lines, { "* Two", t.aligned("* Archive", ":ARCHIVE:"), "** One", ":PROPERTIES:", lines[5], ":END:",
      "one body" }, "text")
    t.eq(api.nvim_win_get_cursor(0)[1], 1, "point on * Two")
    t.eq(t.folds(), { "2-7" }, "Archive folded")
    agree(t, src)
  end,
}
