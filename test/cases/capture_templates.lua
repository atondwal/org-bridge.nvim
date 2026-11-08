-- Capture templates past the basic entry: prompts, tags, dates, %i, %?, the
-- item/checkitem/plain/table-line types, olp/datetree targets, C-c C-k/C-w.
-- Expected text: emacs -Q --batch -l test/init.el, prompts answered on stdin.
local api = vim.api

local DATE = "^<%d%d%d%d%-%d%d%-%d%d %a+>$"
local STAMP = "^%[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]$"

-- An Elisp string literal.
local function q(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end

-- org-capture-templates for this test: one template under key "x".
local function template(t, kind, target, text, props)
  t.set("org-capture-templates", ("'((\"x\" \"Test\" %s %s %s %s))"):format(kind, target, q(text), props or ""))
end

local function capture(t, ...)
  t.answer("x", ...)
  t.command("org-capture")
end

-- Capture as typed: the capture buffer starts in Insert mode at %?, so text
-- typed after the command goes there.
local function capture_typing(t, text)
  t.answer("x")
  t.feed("<Cmd>lua require('emacs').exec({ command = 'org-capture' })<CR>" .. text .. "<Esc>")
end

-- Capture from a Visual selection made by `motion`, through Visual-mode
-- C-c as typed, with org-capture on C-c c as in Org's manual.
local function capture_region(t, motion)
  t.eval([[(global-set-key (kbd "C-c c") #'org-capture)]])
  t.after(function() t.eval([[(global-set-key (kbd "C-c c") nil)]]) end)
  t.answer("c", "x")
  t.feed(motion .. "<C-c>")
end

-- Emacs's copy of the target file, and Neovim's if it has one, both equal want.
local function target_is(t, path, want)
  t.eq(t.emacs_lines(path), want, "Emacs's " .. vim.fn.fnamemodify(path, ":t"))
  local buf = vim.fn.bufnr(path)
  if buf > 0 then t.eq(api.nvim_buf_get_lines(buf, 0, -1, false), want, "Neovim's " .. vim.fn.fnamemodify(path, ":t")) end
end

return {
  ["%^{Prompt} and %^{Prompt|default|...} fill the entry; an empty answer takes the default"] = function(t)
    local path = t.file("prompts.org", "* Old\n")
    template(t, "entry", ("(file %q)"):format(path), "* TODO %^{Task}\nKind: %^{Kind|work|home}\n%?")
    capture(t, "Write tests", "")
    t.eq(t.lines(), { "* TODO Write tests", "Kind: work", "" }, "capture buffer")
    t.keys("C-c C-c")
    target_is(t, path, { "* Old", "* TODO Write tests", "Kind: work", "" })
  end,

  ["%^g reads tags and aligns them; %t and %U insert today's date"] = function(t)
    local path = t.file("tags.org", "* Old :alpha:\n")
    template(t, "entry", ("(file %q)"):format(path), "* %^{Title} %^g\n%t\n%U", ":immediate-finish t")
    capture(t, "Buy milk", "errand:home")
    local lines = t.emacs_lines(path)
    t.eq({ lines[1], lines[2], #lines }, { "* Old :alpha:", t.aligned("* Buy milk", ":errand:home:"), 4 }, "tags")
    assert(lines[3]:find(DATE) and lines[4]:find(STAMP), "dates: " .. vim.inspect(lines))
    t.eq(lines[3]:sub(2, 11), os.date("%Y-%m-%d"), "%t is today")
    target_is(t, path, lines)
  end,

  ["%i takes a Visual selection; linewise text is indented like the %i"] = function(t)
    local path = t.file("region.org", "")
    t.open("src.org", "* S\nline one\nline two\n* T\n")
    template(t, "entry", ("(file %q)"):format(path), "* Quote\n  %i\n%?")
    t.cursor(2)
    capture_region(t, "Vj")
    t.eq(t.lines(), { "* Quote", "  line one", "  line two", "  ", "" }, "capture buffer")
    t.keys("C-c C-c")
    target_is(t, path, { "* Quote", "  line one", "  line two", "  ", "" })
    -- Charwise. As in Emacs, the source's region is still active after the capture.
    t.feed("<Esc>")
    template(t, "entry", ("(file %q)"):format(path), "* Word %i")
    t.cursor(2, 5)
    capture_region(t, "ve")
    t.eq(t.lines(), { "* Word one" }, "charwise capture buffer")
    t.keys("C-c C-k")
  end,

  -- In Emacs the region of the file's last two whole lines (C-SPC C-n C-n)
  -- ends at point-max, after the final newline.
  ["%i from a linewise selection of the last lines keeps their final newline"] = function(t)
    local path = t.file("region_eob.org", "")
    t.open("src_eob.org", "* S\nline one\nline two\n")
    template(t, "entry", ("(file %q)"):format(path), "* Quote\n  %i\n%?")
    t.cursor(2)
    capture_region(t, "Vj")
    t.eq(t.lines(), { "* Quote", "  line one", "  line two", "  ", "" }, "capture buffer")
    t.keys("C-c C-k")
  end,

  ["%? is where typing goes when the capture buffer opens"] = function(t)
    local path = t.open("abort_cursor.org", "* Keep\nbody\n")
    template(t, "entry", ("(file+headline %q \"Keep\")"):format(path), "* TODO %?\nnotes")
    capture_typing(t, "typed")
    t.eq(t.lines(), { "** TODO typed", "notes" }, "capture buffer")
    t.keys("C-c C-k")
  end,

  ["item into file+headline appends; checkitem with :prepend goes first"] = function(t)
    local path = t.file("lists.org", "* Groceries\n- milk\n* Todo\n- [ ] a\n* Other\n")
    template(t, "item", ("(file+headline %q \"Groceries\")"):format(path), "%^{Item}", ":immediate-finish t")
    capture(t, "eggs")
    template(t, "checkitem", ("(file+headline %q \"Todo\")"):format(path), "[ ] %^{Do}", ":prepend t :immediate-finish t")
    capture(t, "new")
    target_is(t, path, { "* Groceries", "- milk", "- eggs", "* Todo", "- [ ] new", "- [ ] a", "* Other" })
  end,

  ["table-line adds a row after the table's last row and realigns"] = function(t)
    local path = t.file("table.org", "* Data\n| name | n |\n|------+---|\n| a | 1 |\n* After\n")
    template(t, "table-line", ("(file+headline %q \"Data\")"):format(path), "| %^{Name} | %^{N} |", ":immediate-finish t")
    capture(t, "bb", "22")
    target_is(t, path, { "* Data", "| name |  n |", "|------+----|", "| a    |  1 |", "| bb   | 22 |", "* After" })
  end,

  ["plain into file+olp lands at the end of that subtree's body"] = function(t)
    local path = t.file("olp.org", "* Top\n** Sub\ntext\n** Sib\n")
    template(t, "plain", ("(file+olp %q \"Top\" \"Sub\")"):format(path), "plain %^{X}", ":immediate-finish t")
    capture(t, "hi")
    target_is(t, path, { "* Top", "** Sub", "text", "plain hi", "** Sib" })
  end,

  ["file+olp+datetree files under year, month and day headings"] = function(t)
    local path = t.file("tree.org", "* Journal\n")
    template(t, "entry", ("(file+olp+datetree %q \"Journal\")"):format(path), "* %^{Event}", ":immediate-finish t")
    capture(t, "Party")
    target_is(t, path, { "* Journal", "** " .. os.date("%Y"), "*** " .. os.date("%Y-%m %B"),
      "**** " .. os.date("%Y-%m-%d %A"), "***** Party" })
  end,

  ["C-c C-k after typing leaves an open target file as it was"] = function(t)
    local path = t.open("abort.org", "* Keep\nbody\n")
    local buf = api.nvim_get_current_buf()
    template(t, "entry", ("(file+headline %q \"Keep\")"):format(path), "* TODO %?\nnotes")
    capture_typing(t, "typed")
    t.eq(t.lines()[1], "** TODO typed", "typed into the capture")
    t.keys("C-c C-k")
    t.eq(api.nvim_get_current_buf(), buf, "back in the target")
    target_is(t, path, { "* Keep", "body" })
    t.eq(vim.bo[buf].modified, false, "not modified")
    t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(path)), "nil", "Emacs: not modified")
    t.eq(t.read_file(path), "* Keep\nbody\n", "file on disk")
  end,

  ["C-c C-w in the capture buffer refiles the entry to another file"] = function(t)
    local inbox = t.file("inbox2.org", "* Inbox\n")
    local proj = t.file("proj.org", "* Projects\n** P1\n* Someday\n")
    t.set("org-refile-targets", ("'((%q :maxlevel . 1))"):format(proj))
    template(t, "entry", ("(file %q)"):format(inbox), "* TODO %?")
    capture_typing(t, "Move me")
    t.answer("Someday")
    t.keys("C-c C-w")
    assert(not api.nvim_buf_get_name(0):find("CAPTURE"), "capture closed: " .. api.nvim_buf_get_name(0))
    target_is(t, inbox, { "* Inbox" })
    target_is(t, proj, { "* Projects", "** P1", "* Someday", "** TODO Move me" })
  end,

  [":jump-to-captured shows the new entry in its file"] = function(t)
    local path = t.file("jump.org", "* A\n* B\nbody\n")
    template(t, "entry", ("(file+headline %q \"A\")"):format(path), "* Child %^{Name}",
      ":jump-to-captured t :immediate-finish t")
    capture(t, "X")
    t.eq(api.nvim_buf_get_name(0), path, "jumped to the target")
    t.eq(t.lines(), { "* A", "** Child X", "* B", "body" })
    t.eq(api.nvim_win_get_cursor(0)[1], 2, "on the captured entry")
    target_is(t, path, t.lines())
  end,
}
