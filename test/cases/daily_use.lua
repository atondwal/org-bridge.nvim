-- A day of org in a terminal: agenda review with closing notes, captures
-- into an inbox, refiling them. Only what a headless run reproduces is here.
-- Expected: emacs -Q --batch -l test/init.el, same commands (an undo
-- boundary per command, prompts stubbed); window order read from
-- window-top-line.
local api = vim.api
local mirror = require("emacs.mirror")

-- The plugin's real prompt handlers (the harness stubs them): Emacs's
-- menus and C-c's second key read the next keys from typeahead, as typed.
local function real_prompts()
  package.loaded["emacs.ui"] = nil
  require("emacs.ui")
end

-- Type keys; returns the mode they left Neovim in (feedkeys's "x" ends
-- Insert mode afterwards, so <Cmd> reads it first).
local function type_keys(keys)
  keys = keys .. "<Cmd>lua _G.emacs_test_mode = vim.api.nvim_get_mode().mode<CR>"
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
  return _G.emacs_test_mode
end

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(vim.fn.bufnr(path)), (what or "") .. " Emacs agrees")
end

-- Inline virtual text in buf, as { "row:col text" }, from every namespace.
local function inline_text(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local d = m[4]
    if d.virt_text and d.virt_text_pos == "inline" then
      local s = ""
      for _, chunk in ipairs(d.virt_text) do s = s .. chunk[1] end
      out[#out + 1] = m[2] .. ":" .. m[3] .. " " .. s
    end
  end
  return out
end

-- test/init.el's bookmark file is empty, which bookmark-set refuses; a
-- missing file starts an empty bookmark list, as on a first run.
local function inbox_template(t, inbox)
  t.set("org-capture-templates", ([['(("i" "Inbox" entry (file %q) "* TODO %%?"))]]):format(inbox))
  t.eval("(require 'bookmark)")
  t.set("bookmark-default-file", ("%q"):format(vim.fn.tempname()))
  t.set("bookmarks-already-loaded", "nil")
end

-- Capture "* TODO <text>" into the inbox template's file.
local function capture(t, text)
  t.answer("i")
  t.command("org-capture")
  assert(api.nvim_buf_get_name(0):find("CAPTURE", 1, true), "in the capture buffer")
  vim.cmd("stopinsert")
  api.nvim_buf_set_lines(0, 0, 1, false, { "* TODO " .. text })
end

-- Non-float windows of the current tab, top to bottom, as buffer tails.
local function layout()
  local wins = vim.tbl_filter(function(w) return api.nvim_win_get_config(w).relative == "" end,
    api.nvim_tabpage_list_wins(0))
  table.sort(wins, function(a, b) return api.nvim_win_get_position(a)[1] < api.nvim_win_get_position(b)[1] end)
  return vim.tbl_map(function(w) return vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(w)), ":t") end,
    wins)
end

return {
  -- Emacs: org-capture's bookmark-set puts a bookmark overlay on the new
  -- entry whose before-string "x" has display (left-fringe ...): a fringe
  -- bitmap, never text in the line (a tty has no fringe at all).
  ["after a capture the new entry has no inline x (bookmark fringe mark)"] = function(t)
    local inbox = t.file("day_inbox.org", "#+TITLE: Inbox\n")
    inbox_template(t, inbox)
    t.open("day_projects.org", "* Work\n")
    capture(t, "Book dentist")
    t.keys("C-c C-c")
    vim.cmd("edit " .. vim.fn.fnameescape(inbox))
    t.eq(t.lines(), { "#+TITLE: Inbox", "* TODO Book dentist" })
    agree(t, inbox)
    t.eq(inline_text(0), {}, "inline virtual text in the inbox")
  end,

  -- Emacs: C-c C-w in the capture buffer files the entry under Someday;
  -- capture's and refile's bookmarks both mark it, still only in the fringe.
  ["capture then C-c C-w leaves no inline x on the refiled entry"] = function(t)
    local inbox = t.file("day_inbox2.org", "#+TITLE: Inbox\n")
    inbox_template(t, inbox)
    local projects = t.open("day_projects2.org", "* Work\n* Someday\n")
    t.set("org-refile-targets", ([['((%q :maxlevel . 1))]]):format(projects))
    capture(t, "Renew passport")
    t.answer("Someday")
    t.keys("C-c C-w")
    local buf = vim.fn.bufnr(projects)
    t.eq(t.lines(buf), { "* Work", "* Someday", "** TODO Renew passport" })
    agree(t, projects)
    agree(t, inbox, "inbox")
    t.eq(inline_text(buf), {}, "inline virtual text in the target")
  end,

  -- Emacs: org-add-log-note saves the window configuration and
  -- org-store-log-note restores it, so after t d and the note the file is
  -- still above the agenda (window-top-line 1 and 12 in batch), its point
  -- still on "Pay rent", and the agenda is selected.
  ["agenda t d with a closing note keeps the file above the agenda"] = function(t)
    local today = os.date("%Y-%m-%d %a")
    local path = t.open("day_review.org",
      ("* TODO Call plumber\nSCHEDULED: <%s>\n* TODO Buy groceries\n* TODO Pay rent\n"):format(today))
    t.cursor(4)
    t.eval("(require 'org-agenda)")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.set("org-agenda-span", "'day")
    t.set("org-log-done", "'note")
    t.answer("a")
    t.command("org-agenda")
    t.eq(layout(), { "day_review.org", "*Org Agenda*" }, "agenda opened below the file")
    t.cursor(t.find_line("Call plumber"))
    t.answer("d")
    press("t")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Org Note*", "note buffer shown")
    api.nvim_buf_set_lines(0, -2, -1, false, { "Plumber fixed the sink" })
    t.keys("C-c C-c")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Org Agenda*", "agenda selected")
    agree(t, path)
    local file_buf = vim.fn.bufnr(path)
    t.eq(api.nvim_win_get_cursor(vim.fn.bufwinid(path))[1], t.find_line("Pay rent", file_buf),
      "file window's cursor stays on its line")
    t.eq(layout(), { "day_review.org", "*Org Agenda*" }, "layout after the note")
  end,

  -- Finishing a capture with C-c C-c typed in Insert mode lands in Normal
  -- mode in the file; the *Org Note* of a DONE is the same kind of
  -- buffer and should too, or the next keys type into the heading.
  ["C-c C-c typed in Insert mode in *Org Note* returns in Normal mode"] = function(t)
    local path = t.open("day_note_insert.org", "* TODO Email Dana\n")
    t.set("org-log-done", "'note")
    real_prompts()
    type_keys("<C-c><C-t>d")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Org Note*", "note buffer shown")
    local mode = type_keys("GiSent<C-c><C-c>")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "day_note_insert.org", "back in the file")
    agree(t, path)
    t.eq(mode, "n", "mode after the note")
  end,

  -- The convention the note test holds *Org Note* to.
  ["C-c C-c typed in Insert mode in a capture returns in Normal mode"] = function(t)
    local inbox = t.file("day_inbox3.org", "")
    inbox_template(t, inbox)
    t.open("day_cap_insert.org", "* Work\n")
    real_prompts()
    local capture_cmd = "<Cmd>lua require('emacs').exec({ command = 'org-capture' })<CR>"
    t.eq(type_keys(capture_cmd .. "iMilk"), "i", "capture starts in Insert mode")
    local mode = type_keys("<C-c><C-c>")
    t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "day_cap_insert.org", "back in the file")
    t.eq(mode, "n", "mode after the capture")
    agree(t, inbox)
  end,

  -- Emacs binds G in the agenda (time grid); Neovim keeps it, so G and
  -- 19G move as in any buffer.
  ["G in the agenda goes to the last line"] = function(t)
    local path = t.open("day_g.org", ("* TODO A\nSCHEDULED: <%s>\n"):format(os.date("%Y-%m-%d %a")))
    t.eval("(require 'org-agenda)")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.answer("a")
    t.command("org-agenda")
    t.feed("gg")
    t.feed("G")
    t.eq(vim.fn.line("."), vim.fn.line("$"))
  end,
}
