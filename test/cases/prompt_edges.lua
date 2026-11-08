-- Awkward answers to Emacs's prompts: empty, long, multibyte and multi-line
-- answers, Escape mid-command and in menus, require-match, read-number and
-- org-read-date given junk. Expected: emacs -Q --batch -l test/init.el.
local api = vim.api
local mirror = require("emacs.mirror")

local org_date = require("dates").org

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function agree(t, path, what)
  mirror.sync()
  local buf = vim.fn.bufnr(path)
  t.eq(t.emacs_lines(path), api.nvim_buf_get_lines(buf, 0, -1, false), (what or "") .. " Emacs agrees")
end

-- Methods and prompts of every input request so far.
local function prompts(t)
  local out = {}
  for _, a in ipairs(t.asked()) do out[#out + 1] = a.method .. " " .. a.params.prompt end
  return out
end

-- An Elisp string literal.
local function q(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end

local function template(t, path, text)
  t.set("org-capture-templates", ("'((\"x\" \"Test\" entry (file %q) %s))"):format(path, q(text)))
end

local function capture_buffers(t)
  return t.eval([[(format "%S" (seq-filter (lambda (name) (string-match-p "CAPTURE" name))
                                         (mapcar #'buffer-name (buffer-list))))]])
end

local function set_property(t, name, value)
  t.cursor(1)
  t.answer(name, value)
  t.keys("C-c C-x p")
end

return {
  -- Emacs: org-capture turns the quit into "Capture abort: Quit"; inbox.org
  -- keeps "* Old" and no CAPTURE- buffer is left.
  ["Escape at the second capture prompt leaves no half capture"] = function(t)
    local src = t.open("pe_src.org", t.DOC)
    local inbox = t.file("pe_inbox.org", "* Old\n")
    template(t, inbox, "* %^{a} %^{b}")
    t.answer("x", "first", t.QUIT)
    t.command("org-capture")
    t.eq(prompts(t), { "read_key Template key: ", "completing_read a: ", "completing_read b: " }, "prompts")
    t.eq(capture_buffers(t), [["nil"]], "Emacs capture buffers")
    t.eq(api.nvim_buf_get_name(0), src, "back in the source")
    t.eq(t.emacs_lines(inbox), { "* Old" }, "Emacs's inbox")
    t.eq(t.read_file(inbox), "* Old\n", "inbox on disk")
    agree(t, src)
    -- Nothing stale: the next capture runs from the top.
    t.answer("x", "one", "two")
    t.command("org-capture")
    t.eq(t.lines(), { "* one two" }, "second capture buffer")
    t.keys("C-c C-c")
    t.eq(t.emacs_lines(inbox), { "* Old", "* one two" })
  end,

  -- Emacs: an empty %^{a} inserts nothing; the multibyte text goes in as is.
  ["an empty and a multibyte answer fill a capture template"] = function(t)
    local inbox = t.file("pe_mb.org", "* Old\n")
    template(t, inbox, "* [%^{a}] %^{b}")
    t.answer("x", "", "日本語 café 🎉")
    t.command("org-capture")
    t.eq(t.lines(), { "* [] 日本語 café 🎉" }, "capture buffer")
    t.keys("C-c C-c")
    t.eq(t.emacs_lines(inbox), { "* Old", "* [] 日本語 café 🎉" })
    agree(t, inbox)
  end,

  -- Emacs: ":Foo:      " then the 3000 characters, on one line.
  ["a 3000-character property value lands whole on one line"] = function(t)
    local path = t.open("pe_long.org", "* A\n")
    local long = string.rep("x", 1500) .. string.rep("é", 1500)
    set_property(t, "Foo", long)
    t.eq(t.lines(), { "* A", ":PROPERTIES:", ":Foo:      " .. long, ":END:" })
    agree(t, path)
  end,

  -- Emacs inserts the newline as is, splitting the drawer line.
  ["a property value with a newline goes in as Emacs puts it"] = function(t)
    local path = t.open("pe_nl.org", "* A\n")
    set_property(t, "Foo", "line1\nline2")
    t.eq(t.lines(), { "* A", ":PROPERTIES:", ":Foo: line1", "line2", ":END:" })
    agree(t, path)
  end,

  -- Emacs: org-set-property reads both answers before editing; quit at the
  -- value leaves the buffer as it was.
  ["Escape at the property value prompt changes nothing"] = function(t)
    local path = t.open("pe_propquit.org", "* A\n")
    set_property(t, "Foo", t.QUIT)
    t.eq(t.lines(), { "* A" })
    agree(t, path)
    t.eq(vim.bo.modified, false, "Neovim buffer unmodified")
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(path)), "nil", "Emacs unmodified")
  end,

  -- Emacs: C-c C-t C-g signals quit, heading unchanged; tags w then C-g
  -- drops the pending w.
  ["Escape in the fast TODO and tag menus leaves the heading"] = function(t)
    -- Before the file opens: org-mode reads org-tag-alist at startup.
    t.set("org-tag-alist", "'((\"work\" . ?w) (\"home\" . ?h))")
    local path = t.open("pe_menu.org", "* A\n")
    t.cursor(1)
    t.answer(t.QUIT)
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* A" }, "after Escape in the TODO menu")
    t.answer("w", t.QUIT)
    t.keys("C-c C-q")
    t.eq(t.lines(), { "* A" }, "after Escape in the tag menu")
    agree(t, path)
    t.answer("n")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* NEXT A" }, "the menu works afterwards")
    agree(t, path, "after C-c C-t n")
  end,

  ["Escape in the export dispatcher writes nothing"] = function(t)
    local path = t.open("pe_export.org", t.DOC)
    t.answer(t.QUIT)
    t.keys("C-c C-e")
    t.eq(vim.fn.glob(t.WORK .. "/pe_export.*", false, true), { path }, "no export file")
    t.eq(t.eval([[(format "%S" (get-buffer "*Org Export Dispatcher*"))]]), [["nil"]], "dispatcher buffer gone")
    agree(t, path)
  end,

  -- Emacs (a keyboard macro drives a real minibuffer in batch): with
  -- Effort_ALL set, RET on "2:00" says [No match] and stays; 0:30 is taken.
  ["a require-match prompt refuses an answer outside its table"] = function(t)
    local path = t.open("pe_effort.org", "#+PROPERTY: Effort_ALL 0:10 0:30 1:00\n* A\n")
    t.cursor(2)
    t.answer("2:00", "0:30")
    t.command("org-set-effort")
    t.eq(t.lines(), { "#+PROPERTY: Effort_ALL 0:10 0:30 1:00", "* A", ":PROPERTIES:", ":Effort:   0:30", ":END:" })
    agree(t, path)
  end,

  -- Emacs: read-number says "Please enter a number." and asks again; the
  -- scatter over 1 day schedules for tomorrow.
  ["read-number in an agenda bulk action asks again given text"] = function(t)
    local path = t.open("pe_bulk.org", "* TODO Task\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.answer("t")
    t.command("org-agenda")
    t.cursor(t.find_line("Task"))
    t.keys("m")
    t.answer("S", "abc", "1")
    press("B")
    local asked = prompts(t)
    t.eq({ asked[#asked - 1], asked[#asked] }, { "read_string Scatter tasks across how many days (default 7): ",
      "read_string Scatter tasks across how many days (default 7): " }, "asked twice")
    t.eq(api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false), { "* TODO Task", "SCHEDULED: <" .. org_date(1) .. ">" })
    agree(t, path)
  end,

  ["Escape at a bulk action's prompt schedules nothing"] = function(t)
    local path = t.open("pe_bulkquit.org", "* TODO Task\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.answer("t")
    t.command("org-agenda")
    t.cursor(t.find_line("Task"))
    t.keys("m")
    t.answer("s", t.QUIT)
    press("B")
    t.eq(api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false), { "* TODO Task" })
    agree(t, path)
  end,

  -- Emacs: org-read-date reads "garbage" as today.
  ["org-read-date given garbage schedules today"] = function(t)
    local path = t.open("pe_date.org", "* A\n")
    t.cursor(1)
    t.answer("garbage")
    t.keys("C-c C-s")
    t.eq(t.lines(), { "* A", "SCHEDULED: <" .. org_date(0) .. ">" })
    agree(t, path)
  end,
}
