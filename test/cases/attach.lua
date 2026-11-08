-- org-attach (C-c C-a): the dispatcher, attaching by copy/move/link, the
-- ATTACH tag and :ID:, delete, sync, open, new, :DIR: and attachment: links.
-- Expected: emacs -Q --batch -l test/init.el, prompts stubbed with cl-letf.
local api = vim.api
local mirror = require("emacs.mirror")
local uv = vim.uv or vim.loop

local function agree(t, path)
  mirror.sync()
  t.eq(t.emacs_lines(path), api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false), "Emacs agrees")
end

-- Attachment folders go under t.WORK; files open in Emacs, never in an
-- external program.
local function setup(t)
  t.eval("(require 'org-attach)")
  local dir = t.WORK .. "/data/"
  t.set("org-attach-id-dir", ("%q"):format(dir))
  t.set("org-file-apps", "'((t . emacs))")
  return dir
end

local function exists(path) return uv.fs_stat(path) ~= nil end

local function last_asked(t) return t.asked()[#t.asked()].params end

return {
  [":ID: given: a copies into the id's folder and tags the heading"] = function(t)
    local dir = setup(t)
    local path = t.open("att_copy.org", "* Task\n:PROPERTIES:\n:ID: ab1234\n:END:\nbody\n")
    local src = t.file("att_src.txt", "hello\n")
    t.answer("a", src)
    t.keys("C-c C-a")
    t.eq(last_asked(t).prompt, "File to keep as an attachment: ")
    t.eq(t.lines(), { t.aligned("* Task", ":ATTACH:"), ":PROPERTIES:", ":ID: ab1234", ":END:", "body" })
    agree(t, path)
    t.eq(t.read_file(dir .. "ab/1234/att_src.txt"), "hello\n", "copied")
    assert(exists(src), "source kept")
  end,

  ["c without an ID adds a uuid :ID: drawer; u undoes it and the tag at once"] = function(t)
    local dir = setup(t)
    local path = t.open("att_noid.org", "* Fresh\nbody\n* Other\n")
    t.cursor(2)
    t.answer("c", t.file("att_src2.txt", "two\n"))
    t.keys("C-c C-a")
    local lines = t.lines()
    t.eq({ lines[1], lines[2], lines[4], lines[5], lines[6], #lines },
      { t.aligned("* Fresh", ":ATTACH:"), ":PROPERTIES:", ":END:", "body", "* Other", 6 })
    local id = lines[3]:match("^:ID:%s+(%x+%-[%x-]+)$")
    assert(id, "uuid id: " .. lines[3])
    agree(t, path)
    t.eq(t.read_file(dir .. id:sub(1, 2) .. "/" .. id:sub(3) .. "/att_src2.txt"), "two\n", "copied by id")
    t.feed("u")
    t.eq(t.lines(), { "* Fresh", "body", "* Other" })
    agree(t, path)
  end,

  ["m moves, l hard-links, y symlinks; D removes the folder and only ATTACH"] = function(t)
    local dir = setup(t)
    local path = t.open("att_mv.org", "* Mv :old:\n:PROPERTIES:\n:ID: cd5678\n:END:\n")
    local folder = dir .. "cd/5678/"
    local moved = t.file("att_mv.txt", "m\n")
    t.answer("m", moved)
    t.keys("C-c C-a")
    assert(not exists(moved), "source moved away")
    t.eq(t.read_file(folder .. "att_mv.txt"), "m\n", "moved")
    t.answer("l", t.file("att_ln.txt", "l\n"))
    t.keys("C-c C-a")
    t.eq(uv.fs_stat(folder .. "att_ln.txt").nlink, 2, "hard link")
    local target = t.file("att_sym.txt", "s\n")
    t.answer("y", target)
    t.keys("C-c C-a")
    t.eq(uv.fs_readlink(folder .. "att_sym.txt"), target, "symlink")
    t.eq(t.lines()[1], t.aligned("* Mv", ":old:ATTACH:"))
    agree(t, path)
    t.answer("D", true, true)
    t.keys("C-c C-a")
    assert(not exists(folder), "folder removed")
    t.eq(t.lines(), { t.aligned("* Mv", ":old:"), ":PROPERTIES:", ":ID: cd5678", ":END:" })
    agree(t, path)
  end,

  ["d deletes one attachment and keeps the tag; z then drops tag and empty folder"] = function(t)
    local dir = setup(t)
    local path = t.open("att_del.org", "* Del\n:PROPERTIES:\n:ID: ef9012\n:END:\n")
    t.answer("a", t.file("att_d1.txt", "1\n"))
    t.keys("C-c C-a")
    t.answer("d", "att_d1.txt")
    t.keys("C-c C-a")
    t.eq(last_asked(t).candidates, { "att_d1.txt" }, "delete candidates")
    assert(exists(dir .. "ef/9012") and not exists(dir .. "ef/9012/att_d1.txt"), "file deleted")
    t.eq(t.lines()[1], t.aligned("* Del", ":ATTACH:"), "d keeps the tag")
    t.answer("z", true)
    t.keys("C-c C-a")
    t.eq(last_asked(t).prompt, "Attachment directory is empty.  Delete?")
    assert(not exists(dir .. "ef/9012"), "empty folder deleted")
    t.eq(t.lines(), { "* Del", ":PROPERTIES:", ":ID: ef9012", ":END:" })
    agree(t, path)
  end,

  -- Emacs: org-open-file's find-file-other-window splits and selects the
  -- attachment; with two attachments o asks which (sorted by name).
  ["o opens the only attachment in a split; b attaches a buffer; o then asks"] = function(t)
    local dir = setup(t)
    local path = t.open("att_open.org", "* O\n:PROPERTIES:\n:ID: bb0002\n:END:\n")
    t.answer("a", t.file("att_open.txt", "opened\n"))
    t.keys("C-c C-a")
    t.answer("o")
    t.keys("C-c C-a")
    t.eq(api.nvim_buf_get_name(0), dir .. "bb/0002/att_open.txt", "attachment shown")
    t.eq({ t.lines(), #api.nvim_list_wins() }, { { "opened" }, 2 }, "in a split")
    vim.cmd("wincmd p")
    t.eval([[(with-current-buffer (get-buffer-create "attbuf") (erase-buffer) (insert "from buffer\n"))]])
    t.after(function() t.eval([[(kill-buffer "attbuf")]]) end)
    t.answer("b", "attbuf")
    t.keys("C-c C-a")
    t.eq(t.read_file(dir .. "bb/0002/attbuf"), "from buffer\n", "buffer attached")
    t.answer("o", "attbuf")
    t.keys("C-c C-a")
    t.eq(last_asked(t).candidates, { "att_open.txt", "attbuf" }, "open candidates")
    t.eq(t.lines(), { "from buffer" }, "chosen one opened")
    agree(t, path)
  end,

  ["n visits a new file in the attachment folder that :w writes"] = function(t)
    local dir = setup(t)
    local path = t.open("att_new.org", "* N\n:PROPERTIES:\n:ID: cc0003\n:END:\n")
    t.answer("n", "fresh.txt")
    t.keys("C-c C-a")
    t.eq(api.nvim_buf_get_name(0), dir .. "cc/0003/fresh.txt", "new attachment visited")
    api.nvim_buf_set_lines(0, 0, -1, false, { "typed" })
    vim.cmd("silent write")
    t.eq(t.read_file(dir .. "cc/0003/fresh.txt"), "typed\n", "written by Neovim")
    agree(t, path)
    t.eq(t.emacs_lines(path)[1], t.aligned("* N", ":ATTACH:"), "tagged")
  end,

  -- Emacs: F shows dired of the folder in the selected window and adds no tag.
  ["s sets :DIR:, a attaches there, F lists it in dired"] = function(t)
    setup(t)
    local path = t.open("att_dir.org", "* S\nbody\n")
    local dir = t.WORK .. "/mydir/"
    t.answer("s", dir)
    t.keys("C-c C-a")
    t.eq(t.lines(), { "* S", ":PROPERTIES:", ":DIR:      " .. dir, ":END:", "body" })
    t.answer("a", t.file("att_s.txt", "s\n"))
    t.keys("C-c C-a")
    t.eq(t.lines()[1], t.aligned("* S", ":ATTACH:"))
    t.eq(t.read_file(dir .. "att_s.txt"), "s\n", "in :DIR:")
    agree(t, path)
    t.answer("F")
    t.keys("C-c C-a")
    local shown = table.concat(t.lines(), "\n")
    assert(shown:find("mydir", 1, true) and shown:find("att_s.txt", 1, true), "dired listing: " .. shown)
  end,

  ["C-c C-o on an attachment: link opens the file from the id folder"] = function(t)
    local dir = setup(t)
    vim.fn.mkdir(dir .. "dd/0004", "p")
    t.file("data/dd/0004/linked.txt", "via link\n")
    local path = t.open("att_link.org", "* T\n:PROPERTIES:\n:ID: dd0004\n:END:\nSee [[attachment:linked.txt]]\n")
    t.cursor(5, 6)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), dir .. "dd/0004/linked.txt", "attachment shown")
    t.eq(t.lines(), { "via link" })
    agree(t, path)
  end,

  ["C-c C-a in the agenda attaches to the entry under the cursor"] = function(t)
    local dir = setup(t)
    local path = t.open("att_agenda.org", "* TODO Agenda task\n:PROPERTIES:\n:ID: ab0007\n:END:\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.answer("t")
    t.command("org-agenda")
    t.cursor(t.find_line("Agenda task"))
    t.answer("a", t.file("att_ag.txt", "ag\n"))
    t.keys("C-c C-a")
    t.eq(t.read_file(dir .. "ab/0007/att_ag.txt"), "ag\n", "attached")
    agree(t, path)
    t.eq(t.emacs_lines(path)[1], t.aligned("* TODO Agenda task", ":ATTACH:"), "tagged")
  end,

  -- In Emacs the menu window shows point, which org-attach leaves at the
  -- menu's end, so C-v finds the end visible, says "End of buffer" and
  -- reads another key (org-scroll); it never aborts the dispatcher.
  ["q aborts, x errors, C-g leave the text and windows alone"] = function(t)
    setup(t)
    local path = t.open("att_quit.org", "* Q\n")
    -- C-g leaves *Org Attach* behind in Emacs too; q's run kills it.
    t.answer(t.QUIT)
    t.keys("C-c C-a")
    t.answer("x")
    t.keys("C-c C-a")
    t.answer("q")
    t.keys("C-c C-a")
    t.eq(t.lines(), { "* Q" })
    t.eq(#api.nvim_list_wins(), 1, "no dispatcher window left")
    t.eq(t.eval('(and (get-buffer "*Org Attach*") t)'), "nil", "dispatcher buffer killed")
    agree(t, path)
    -- C-v there should say "End of buffer" and read the next key.
    t.skip("org-scroll needs redisplay to see the menu's end (PROGRESS.md)")
  end,
}
