-- Scale: a 20k-line org file with 3000 headings and many timestamps.
-- Times each interactive command with vim.loop.hrtime against a 100 ms
-- budget (plus what Emacs itself spends), and checks 200 repeats don't leak.
local api = vim.api

local BUDGET_MS = 100
local HEADINGS = 3000
local AGENDA_FILES = 5
local REPEATS = 200
local NS = api.nvim_get_namespaces().emacs

local DAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- Heading i of file `tag`: level 1 every 10th, else 2 or 3. Every 10th is
-- scheduled in the week of 2026-11-02, the rest carry older timestamps;
-- every 100th has a table.
local function big_org(tag)
  local out = {}
  local function add(s) out[#out + 1] = s end
  for i = 1, HEADINGS do
    local level = i % 10 == 1 and 1 or (i % 3 == 0 and 3 or 2)
    local todo = i % 4 == 0 and "TODO " or ""
    add(("%s %sTask %s-%d :t%d:"):format(("*"):rep(level), todo, tag, i, i % 7))
    if i % 10 == 5 then
      local day = i % 7
      add(("SCHEDULED: <2026-11-%02d %s>"):format(2 + day, DAYS[day + 1]))
    end
    add(":PROPERTIES:")
    add((":CUSTOM_ID: %s-%d"):format(tag, i))
    add(":END:")
    add(("Body of %d, noted <2025-%02d-%02d>."):format(i, i % 12 + 1, i % 28 + 1))
    add("Second line of text.")
    add("Third line of text.")
    if i % 100 == 50 then
      add("| name | n |")
      add("|------+---|")
      for r = 1, 3 do add(("| row%d | %d |"):format(r, r)) end
    end
  end
  add("")
  return table.concat(out, "\n")
end

local function now_ms() return vim.loop.hrtime() / 1e6 end

local function time_ms(fn)
  local start = now_ms()
  fn()
  return now_ms() - start
end

-- Emacs's own time for elisp `form`, in ms, run inside the bridge.
local function emacs_ms(t, form)
  return tonumber(t.eval(("(* 1000 (float-time (let ((s (current-time))) %s (time-since s))))"):format(form)))
end

local function report(what, n, unit) io.stdout:write(("  %-40s %8.1f %s\n"):format(what, n, unit or "ms")) end

-- Report `ms` and note it if over budget; `own` is time Emacs itself
-- would spend.
local overruns = {}
local function within(what, ms, own)
  report(what, ms)
  local limit = BUDGET_MS + (own or 0)
  if ms > limit then overruns[#overruns + 1] = ("%s took %.0f ms (budget %.0f ms)"):format(what, ms, limit) end
end

local function check_budget()
  if #overruns > 0 then error(table.concat(overruns, "\n"), 0) end
end

local function open_big(t, name)
  local path = t.file(name, big_org(name:gsub("%.org$", "")))
  local ms = time_ms(function() vim.cmd("silent edit " .. vim.fn.fnameescape(path)) end)
  return path, ms
end

local function agree(t, path, what) t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees") end

-- Type `chars` in Insert mode from the cursor, one key at a time as a
-- person would; report each key's time and note the slowest over budget.
local function type_timed(t, what, chars)
  local stamps = {}
  vim.keymap.set("i", "<F11>", function() stamps[#stamps + 1] = now_ms() end, { buffer = true })
  local keys = "i<F11>" .. chars:gsub(".", "%0<F11>") .. "<Esc>"
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
  local worst, deltas = 0, {}
  for i = 2, #stamps do
    worst = math.max(worst, stamps[i] - stamps[i - 1])
    deltas[#deltas + 1] = ("%.0f"):format(stamps[i] - stamps[i - 1])
  end
  io.stdout:write("  ms per key: ", table.concat(deltas, " "), "\n")
  report(what .. ", mean per key", (stamps[#stamps] - stamps[1]) / #chars)
  within(what .. ", slowest key", worst)
end

-- Bytes Emacs has allocated so far (memory-use-counts, weighted by size).
local function emacs_alloc(t)
  return tonumber(t.eval([[(pcase-let ((`(,conses ,floats ,vector-cells ,symbols ,chars ,intervals ,strings)
                (memory-use-counts)))
    (+ (* 16 conses) (* 8 floats) (* 8 vector-cells) (* 48 symbols) chars (* 56 intervals) (* 32 strings)))]]))
end

-- Emacs's live heap in KB, after a full collection.
local function emacs_heap_kb(t)
  return tonumber(t.eval([[(let ((s 0))
    (dolist (e (garbage-collect)) (setq s (+ s (* (nth 1 e) (or (nth 2 e) 0)))))
    (/ s 1024))]]))
end

local cases = {
  ["opening the file and its first command"] = function(t)
    local path, open = open_big(t, "open.org")
    t.eq(#t.lines() > 20000, true, "20k lines")
    report("open (:edit)", open)
    -- The first command attaches the buffer if :edit didn't.
    t.cursor(1)
    local first = time_ms(function() t.keys("TAB") end)
    within("first TAB after open", first)
    agree(t, path)
  end,

  ["TAB on a heading cycles its subtree"] = function(t)
    open_big(t, "tab.org")
    local l = t.find_line("^%* Task tab%-1001 ")
    t.cursor(l)
    t.keys("TAB")
    t.cursor(l)
    local ms = time_ms(function() t.keys("TAB") end)
    within("TAB on a heading", ms)
  end,

  ["S-TAB global cycle"] = function(t)
    open_big(t, "stab.org")
    t.cursor(1)
    t.keys("TAB")
    for _, what in ipairs({ "overview", "contents", "show all" }) do
      local ms = time_ms(function() t.keys("<backtab>") end)
      within("S-TAB " .. what, ms)
    end
  end,

  -- Emacs: M-down on the first top-level subtree (100 headings) swaps it
  -- with the next; the text is the two blocks exchanged.
  ["M-down moves a 100-heading subtree"] = function(t)
    local path = open_big(t, "mdown.org")
    local before = t.lines()
    local second = t.find_line("^%* Task mdown%-11 ")
    local third = t.find_line("^%* Task mdown%-21 ")
    t.cursor(1)
    local ms = time_ms(function() t.keys("M-<down>") end)
    local want = {}
    vim.list_extend(want, before, second, third - 1)
    vim.list_extend(want, before, 1, second - 1)
    vim.list_extend(want, before, third, #before)
    t.eq(t.lines(), want, "subtrees exchanged")
    within("M-down of a big subtree", ms)
    agree(t, path)
  end,

  ["C-c C-t on a heading"] = function(t)
    local path = open_big(t, "todo.org")
    local l = t.find_line("^%*%* Task todo%-1502 ")
    t.cursor(l)
    t.answer("t")
    local ms = time_ms(function() t.keys("C-c C-t") end)
    t.eq(t.lines()[l], t.aligned("** TODO Task todo-1502", ":t4:"))
    within("C-c C-t", ms)
    agree(t, path)
  end,

  ["typing 20 characters on a heading"] = function(t)
    local path = open_big(t, "typeh.org")
    local l = t.find_line("^%*%* Task typeh%-1502 ")
    t.cursor(l, 3)
    local chars = "abcdefghijklmnopqrst"
    type_timed(t, "typing on a heading", chars)
    t.eq(t.lines()[l], t.aligned("** " .. chars .. "Task typeh-1502", ":t4:"))
    agree(t, path)
  end,

  ["typing 20 characters in a table cell"] = function(t)
    local path = open_big(t, "typet.org")
    -- The table of heading 1550, near the middle of the file.
    local l = t.find_line(" Task typet%-1550 ") + 9
    t.cursor(l, 2)
    local chars = "abcdefghijklmnopqrst"
    type_timed(t, "typing in a table", chars)
    t.eq(t.lines()[l], "| " .. chars .. "row1 | 1 |", "typed into the cell, as in Emacs")
    agree(t, path)
  end,

  ["week agenda over 5 big files, then t on an entry"] = function(t)
    local paths = {}
    for i = 1, AGENDA_FILES do
      paths[i] = t.file(("ag%d.org"):format(i), big_org("ag" .. i))
    end
    -- Mirroring a file this size, which the first change in an agenda file
    -- Neovim hasn't loaded also does (Emacs sends it whole).
    local mirror_ms = time_ms(function() vim.cmd("silent edit " .. vim.fn.fnameescape(paths[1])) end)
    local files = table.concat(vim.tbl_map(function(p) return ("%q"):format(p) end, paths), " ")
    t.eval(("(setq org-agenda-files (list %s))"):format(files))
    t.eval("(require 'org-agenda)")
    t.set("org-agenda-start-day", '"2026-11-02"')
    t.set("org-agenda-start-on-weekday", "1")
    -- What Emacs alone spends building the same week; twice, as the first
    -- visits the files.
    local agenda = "(save-window-excursion (org-agenda-list) (kill-buffer))"
    local cold = emacs_ms(t, agenda)
    report("Emacs's own org-agenda-list, cold", cold)
    local warm = emacs_ms(t, agenda)
    report("Emacs's own org-agenda-list, warm", warm)
    -- Emacs's own builds vary by half from run to run: budget the slower.
    local own = math.max(cold, warm)
    t.answer("a")
    local ms = time_ms(function() t.command("org-agenda") end)
    assert(api.nvim_buf_get_name(0):find("Org Agenda"), "agenda shown")
    local entry = assert(t.find_line("Task ag3%-1505"), "agenda lists ag3-1505")
    within("week agenda (5 files)", ms, own)
    t.cursor(entry)
    t.answer("t")
    local gc0 = tonumber(t.eval("gc-elapsed"))
    local tms = time_ms(function() api.nvim_feedkeys("t", "x", false) end)
    assert(t.find_line("TODO Task ag3%-1505"), "agenda redrawn:\n" .. table.concat(t.lines(), "\n"))
    within("agenda t on an entry", tms, mirror_ms)
    report("  of which Emacs collected garbage", (tonumber(t.eval("gc-elapsed")) - gc0) * 1000)
    -- ag3.org now has a Neovim buffer; a second t in it.
    t.cursor(t.find_line("Task ag3%-1515"))
    t.answer("t")
    tms = time_ms(function() api.nvim_feedkeys("t", "x", false) end)
    assert(t.find_line("TODO Task ag3%-1515"), "agenda redrawn")
    within("second agenda t, same file", tms)
  end,

  ["200 repeated commands don't grow time, buffers or extmarks"] = function(t)
    open_big(t, "leak.org")
    local l = t.find_line("^%*%* Task leak%-1502 ")
    t.cursor(l)
    local function emacs_buffers() return tonumber(t.eval("(length (buffer-list))")) end
    local function marks() return #api.nvim_buf_get_extmarks(0, NS, 0, -1, {}) end
    local times = {}
    local b0, m0, heap0, lua0
    -- S-left makes it DONE, S-right clears it: the text comes back each pair.
    for i = 1, REPEATS do
      t.cursor(l)
      times[i] = time_ms(function() t.keys(i % 2 == 0 and "S-<right>" or "S-<left>") end)
      if i == 10 then
        b0, m0, heap0 = emacs_buffers(), marks(), emacs_heap_kb(t)
        collectgarbage()
        lua0 = collectgarbage("count")
      end
    end
    local function mean(a, b)
      local s = 0
      for i = a, b do s = s + times[i] end
      return s / (b - a + 1)
    end
    local early, late = mean(11, 30), mean(REPEATS - 19, REPEATS)
    report("S-left/right mean, repeats 11-30", early)
    report("S-left/right mean, last 20", late)
    t.eq(emacs_buffers(), b0, "Emacs buffer count")
    t.eq(marks(), m0, "Neovim extmark count")
    local heap = emacs_heap_kb(t)
    collectgarbage()
    local lua = collectgarbage("count")
    report("Emacs heap growth", heap - heap0, "KB")
    report("Neovim Lua heap growth", lua - lua0, "KB")
    assert(heap - heap0 < 1024, ("Emacs heap grew %d KB"):format(heap - heap0))
    assert(lua - lua0 < 1024, ("Lua heap grew %d KB"):format(lua - lua0))
    assert(late < early * 1.5 + 5, ("time grew: %.1f -> %.1f ms"):format(early, late))
    within("S-left/right, last 20 mean", late)
  end,

  -- A command on a big file should cost Emacs little more garbage than the
  -- command itself: past gc-cons-threshold (800 KB) every command collects,
  -- and a collection with five such files loaded takes 100+ ms.
  ["a command allocates about what Emacs's own command does"] = function(t)
    local path = open_big(t, "alloc.org")
    local l = t.find_line("^%*%* Task alloc%-1502 ")
    t.cursor(l)
    t.keys("S-<right>")
    local before = emacs_alloc(t)
    t.cursor(l)
    t.keys("S-<right>")
    local bridge = emacs_alloc(t) - before
    -- The same command in a copy of the buffer Neovim doesn't see.
    t.eval(([[(with-current-buffer (get-buffer-create "alloc-copy")
      (insert-buffer-substring (get-file-buffer %q)) (org-mode)
      (goto-char (point-min)) (forward-line %d))]]):format(path, l - 1))
    t.after(function() t.eval('(kill-buffer "alloc-copy")') end)
    before = emacs_alloc(t)
    t.eval('(with-current-buffer "alloc-copy" (org-shiftright))')
    local own = emacs_alloc(t) - before
    io.stdout:write(("  S-right allocates %d KB through the bridge, %d KB alone\n"):format(bridge / 1024, own / 1024))
    local threshold = tonumber(t.eval("gc-cons-threshold"))
    assert(bridge < own + threshold, ("bridge allocated %d KB for a %d KB command"):format(bridge / 1024, own / 1024))
  end,
}

-- Every case fails at its end with all the budget overruns it noted.
for name, case in pairs(cases) do
  cases[name] = function(t)
    overruns = {}
    case(t)
    check_budget()
  end
end
return cases
