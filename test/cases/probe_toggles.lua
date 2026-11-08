-- Toggles and small editing commands: fixed width, emphasis, pretty
-- entities, custom time stamps, ORDERED, ARCHIVE, effort steps, C-c RET,
-- C-c TAB, and the C-S-arrow commands (keyword sets, clock lines).
local api = vim.api

local NS = api.nvim_create_namespace("emacs")

local function cursor() return api.nvim_win_get_cursor(0) end

local function messages() return vim.fn.execute("messages") end

local function marks(row)
  return api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })
end

-- Line `row` (0-based) as Neovim draws it off the cursor line: concealed
-- text dropped (when 'conceallevel' shows it), conceal replacements and
-- inline virtual text inserted.
local function drawn(row)
  local line = api.nvim_buf_get_lines(0, row, row + 1, false)[1]
  local hidden, inserts = {}, {}
  for _, m in ipairs(marks(row)) do
    local d = m[4]
    if d.conceal and vim.wo.conceallevel > 0 then
      for b = m[3] + 1, d.end_col do hidden[b] = true end
      inserts[m[3]] = (inserts[m[3]] or "") .. d.conceal
    end
    if d.virt_text and d.virt_text_pos == "inline" then
      for _, chunk in ipairs(d.virt_text) do inserts[m[3]] = (inserts[m[3]] or "") .. chunk[1] end
    end
  end
  local out = {}
  for b = 0, #line do
    out[#out + 1] = inserts[b]
    if b < #line and not hidden[b + 1] then out[#out + 1] = line:sub(b + 1, b + 1) end
  end
  return table.concat(out)
end

-- Line numbers Neovim shows: not inside a closed fold, or its first line.
local function visible()
  local out = {}
  for l = 1, vim.fn.line("$") do
    local start = vim.fn.foldclosed(l)
    if start == -1 or start == l then out[#out + 1] = l end
  end
  return out
end

local TWO_SETS = [['((sequence "TODO" "|" "DONE") (sequence "BUG" "FIX" "|" "FIXED"))]]

local CLOCK = "* T\n:LOGBOOK:\nCLOCK: [2026-11-02 Mon 10:00]--[2026-11-02 Mon 11:00] =>  1:00\n:END:\n"

return {
  ["C-c : toggles a fixed-width line, and every line of a Visual selection"] = function(t)
    t.open("fixed.org", "* H\nfoo\nbar\n")
    t.cursor(2)
    t.keys("C-c :")
    t.eq(t.lines(), { "* H", ": foo", "bar" })
    t.eq(cursor(), { 2, 2 })
    t.keys("C-c :")
    t.eq(t.lines(), { "* H", "foo", "bar" }, "toggled back")
    t.cursor(2)
    t.answer(":")
    t.feed("Vj<C-c>")
    t.eq(t.lines(), { "* H", ": foo", ": bar" }, "Visual lines")
  end,

  ["C-c C-x C-f asks for a marker and inserts an empty pair"] = function(t)
    t.open("emph.org", "x word y\n")
    t.cursor(1, 2)
    t.answer("*")
    t.keys("C-c C-x C-f")
    t.eq(t.asked()[1].params.prompt, "Emphasis marker or tag: [*/_=~+]")
    t.eq(t.lines(), { "x ** word y" })
    t.eq(cursor(), { 1, 3 }, "point between the markers")
  end,

  ["C-c C-x C-f on a Visual selection wraps it, SPC removes the markers"] = function(t)
    t.open("emphv.org", "x word y\n")
    t.cursor(1, 2)
    t.answer("C-x", "C-f", "/")
    t.feed("viw<C-c>")
    t.eq(t.lines(), { "x /word/ y" })
    t.cursor(1, 2)
    t.answer("C-x", "C-f", "SPC")
    t.feed("v5l<C-c>")
    t.eq(t.lines(), { "x word y" }, "SPC on /word/ removes the emphasis")
  end,

  -- Emacs draws \alpha as α (a composition) once org-pretty-entities is on.
  ["C-c C-x \\ shows \\alpha as α with the default config"] = function(t)
    t.open("pretty.org", "x \\alpha y\nnext\n")
    t.cursor(2)
    t.keys("C-c C-x \\")
    t.eq(t.eval('(with-current-buffer "pretty.org" org-pretty-entities)'), "t")
    t.eq(drawn(0), "x α y")
    t.keys("C-c C-x \\")
    t.eq(drawn(0), "x \\alpha y", "toggled off")
  end,

  ["C-c C-x C-t draws time stamps in org-time-stamp-custom-formats"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("a replacement of another width needs inline virtual text") end
    t.set("org-time-stamp-custom-formats", [['("<%d.%m.%Y>" . "<%d.%m.%Y %H:%M>")]])
    t.set("org-display-custom-times", "nil")
    t.open("custom.org", "* H\nSCHEDULED: <2026-11-09 Mon>\nat <2026-11-10 Tue 14:30> x\n")
    t.keys("C-c C-x C-t")
    assert(messages():find("Time stamps are overlaid with custom format", 1, true), messages())
    t.eq({ drawn(1), drawn(2) }, { "SCHEDULED: <09.11.2026>", "at <10.11.2026 14:30> x" })
    t.keys("C-c C-x C-t")
    t.eq({ drawn(1), drawn(2) }, { "SCHEDULED: <2026-11-09 Mon>", "at <2026-11-10 Tue 14:30> x" },
      "toggled off")
    t.eq(t.lines()[2], "SCHEDULED: <2026-11-09 Mon>", "text unchanged")
  end,

  ["C-c C-x o toggles the ORDERED property"] = function(t)
    t.open("ordered.org", "* H\nbody\n** a\n")
    t.keys("C-c C-x o")
    t.eq(t.lines(), { "* H", ":PROPERTIES:", ":ORDERED:  t", ":END:", "body", "** a" })
    assert(messages():find("Subtasks must be completed in sequence", 1, true), messages())
    t.keys("C-c C-x o")
    t.eq(t.lines(), { "* H", "body", "** a" }, "removed again")
    assert(messages():find("Subtasks can be completed in arbitrary order", 1, true), messages())
  end,

  ["C-c C-x a adds the ARCHIVE tag and folds the subtree, then removes it"] = function(t)
    t.open("archtag.org", "* H\nbody\n** a\n* B\n")
    t.keys("C-c C-x a")
    t.eq(t.lines(), { t.aligned("* H", ":ARCHIVE:"), "body", "** a", "* B" })
    t.eq(t.folds(), { "1-3" }, "subtree folded")
    t.keys("C-c C-x a")
    t.eq(t.lines(), { "* H", "body", "** a", "* B" })
    assert(messages():find("Subtree unarchived", 1, true), messages())
    t.open("archtag2.org", "* H :x:\nbody\n")
    t.keys("C-c C-x a")
    t.eq(t.lines()[1], t.aligned("* H", ":x:ARCHIVE:"), "joins existing tags")
  end,

  ["C-c C-x E steps Effort to the next allowed value"] = function(t)
    t.open("effort.org", "#+PROPERTY: Effort_ALL 0 0:10 0:30 1:00\n* H\n:PROPERTIES:\n:Effort:   0:10\n:END:\n")
    t.cursor(2)
    t.keys("C-c C-x E")
    t.eq(t.lines()[4], ":Effort:   0:30")
    assert(messages():find("Effort is now 0:30", 1, true), messages())
    t.open("effort_none.org", "* H\n")
    vim.cmd("messages clear")
    t.keys("C-c C-x E")
    t.eq(t.lines(), { "* H" })
    assert(messages():find("Allowed effort values are not set", 1, true), messages())
  end,

  ["C-c RET adds a table hline, or makes a heading of a plain line"] = function(t)
    t.open("cret_tbl.org", "| a | b |\n| 1 | 2 |\n")
    t.cursor(1, 2)
    t.keys("C-c RET")
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 | 2 |" })
    t.eq(cursor(), { 3, 2 })
    t.open("cret_head.org", "* A\nbody\n** A1\n")
    t.cursor(2)
    t.keys("C-c RET")
    t.eq(t.lines(), { "* A", "* body", "** A1" })
    t.eq(cursor(), { 2, 2 })
  end,

  ["C-c TAB on a heading shows only its child headings"] = function(t)
    t.open("ctab.org", "* A\nbody\n** A1\ntext\n*** A2\n* B\n")
    t.keys("S-TAB")
    t.keys("C-c TAB")
    t.eq(visible(), { 1, 3, 6 })
  end,

  -- Emacs shrinks the column to width 0: each cell drawn as "…".
  ["C-c TAB in a table shrinks the column"] = function(t)
    t.config("conceal", true)
    t.open("ctab_tbl.org", "| a | b |\n| abcdef | 2 |\n")
    t.cursor(2, 3)
    t.keys("C-c TAB")
    t.cursor(1)
    t.eq(drawn(1), "|…| 2 |")
    t.cursor(2)
    t.eq(drawn(0), "|…| b |")
    t.eq(t.lines(), { "| a | b |", "| abcdef | 2 |" }, "text unchanged")
  end,

  ["C-S-right/left switch the TODO keyword set"] = function(t)
    t.set("org-todo-keywords", TWO_SETS)
    t.open("sets.org", "* TODO a\n* DONE b\n* c\n")
    t.keys("C-S-<right>")
    t.eq(t.lines()[1], "* BUG a")
    assert(messages():find("Keyword-Set 2/2: BUG FIX FIXED", 1, true), messages())
    t.keys("C-S-<right>")
    t.eq(t.lines()[1], "* TODO a", "wraps to the first set")
    t.cursor(2)
    t.keys("C-S-<left>")
    t.eq(t.lines()[2], "* BUG b", "from DONE back to the other set")
    t.cursor(3)
    t.keys("C-S-<right>")
    t.eq(t.lines()[3], "* TODO c", "no keyword: first set")
  end,

  ["C-S-Right typed in Neovim switches the keyword set"] = function(t)
    t.set("org-todo-keywords", TWO_SETS)
    t.open("sets_feed.org", "* TODO a\n")
    t.feed("<C-S-Right>")
    t.eq(t.lines(), { "* BUG a" })
  end,

  -- org-clock-timestamps-up isn't autoloaded: Emacs -Q has it once
  -- org-clock is loaded (any clock command loads it).
  ["C-S-up/down on a clock line shift both ends together"] = function(t)
    t.eval("(require 'org-clock)")
    t.open("clockshift.org", CLOCK)
    t.cursor(3, 26)
    t.keys("C-S-<up>")
    t.eq(t.lines()[3], "CLOCK: [2026-11-02 Mon 10:05]--[2026-11-02 Mon 11:05] =>  1:00", "minutes")
    t.eq(cursor(), { 3, 26 })
    t.cursor(3, 47)
    t.keys("C-S-<down>")
    t.eq(t.lines()[3], "CLOCK: [2026-11-02 Mon 09:05]--[2026-11-02 Mon 10:05] =>  1:00", "hours, on the end")
    t.cursor(3, 15)
    t.keys("C-S-<up>")
    t.eq(t.lines()[3], "CLOCK: [2026-12-02 Wed 09:05]--[2026-12-02 Wed 10:05] =>  1:00", "months")
  end,

  ["C-S-Up typed in Neovim shifts a clock line"] = function(t)
    t.eval("(require 'org-clock)")
    t.open("clockfeed.org", CLOCK)
    t.cursor(3, 26)
    t.feed("<C-S-Up>")
    t.eq(t.lines()[3], "CLOCK: [2026-11-02 Mon 10:05]--[2026-11-02 Mon 11:05] =>  1:00")
  end,
}
