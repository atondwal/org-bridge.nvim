-- Files changing under the bridge: reloads, other programs' writes, :r,
-- :w copies and appends, :earlier/:later, a formatter in BufWritePre, and
-- Emacs killed between commands. After each, both sides agree.
local api = vim.api
local uv = vim.loop
local rpc = require("emacs.rpc")
local mirror = require("emacs.mirror")

local DOC_LINES = { "* A", "body a", "** A1", "text", "* B", "body b" }

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- Write `content` to path as another program would, with a newer mtime.
local function write_behind(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  local later = os.time() + 5
  uv.fs_utime(path, later, later)
end

local function todo_at(t, line)
  t.cursor(line)
  t.answer("t")
  t.keys("C-c C-t")
end

local function emacs_modified(t, path)
  return t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(path))
end

-- The bridge's Emacs job: the job channel running `emacs --batch`.
local function emacs_job()
  for _, chan in ipairs(api.nvim_list_chans()) do
    if chan.argv and vim.tbl_contains(chan.argv, "--batch") then return chan.id end
  end
end

-- Typed keys each end an undo step; a script's calls don't. Setting
-- 'undolevels' ends one (:h undo-break).
local function close_undo_step() vim.o.undolevels = vim.o.undolevels end

local function wait_dead()
  assert(vim.wait(5000, function() return not rpc.running() end, 10), "Emacs still running")
end

