-- Clock reports and dynamic blocks. Expected text is what the same command
-- leaves in emacs -Q --batch -l test/init.el (org 9.6.15). There, C-c C-x
-- C-r is org-toggle-radio-button and C-c C-x C-u is org-dblock-update;
-- org-clock-report has no key.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")

local LOG = {
  "* A",
  ":LOGBOOK:",
  "CLOCK: [2026-11-02 Mon 09:00]--[2026-11-02 Mon 10:30] =>  1:30",
  ":END:",
  "** A1",
  ":LOGBOOK:",
  "CLOCK: [2026-11-03 Tue 09:00]--[2026-11-03 Tue 09:45] =>  0:45",
  ":END:",
  "* B",
  ":LOGBOOK:",
  "CLOCK: [2026-11-04 Wed 14:00]--[2026-11-04 Wed 16:00] =>  2:00",
  ":END:",
  "* Report",
}
local DOC = table.concat(LOG, "\n") .. "\n"

-- Two empty clocktables after LOG; the first starts on line 14.
local STALE = DOC .. table.concat({
  "#+BEGIN: clocktable :scope file :maxlevel 1",
  "#+END:",
  "text",
  '#+BEGIN: clocktable :scope file :maxlevel 2 :header "#+NAME: two\\n"',
  "#+END:",
  "",
}, "\n")

local CAPTION = "#+CAPTION: Clock summary at [NOW]"

local LEVEL1 = {
  "#+BEGIN: clocktable :scope file :maxlevel 1",
  CAPTION,
  "| Headline     |   Time |",
  "|--------------+--------|",
  "| *Total time* | *4:15* |",
  "|--------------+--------|",
  "| A            |   2:15 |",
  "| B            |   2:00 |",
  "#+END:",
}

local LEVEL2_ROWS = {
  "| Headline     |   Time |      |",
  "|--------------+--------+------|",
  "| *Total time* | *4:15* |      |",
  "|--------------+--------+------|",
  "| A            |   2:15 |      |",
  "| \\_  A1       |        | 0:45 |",
  "| B            |   2:00 |      |",
}

local EMPTY_SUBTREE = {
  "#+BEGIN: clocktable :scope subtree :maxlevel 2",
  CAPTION,
  "| Headline     | Time   |",
  "|--------------+--------|",
  "| *Total time* | *0:00* |",
  "#+END:",
  "",
}

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do vim.list_extend(out, list) end
  return out
end

-- Buffer lines with the clocktable's timestamp replaced by NOW.
local function lines(t)
  return vim.tbl_map(function(l)
    return (l:gsub("^#%+CAPTION: Clock summary at %[[^]]+%]$", CAPTION))
  end, t.lines())
end

local function overlay_count(t, name)
  return t.eval(([[(with-current-buffer %q (length org-clock-overlays))]]):format(name))
end

-- Inline virtual text Neovim draws on `row` (0-based), concatenated.
local function virt_text(row)
  local s = ""
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do s = s .. chunk[1] end
  end
  return s
end

local function refetch_spans()
  local buf = api.nvim_get_current_buf()
  mirror.state[buf].spans = nil
  mirror.refresh_spans(buf)
end

