-- The demo workflows a person runs in a terminal: TAB cycling, the TODO and
-- tag menus, the date prompt's calendar, agenda, capture, table typing and
-- checkboxes. Expected text: emacs -Q --batch -l test/init.el, same keys.
local api = vim.api
local rpc = require("emacs.rpc")
local keys = require("emacs.keys")
local mirror = require("emacs.mirror")

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local NOTES = ROOT .. "/demo/notes.org"
local TABLE = "| name   | qty |\n|--------+-----|\n| apples | 3 |\n| pears | 12 |\n"
local TASKS = "* TODO Write report :work:\nSCHEDULED: <%s>\n* TODO Call Bob\n"
local TAGS = [['(("work" . ?w) ("home" . ?h) ("demo" . ?d))]]

-- With tags given, set before the file opens: org reads org-tag-alist when
-- the buffer starts org-mode.
local function open_notes(t, tags)
  if tags then t.set("org-tag-alist", TAGS) end
  return t.open("notes.org", t.read_file(NOTES))
end

local function agree(t, path, what) t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees") end

local function floats()
  local out = {}
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" then out[#out + 1] = w end
  end
  return out
end

-- Run fn with the plugin's real prompt handlers (the harness stubs them),
-- keys.read answering from `answers` and calling on_read(float) first.
local function with_real_ui(answers, on_read, fn)
  local stubs = {}
  for k, v in pairs(rpc.handlers) do stubs[k] = v end
  package.loaded["emacs.ui"] = nil
  require("emacs.ui")
  local read = keys.read
  keys.read = function()
    on_read(floats()[1])
    return table.remove(answers, 1)
  end
  local ok, err = pcall(fn)
  keys.read = read
  for k, v in pairs(stubs) do rpc.handlers[k] = v end
  assert(ok, err)
end

-- Run fn with the real date prompt, vim.fn.input answering `answer` once
-- the prompt's CmdlineEnter has drawn the calendar; returns the float that
-- was open then, as { pos = {row, col}, height = n }.
local function with_date_prompt(answer, fn)
  local seen
  local input = vim.fn.input
  vim.fn.input = function(opts)
    api.nvim_exec_autocmds("CmdlineEnter", {})
    local f = floats()[1]
    if f then seen = { pos = api.nvim_win_get_position(f), height = api.nvim_win_get_height(f) } end
    return answer == "cancel" and opts.cancelreturn or answer
  end
  local ok, err = pcall(with_real_ui, {}, function() end, fn)
  vim.fn.input = input
  assert(ok, err)
  return seen
end

-- Today plus `days` as an org date, "2026-11-09 Mon".
local function org_date(days)
  local d = os.date("*t")
  d.day = d.day + days
  return os.date("%Y-%m-%d %a", os.time(d))
end

-- Enter Insert mode with `cmd` and type each of `typed`, pausing after each
-- key as a person would: keys typed on a table line reach Emacs on the
-- event loop.
local function type_slowly(cmd, typed)
  vim.keymap.set("i", "<F11>", function() vim.wait(50) end, { buffer = true })
  local fed = cmd .. table.concat(typed, "<F11>") .. "<F11><Esc>"
  api.nvim_feedkeys(api.nvim_replace_termcodes(fed, true, false, true), "xt", false)
end

-- Background a highlight group draws with, following links.
local function bg_of(group) return api.nvim_get_hl(0, { name = group, link = false }).bg end

return {
  -- Emacs hides lines 4-9 (the blank line too: org-cycle-separator-lines
  -- is 2), then 8-9, then nothing.
  ["TAB on the demo's first heading cycles folded, children, subtree"] = function(t)
    open_notes(t)
    t.cursor(3)
    t.keys("TAB")
    t.eq(t.folds(), { "3-9" }, "FOLDED")
    t.keys("TAB")
    t.eq(t.folds(), { "7-9" }, "CHILDREN")
    t.keys("TAB")
    t.eq(t.folds(), {}, "SUBTREE")
  end,

  ["S-TAB folds every top-level entry of the demo"] = function(t)
    open_notes(t)
    t.cursor(3)
    t.keys("S-TAB")
    t.eq(t.folds(), { "3-9", "10-13", "14-20", "21-23", "24-31", "32-34" }, "OVERVIEW")
  end,

  -- Emacs: C-c C-t n, then C-c C-s asks "SCHEDULED Date+time [today]: "
  -- and +2d schedules two days out.
  ["C-c C-t n then C-c C-s +2d schedules the heading"] = function(t)
    local path = open_notes(t)
    t.cursor(10)
    t.answer("n")
    t.keys("C-c C-t")
    t.answer("+2d")
    t.keys("C-c C-s")
    t.eq(t.asked()[2].params.prompt, "SCHEDULED Date+time [" .. org_date(0):sub(1, 10) .. "]: ", "prompt")
    t.eq({ t.lines()[10], t.lines()[11] }, { "* NEXT Change states", "SCHEDULED: <" .. org_date(2) .. ">" })
    agree(t, path)
  end,

  ["fast tag selection w RET adds :work: aligned at column 77"] = function(t)
    local path = open_notes(t, true)
    t.cursor(10)
    t.answer("w", "RET")
    t.keys("C-c C-q")
    t.eq(t.lines()[10], t.aligned("* TODO Change states", ":work:"))
    agree(t, path)
  end,

  -- After w, org redraws the menu with face `default` on the tags not
  -- chosen; in Emacs that is the menu window's own background.
  ["the tag menu draws unchosen tags on the float's background"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("overlapping extmark queries need Neovim 0.10") end
    -- Wide enough for the prompt to fit the command line, as in a terminal.
    local columns = vim.o.columns
    vim.o.columns = 120
    t.after(function() vim.o.columns = columns end)
    open_notes(t, true)
    t.cursor(10)
    local menus = {}
    with_real_ui({ "w", "RET" }, function(win)
      local buf = api.nvim_win_get_buf(win)
      local row = t.find_line("%[h%] home", buf) - 1
      local col = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]:find("home", 1, true) - 1
      local groups = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, { row, col }, { row, col }, { details = true, overlap = true })) do
        groups[#groups + 1] = m[4].hl_group
      end
      menus[#menus + 1] = groups
    end, function() t.keys("C-c C-q") end)
    local float_bg = bg_of("NormalFloat")
    for _, group in ipairs(menus[2]) do
      local bg = bg_of(group)
      assert(bg == nil or bg == float_bg, ("'home' drawn with %s, background %s on a float of %s")
        :format(group, tostring(bg), tostring(float_bg)))
    end
  end,

  -- Emacs pops the calendar up in its own window: the org window's mode
  -- line stays visible above it.
  ["the date prompt's calendar float leaves the statusline visible"] = function(t)
    open_notes(t)
    t.cursor(10)
    local cal = with_date_prompt("+2d", function() t.keys("C-c C-s") end)
    assert(cal, "calendar float shown")
    local status_row = vim.o.lines - vim.o.cmdheight - 1
    assert(cal.pos[1] + cal.height <= status_row,
      ("calendar rows %d-%d cover the statusline row %d"):format(cal.pos[1], cal.pos[1] + cal.height - 1, status_row))
  end,

  ["Escape at the date prompt closes the calendar and changes nothing"] = function(t)
    local path = open_notes(t)
    local before = t.lines()
    t.cursor(10)
    local cal = with_date_prompt("cancel", function() t.keys("C-c C-s") end)
    assert(cal, "calendar float shown")
    t.eq(#floats(), 0, "no float left")
    t.eq(t.lines(), before)
    agree(t, path)
  end,

  -- Emacs: org-agenda a, the line after today's, t d: the file says DONE
  -- with :work: realigned; q leaves one window on the file.
  ["agenda a, t d on today's item marks it DONE; q closes the agenda"] = function(t)
    local path = t.open("tasks.org", TASKS:format(org_date(0)))
    local file_buf = api.nvim_get_current_buf()
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.answer("a")
    t.command("org-agenda")
    t.eq(api.nvim_get_current_line():match("^%a+"), os.date("%A"), "point on today")
    t.cursor(api.nvim_win_get_cursor(0)[1] + 1)
    t.answer("d")
    api.nvim_feedkeys("t", "x", false)
    t.eq(t.lines(file_buf)[1], t.aligned("* DONE Write report", ":work:"))
    api.nvim_feedkeys("q", "x", false)
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "agenda closed")
    t.eq(api.nvim_get_current_buf(), file_buf)
    agree(t, path)
  end,

  -- Emacs: point after "* TODO " in CAPTURE-inbox.org; C-c C-c saves
  -- "* TODO Buy milk\n".
  ["capture to a temp file starts after the template and saves the entry"] = function(t)
    local inbox = t.WORK .. "/tui_inbox.org"
    os.remove(inbox)
    t.open("capture_from.org", "* A\n")
    local from = api.nvim_get_current_buf()
    t.set("org-capture-templates", ([['(("t" "Task" entry (file %q) "* TODO %%?"))]]):format(inbox))
    t.answer("t")
    t.command("org-capture")
    t.eq({ api.nvim_buf_get_name(0):match("CAPTURE%-tui_inbox%.org$") ~= nil, api.nvim_win_get_cursor(0) },
      { true, { 1, 7 } }, "capture buffer, cursor after the template")
    api.nvim_buf_set_lines(0, 0, 1, false, { "* TODO Buy milk" })
    mirror.sync()
    t.keys("C-c C-c")
    t.eq(t.read_file(inbox), "* TODO Buy milk\n")
    t.eq(api.nvim_get_current_buf(), from, "back in the file")
  end,

  -- Emacs: 00 after the 3, TAB realigns and moves to "pears", which the
  -- first typed key blanks (org-table-auto-blank-field).
  ["typing a00, TAB, 7 in the demo table gives Emacs's cells"] = function(t)
    local path = t.open("tui_table.org", TABLE)
    t.cursor(3, 11)
    type_slowly("a", { "0", "0", "<Tab>", "7" })
    t.eq(t.lines(), { "| name   | qty |", "|--------+-----|", "| apples | 300 |", "| 7      |  12 |" })
    agree(t, path)
  end,

  -- Emacs: on the parent, user-error "unchecked subitems" and no change;
  -- on the child, both boxes check.
  ["C-c C-c on a checkbox: refused over an unchecked child, then checks both"] = function(t)
    local path = t.open("tui_boxes.org", "* L\n- [ ] milk\n  - [ ] eggs\n")
    t.cursor(2, 6)
    pcall(t.keys, "C-c C-c")
    t.eq(t.lines(), { "* L", "- [ ] milk", "  - [ ] eggs" }, "parent refused")
    t.cursor(3, 8)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "* L", "- [X] milk", "  - [X] eggs" }, "child")
    agree(t, path)
  end,
}