return {
  [":e! drops synced and unsynced Neovim edits on both sides"] = function(t)
    local path = t.open("e_bang.org", t.DOC)
    api.nvim_buf_set_lines(0, 0, 1, false, { "* A synced" })
    mirror.sync()
    api.nvim_buf_set_lines(0, 4, 5, false, { "* B unsynced" })
    vim.cmd("edit!")
    t.eq(t.lines(), DOC_LINES, "Neovim reread the file")
    agree(t, path)
    t.eq(emacs_modified(t, path), "nil", "Emacs unmodified")
    todo_at(t, 5)
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path, "after C-c C-t")
  end,

  [":e of an unmodified buffer whose file changed on disk reloads both sides"] = function(t)
    local path = t.open("e_plain.org", t.DOC)
    t.keys("TAB")
    write_behind(path, "* X\nbody x\n* Y\n")
    vim.cmd("silent edit")
    t.eq(t.lines(), { "* X", "body x", "* Y" })
    agree(t, path)
    t.eq(t.folds(), {}, "the old fold is gone")
    todo_at(t, 3)
    t.eq(t.lines()[3], "* TODO Y")
    agree(t, path, "after C-c C-t")
  end,

  -- A modified buffer whose file changed: FileChangedShell picks reload,
  -- as a user answering "Load File" to W12 does.
  [":checktime reload of a modified buffer gives Emacs the disk text"] = function(t)
    local path = t.open("w12.org", t.DOC)
    api.nvim_buf_set_lines(0, 1, 2, false, { "body a, unsaved" })
    mirror.sync()
    local group = api.nvim_create_augroup("probe_fcs", {})
    t.after(function() api.nvim_del_augroup_by_id(group) end)
    api.nvim_create_autocmd("FileChangedShell", { group = group, callback = function() vim.v.fcs_choice = "reload" end })
    write_behind(path, "* X\n* Y\n")
    vim.cmd("checktime")
    t.eq(t.lines(), { "* X", "* Y" }, "Neovim reloaded")
    agree(t, path)
    t.eq(emacs_modified(t, path), "nil", "Emacs unmodified")
    todo_at(t, 2)
    t.eq(t.lines(), { "* X", "* TODO Y" })
    agree(t, path, "after C-c C-t")
  end,

  [":r other.txt inserts its lines on both sides"] = function(t)
    local path = t.open("read_in.org", t.DOC)
    local other = t.file("read_in.txt", "* Inserted\ninserted body\n")
    t.cursor(2)
    vim.cmd("silent read " .. vim.fn.fnameescape(other))
    t.eq(t.lines(), { "* A", "body a", "* Inserted", "inserted body", "** A1", "text", "* B", "body b" })
    agree(t, path)
    todo_at(t, 3)
    t.eq(t.lines()[3], "* TODO Inserted")
    agree(t, path, "after C-c C-t")
  end,

  -- Emacs: C-x C-s after C-c C-t writes only the visited file.
  [":w >> other.org appends a copy; Emacs keeps its own file"] = function(t)
    local path = t.open("append_src.org", t.DOC)
    local other = t.file("append_dst.org", "* Existing\n")
    todo_at(t, 5)
    vim.cmd("silent write >> " .. vim.fn.fnameescape(other))
    t.eq(t.read_file(other), "* Existing\n* A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "appended")
    t.eq(vim.bo.modified, true, "the buffer is still unsaved")
    t.eq(emacs_modified(t, path), "t", "Emacs still unsaved")
    t.eq(t.eval(("(get-file-buffer %q)"):format(other)), "nil", "Emacs doesn't visit the copy")
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "own file saved")
    agree(t, path)
  end,

  [":w other.org writes a copy; Emacs keeps visiting the original"] = function(t)
    local path = t.open("copy_src.org", t.DOC)
    local copy = t.WORK .. "/copy_dst.org"
    todo_at(t, 5)
    vim.cmd("silent write " .. vim.fn.fnameescape(copy))
    t.eq(t.read_file(copy), "* A\nbody a\n** A1\ntext\n* TODO B\nbody b\n", "copy")
    t.eq(t.read_file(path), t.DOC, "original untouched")
    t.eq(t.eval(("(buffer-file-name (nvb--buffer %d))"):format(mirror.id(api.nvim_get_current_buf()))),
      ("%q"):format(path), "Emacs visits the original")
    t.eq(emacs_modified(t, path), "t", "Emacs still unsaved")
    t.eq(vim.bo.modified, true, "Neovim still unsaved")
    agree(t, path)
  end,

  [":earlier and :later across Neovim edits and Emacs commands"] = function(t)
    local path = t.open("earlier.org", t.DOC)
    t.feed("2GA, edited<Esc>")
    mirror.sync()
    close_undo_step()
    todo_at(t, 5)
    close_undo_step()
    t.cursor(3)
    t.keys("M-<right>")
    t.eq(t.lines(), { "* A", "body a, edited", "*** A1", "text", "* TODO B", "body b" }, "three changes")
    vim.cmd("silent earlier 2")
    t.eq(t.lines(), { "* A", "body a, edited", "** A1", "text", "* B", "body b" }, ":earlier 2")
    agree(t, path, ":earlier 2")
    vim.cmd("silent later 1")
    t.eq(t.lines()[5], "* TODO B", ":later 1")
    agree(t, path, ":later 1")
    vim.cmd("silent earlier 1f")
    t.eq(t.lines(), DOC_LINES, ":earlier 1f")
    agree(t, path, ":earlier 1f")
    todo_at(t, 1)
    t.eq(t.lines()[1], "* TODO A")
    agree(t, path, "after C-c C-t")
  end,

  [":bwipeout, a change on disk, then reopening shows the disk text"] = function(t)
    local path = t.open("bw_disk.org", t.DOC)
    todo_at(t, 5)
    vim.cmd("bwipeout!")
    t.eq(t.eval(("(get-file-buffer %q)"):format(path)), "nil", "Emacs killed its buffer")
    write_behind(path, "* X\n* Y\n")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    t.eq(t.lines(), { "* X", "* Y" })
    agree(t, path)
    todo_at(t, 1)
    t.eq(t.lines()[1], "* TODO X")
    agree(t, path, "after C-c C-t")
  end,

  -- git checkout: a new file renamed over the old one (a new inode).
  ["a file replaced by rename, then :e, then C-x C-s writes the new file"] = function(t)
    local path = t.open("renamed_over.org", t.DOC)
    local tmp = t.file("renamed_over.org.tmp", "* X\n* Y\n")
    local later = os.time() + 5
    uv.fs_utime(tmp, later, later)
    assert(uv.fs_rename(tmp, path))
    vim.cmd("silent edit")
    t.eq(t.lines(), { "* X", "* Y" })
    agree(t, path)
    todo_at(t, 2)
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* X\n* TODO Y\n", "file on disk")
    t.eq(vim.bo.modified, false, "Neovim saved")
    t.eq(emacs_modified(t, path), "nil", "Emacs saved")
    agree(t, path)
  end,

  -- A formatter: BufWritePre upcases "body" lines.
  [":w with a BufWritePre formatter leaves both sides on the formatted text"] = function(t)
    local path = t.open("formatter_w.org", t.DOC)
    local group = api.nvim_create_augroup("probe_fmt", {})
    t.after(function() api.nvim_del_augroup_by_id(group) end)
    api.nvim_create_autocmd("BufWritePre", { group = group, buffer = 0, command = [[silent! %s/^body/BODY/]] })
    todo_at(t, 5)
    vim.cmd("silent write")
    local want = { "* A", "BODY a", "** A1", "text", "* TODO B", "BODY b" }
    t.eq(t.lines(), want)
    t.eq(t.read_file(path), table.concat(want, "\n") .. "\n", "file on disk")
    agree(t, path)
    t.eq(emacs_modified(t, path), "nil", "Emacs saved")
    todo_at(t, 1)
    t.eq(t.lines()[1], "* TODO A")
    agree(t, path, "after C-c C-t")
  end,

  ["C-x C-s with a BufWritePre formatter leaves both sides on the formatted text"] = function(t)
    local path = t.open("formatter_cxcs.org", t.DOC)
    local group = api.nvim_create_augroup("probe_fmt2", {})
    t.after(function() api.nvim_del_augroup_by_id(group) end)
    api.nvim_create_autocmd("BufWritePre", { group = group, buffer = 0, command = [[silent! %s/^body/BODY/]] })
    todo_at(t, 5)
    t.keys("C-x C-s")
    local want = { "* A", "BODY a", "** A1", "text", "* TODO B", "BODY b" }
    t.eq(t.lines(), want)
    t.eq(t.read_file(path), table.concat(want, "\n") .. "\n", "file on disk")
    agree(t, path)
    t.eq(emacs_modified(t, path), "nil", "Emacs saved")
  end,

  ["jobstop of Emacs, then an org key: text, unsynced edit and folds come back"] = function(t)
    local path = t.open("jobstop.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" }, "folded before")
    api.nvim_buf_set_lines(0, 5, 6, false, { "body b, unsynced" })
    vim.fn.jobstop((assert(emacs_job(), "Emacs job")))
    wait_dead()
    todo_at(t, 5)
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* TODO B", "body b, unsynced" })
    agree(t, path)
    t.eq(t.folds(), { "1-4" }, "A stays folded")
  end,

  ["SIGTERM to Emacs's pid, then an org key: text and folds come back"] = function(t)
    local path = t.open("sigterm.org", t.DOC)
    t.cursor(5)
    t.keys("TAB")
    t.cursor(1)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4", "5-6" }, "folded before")
    uv.kill(vim.fn.jobpid((assert(emacs_job(), "Emacs job"))), "sigterm")
    wait_dead()
    todo_at(t, 5)
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
    t.eq(t.folds(), { "1-4", "5-6" }, "both stay folded")
  end,
}