-- The string org-clock-put-overlay draws over the title of a heading with
-- `stars` stars: dots pad the title to column 60.
local function clock_overlay(stars, title, time)
  return title .. string.rep("·", 60 - stars - 1 - #title) .. (" %9s "):format(time)
end

return {
  ["C-c C-x C-r toggles a radio-button list"] = function(t)
    t.open("radio.org", "- [ ] a\n- [X] b\n")
    t.keys("C-c C-x C-r")
    t.eq(t.lines(), { "- [X] a", "- [ ] b" })
  end,

  ["org-clock-report before the first heading inserts a file table"] = function(t)
    t.open("report_file.org", "intro\n" .. DOC)
    t.command("org-clock-report")
    t.eq(lines(t), concat({ "intro", "#+BEGIN: clocktable :scope file :maxlevel 2", CAPTION },
      LEVEL2_ROWS, { "#+END:", "" }, LOG))
    t.eq(api.nvim_win_get_cursor(0)[1], 2, "point on #+BEGIN:")
  end,

  ["C-c C-c on #+BEGIN: fills only that clocktable"] = function(t)
    t.open("ctrlc.org", STALE)
    t.cursor(14)
    t.keys("C-c C-c")
    t.eq(lines(t), concat(LOG, LEVEL1, { "text",
      '#+BEGIN: clocktable :scope file :maxlevel 2 :header "#+NAME: two\\n"', "#+END:" }))
    t.eq(api.nvim_win_get_cursor(0)[1], 14, "point stays on #+BEGIN:")
  end,

  ["C-u C-c C-x C-u updates every dynamic block"] = function(t)
    t.open("dbu_all.org", STALE)
    t.keys("C-c C-x C-u", 4)
    t.eq(lines(t), concat(LOG, LEVEL1, { "text",
      '#+BEGIN: clocktable :scope file :maxlevel 2 :header "#+NAME: two\\n"', "#+NAME: two" },
      LEVEL2_ROWS, { "#+END:" }))
    t.eq(api.nvim_win_get_cursor(0)[1], 1, "point stays")
  end,

  ["C-u org-clock-report updates the first clocktable only"] = function(t)
    t.open("report_first.org", STALE)
    vim.cmd("normal! G")
    mirror.exec({ command = "org-clock-report", count = 4 })
    t.eq(lines(t), concat(LOG, LEVEL1, { "text",
      '#+BEGIN: clocktable :scope file :maxlevel 2 :header "#+NAME: two\\n"', "#+END:" }))
    t.eq(api.nvim_win_get_cursor(0)[1], 14, "point on the first #+BEGIN:")
  end,

  ["C-c C-x x clocktable asks for the block type and inserts a subtree table"] = function(t)
    t.open("insert_ct.org", DOC)
    t.cursor(13)
    t.answer("clocktable")
    t.keys("C-c C-x x")
    t.eq(t.asked()[1].params.prompt, "Dynamic block: ")
    t.eq(lines(t), concat(LOG, EMPTY_SUBTREE))
  end,

  ["C-c C-x x columnview asks for the scope and fills the block"] = function(t)
    t.open("insert_cv.org", "* TODO A\n:PROPERTIES:\n:Effort: 1:00\n:END:\n* B\n")
    t.cursor(5)
    t.answer("columnview", "global")
    t.keys("C-c C-x x")
    t.eq(t.asked()[2].params.prompt, "Capture columns (local, global, entry with :ID: property) [local]: ")
    t.eq(t.lines(), {
      "* TODO A", ":PROPERTIES:", ":Effort: 1:00", ":END:",
      -- Real Emacs leaves this trailing space too.
      "* B ",
      "#+BEGIN: columnview :hlines 1 :id global",
      "| ITEM | TODO | PRIORITY | TAGS |",
      "|------+------+----------+------|",
      "| A    | TODO | B        |      |",
      "|------+------+----------+------|",
      "| B    |      | B        |      |",
      "#+END:",
      "",
    })
  end,

  ["C-c C-x C-d draws subtree times as virtual text, text unchanged"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    t.open("display.org", DOC)
    t.keys("C-c C-x C-d")
    t.eq(t.lines(), LOG, "text unchanged")
    t.eq(overlay_count(t, "display.org"), "3")
    t.eq({ virt_text(0), virt_text(4), virt_text(8) },
      { clock_overlay(1, "A", "2:15"), clock_overlay(2, "A1", "0:45"), clock_overlay(1, "B", "2:00") })
  end,

  ["clock overlays go away on C-c C-c and on an edit made in Neovim"] = function(t)
    t.open("display_rm.org", DOC)
    t.keys("C-c C-x C-d")
    t.keys("C-c C-c")
    t.eq(overlay_count(t, "display_rm.org"), "0", "after C-c C-c")
    t.eq(virt_text(0), "", "virtual text after C-c C-c")
    t.keys("C-c C-x C-d")
    api.nvim_buf_set_lines(0, 13, 13, false, { "x" })
    mirror.sync()
    t.eq(overlay_count(t, "display_rm.org"), "0", "after an edit")
    refetch_spans()
    t.eq(virt_text(0), "", "virtual text after an edit")
  end,

  ["C-u C-u C-c C-x C-d asks for a range"] = function(t)
    local day = os.date("%Y-%m-%d %a")
    t.open("display_range.org", ("* Today\nCLOCK: [%s 09:00]--[%s 10:00] =>  1:00\n"):format(day, day))
    t.answer("today")
    t.keys("C-c C-x C-d", 16)
    t.eq(t.asked()[1].params.prompt, "Range: ")
    t.eq(overlay_count(t, "display_range.org"), "1")
    t.eq(t.eval([[(with-current-buffer "display_range.org"
      (substring-no-properties (overlay-get (car org-clock-overlays) 'display)))]]),
      '"' .. clock_overlay(1, "Today", "1:00") .. '"')
  end,

  -- Emacs draws the dots in shadow and the time in org-clock-overlay.
  ["clock overlay keeps its two faces in Neovim"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    t.open("display_faces.org", DOC)
    t.keys("C-c C-x C-d")
    local groups = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(0, NS, { 0, 0 }, { 0, -1 }, { details = true })) do
      for _, chunk in ipairs(m[4].virt_text or {}) do groups[#groups + 1] = { chunk[1], chunk[2] } end
    end
    t.eq(groups, {
      { "A", "EmacsFace_org_level_1" },
      { string.rep("·", 57), "EmacsFace_shadow" },
      { "      2:15 ", "EmacsFace_org_clock_overlay" },
    })
  end,

  ["TAB folding keeps the clock overlays; C-c C-t drops them"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    t.open("display_fold.org", DOC)
    t.keys("C-c C-x C-d")
    t.keys("TAB")
    t.eq(overlay_count(t, "display_fold.org"), "3", "after TAB")
    t.eq(virt_text(0), clock_overlay(1, "A", "2:15"), "virtual text on the folded heading")
    t.cursor(9)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[9], "* TODO B")
    t.eq(overlay_count(t, "display_fold.org"), "0", "after C-c C-t")
    t.eq(virt_text(8), "", "virtual text after C-c C-t")
  end,
}
