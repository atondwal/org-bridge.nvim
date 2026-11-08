-- A realistic user org configuration (hidden markup, pretty entities,
-- startup folding and indent, several TODO sequences with faces, tag groups,
-- priority faces, special C-a/C-e, M-RET settings, custom agenda commands).
-- Expected results: emacs -Q --batch -l test/init.el with the same settings.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")

local DOC = "* TODO A\nbody a\n** NEXT A1\ntext\n\n* WAIT B :urgent:\nbody b\n* [#A] C\n"

-- The user's settings; `startup` is org-startup-folded.
local function user_config(t, startup)
  t.set("org-hide-emphasis-markers", "t")
  t.set("org-pretty-entities", "t")
  t.set("org-startup-indented", "t")
  t.set("org-ellipsis", '" ▾"')
  t.set("org-startup-folded", "'" .. startup)
  t.set("org-todo-keywords", [['((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d)")
    (sequence "WAIT(w)" "HOLD(h)" "|" "CANCELLED(c)"))]])
  t.set("org-todo-keyword-faces", [['(("WAIT" . (:foreground "orange" :weight bold)) ("CANCELLED" . "gray"))]])
  t.set("org-tag-alist", [['((:startgroup) ("@home" . ?h) ("@work" . ?w) (:endgroup) ("urgent" . ?u))]])
  t.set("org-fast-tag-selection-single-key", "t")
  t.set("org-priority-faces", [['((?A . (:foreground "red")) (?B . "orange"))]])
  t.set("org-log-into-drawer", "t")
  t.set("org-special-ctrl-a/e", "t")
  t.set("org-M-RET-may-split-line", "nil")
  t.set("org-insert-heading-respect-content", "t")
  t.set("org-cycle-separator-lines", "1")
end

local function marks(row)
  return api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })
end

-- Foreground of the highest-priority highlight covering (row, col).
local function fg_at(row, col)
  local best
  for _, m in ipairs(marks(row)) do
    local d = m[4]
    if d.hl_group and m[3] <= col and col < (d.end_col or m[3] + 1)
      and (not best or (d.priority or 0) > (best.priority or 0)) then
      best = d
    end
  end
  assert(best, ("no highlight at %d:%d"):format(row, col))
  return api.nvim_get_hl(0, { name = best.hl_group, link = false }).fg
end

local function conceals(row)
  local out = {}
  for _, m in ipairs(marks(row)) do
    if m[4].conceal then out[#out + 1] = { m[3], m[4].end_col, m[4].conceal } end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

-- Inline virtual text at the start of `row` as { text, hl } chunks.
local function inline_prefix(row)
  for _, m in ipairs(marks(row)) do
    if m[3] == 0 and m[4].virt_text_pos == "inline" then return m[4].virt_text end
  end
end

local function pos() return api.nvim_win_get_cursor(0) end

return {
  -- A leftover vim-orgmode `nmap <C-c><C-c> ...` swallowed a fast C-c C-c.
  [":checkhealth names global mappings that take org keys typed fast"] = function(t)
    local health = require("emacs.health")
    t.eq(health.shadowing_maps(), {})
    vim.keymap.set("n", "<C-c><C-c>", "<Nop>")
    t.after(function() vim.keymap.del("n", "<C-c><C-c>") end)
    t.eq(health.shadowing_maps(), { "n <C-C><C-C>" })
  end,

  -- Emacs: lines 2, 4 and 7 invisible; the blank line 5 stays visible
  -- (org-cycle-separator-lines 1).
  ["org-startup-folded content shows the headings and ends folds with ▾"] = function(t)
    user_config(t, "content")
    t.open("uc_content.org", DOC)
    t.eq(t.folds(), { "1-2", "3-4", "6-7" })
    t.eq(vim.fn.foldtextresult(1), "* TODO A ▾")
  end,

  -- Emacs: S-TAB after a content startup is OVERVIEW (2-4 hidden, 5 shown),
  -- then TAB on A shows its children (only 4 hidden), TAB again all of it.
  ["S-TAB then TAB TAB after a content startup cycle as in Emacs"] = function(t)
    user_config(t, "content")
    t.open("uc_cycle.org", DOC)
    t.keys("S-TAB")
    t.eq(t.folds(), { "1-4", "6-7" }, "overview")
    t.cursor(1)
    t.keys("TAB")
    t.eq(t.folds(), { "3-4", "6-7" }, "children")
    t.keys("TAB")
    t.eq(t.folds(), { "6-7" }, "subtree")
  end,

  ["org-startup-folded showeverything leaves every line open"] = function(t)
    user_config(t, "showeverything")
    t.open("uc_all.org", DOC)
    t.eq(t.folds(), {})
  end,

  -- Emacs: the body under ** gets line-prefix "    "; the ** heading gets
  -- "*" in face org-indent (drawn in the background color, so blank).
  ["org-startup-indented prefixes are drawn, a heading's one invisibly"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    user_config(t, "showeverything")
    t.open("uc_indent.org", DOC)
    t.eq(t.eval('(with-current-buffer "uc_indent.org" org-indent-mode)'), "t", "org-indent-mode")
    t.eq(inline_prefix(3)[1][1], "    ", "body under ** A1")
    local head = inline_prefix(2)
    assert(head, "no prefix on ** A1")
    local text, hl = head[1][1], head[1][2]
    local fg = api.nvim_get_hl(0, { name = hl, link = false }).fg
    local bg = api.nvim_get_hl(0, { name = "Normal" }).bg
    assert(text:match("^%s*$") or (fg and fg == bg),
      ("** A1's prefix %q is drawn visibly in %s"):format(text, hl))
  end,

  -- Emacs: the * markers, the _ of a_1 are invisible; \alpha is composed
  -- as α (both settings on from startup, no C-c C-x \).
  ["hidden emphasis markers and pretty entities from the config are concealed"] = function(t)
    t.config("conceal", true)
    user_config(t, "showeverything")
    t.open("uc_pretty.org", "x *Bob* \\alpha a_1\n")
    t.eq(conceals(0), { { 2, 3, "" }, { 6, 7, "" }, { 8, 14, "α" }, { 16, 17, "" } })
  end,

  -- Emacs: WAIT's face is (:foreground "orange" :weight bold) over
  -- org-level-1; CANCELLED's (:inherit org-todo :foreground "gray"); [#A]
  -- (:foreground "red"), [#B] (:inherit org-priority :foreground "orange").
  ["org-todo-keyword-faces and org-priority-faces color their text"] = function(t)
    user_config(t, "showeverything")
    t.open("uc_faces.org", "* WAIT Call\n** CANCELLED Old [#A] x\n* [#B] y\n")
    local orange, gray, red = api.nvim_get_color_by_name("orange"), api.nvim_get_color_by_name("gray"),
      api.nvim_get_color_by_name("red")
    t.eq(fg_at(0, 2), orange, "WAIT")
    t.eq(fg_at(1, 3), gray, "CANCELLED")
    t.eq(fg_at(1, 17), red, "[#A]")
    t.eq(fg_at(2, 2), orange, "[#B]")
  end,

  -- Emacs: C-c C-t w gives WAIT; C-S-right from TODO switches to the
  -- second sequence (WAIT); S-right then cycles WAIT -> HOLD -> CANCELLED.
  ["two TODO sequences: fast keys, C-S-right and S-right"] = function(t)
    user_config(t, "showeverything")
    local path = t.open("uc_todo.org", "* A\n* TODO B\n")
    t.answer("w")
    t.keys("C-c C-t")
    t.eq(t.lines()[1], "* WAIT A", "C-c C-t w")
    t.cursor(2)
    t.keys("C-S-<right>")
    t.eq(t.lines()[2], "* WAIT B", "C-S-right")
    t.keys("S-<right>")
    t.eq(t.lines()[2], "* HOLD B", "S-right")
    t.keys("S-<right>")
    t.eq(t.lines()[2], "* CANCELLED B", "S-right again")
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  -- Emacs (single-key selection): C-c C-q h tags @home and exits; C-c C-q u
  -- adds urgent; C-c C-q w swaps @home for @work (same group).
  ["fast tag selection takes one key and keeps groups exclusive"] = function(t)
    user_config(t, "showeverything")
    t.open("uc_tags.org", "* Task\nbody\n")
    t.answer("h")
    t.keys("C-c C-q")
    t.eq(t.lines()[1], t.aligned("* Task", ":@home:"), "h")
    t.answer("u")
    t.keys("C-c C-q")
    t.eq(t.lines()[1], t.aligned("* Task", ":@home:urgent:"), "u")
    t.answer("w")
    t.keys("C-c C-q")
    t.eq(t.lines()[1], t.aligned("* Task", ":@work:urgent:"), "w")
    t.eq(#t.asked(), 3, "one key per command")
  end,

  -- Emacs: with org-special-ctrl-a/e, C-a from the end goes to the title
  -- (col 12), C-e from inside the title stops before the tags (col 21) and
  -- a second C-e goes to the end of the line (col 32).
  ["org-special-ctrl-a/e: C-a and C-e skip the keyword and the tags"] = function(t)
    user_config(t, "showeverything")
    t.open("uc_ctrla.org", "* TODO [#A] Task here      :tag:\n")
    t.cursor(1, 31)
    t.keys("C-a")
    t.eq(pos(), { 1, 12 }, "C-a")
    t.cursor(1, 3)
    t.keys("C-e")
    t.eq(pos(), { 1, 21 }, "C-e")
  end,

  -- Emacs: M-RET in "report" neither splits the heading nor lands below
  -- it: the new heading goes after the subtree (respect-content), line 5.
  ["M-RET mid-heading with may-split nil and respect-content adds after the subtree"] = function(t)
    user_config(t, "showeverything")
    local path = t.open("uc_mret.org", "* TODO Write report\nbody\n** Sub\nx\n* B\n")
    t.cursor(1, 15)
    t.keys("M-RET")
    t.eq(t.lines(), { "* TODO Write report", "body", "** Sub", "x", "* ", "* B" })
    -- Emacs's point is after "* "; Normal mode puts the cursor on the space.
    t.eq(pos(), { 5, 1 }, "cursor on the new heading")
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  -- Emacs: after a content startup, M-RET at the end of * A adds "* " at
  -- line 5 and reveals A's body; only "text" and "body b" stay hidden.
  ["M-RET on a heading folded by a content startup inserts after its subtree"] = function(t)
    user_config(t, "content")
    t.open("uc_mret_fold.org", "* A\nbody a\n** A1\ntext\n* B\nbody b\n")
    t.cursor(1, 2)
    t.keys("M-RET")
    t.feed("<Esc>")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "* ", "* B", "body b" })
    t.eq(t.folds(), { "3-4", "6-7" })
  end,

  -- Emacs: C-e RET on a folded * A (content startup) opens a line right
  -- under the heading; README says Normal-mode o is C-e RET.
  ["o on a heading folded by a content startup opens a line under it"] = function(t)
    user_config(t, "content")
    local path = t.open("uc_o_fold.org", "* A\nbody a\n* B\n")
    t.cursor(1)
    t.feed("onew<Esc>")
    t.eq(t.lines(), { "* A", "new", "body a", "* B" })
    mirror.sync()
    t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
  end,

  -- Emacs: with org-special-ctrl-a/e, C-e stops before the tags and RET
  -- there realigns them before opening the line.
  ["o on a heading with tags matches C-e RET under org-special-ctrl-a/e"] = function(t)
    user_config(t, "showeverything")
    t.open("uc_o_tags.org", "* Task here      :tag:\nbody\n")
    t.cursor(1)
    t.feed("onew<Esc>")
    t.eq(t.lines(), { t.aligned("* Task here", ":tag:"), "new", "body" })
  end,

  -- Emacs (org-agenda nil "x" / "u"): the block agenda lists WAIT items,
  -- a separator, then urgent TODOs; "u" matches @work|urgent, not DONE.
  ["custom agenda commands: a block agenda and a tags-todo match"] = function(t)
    user_config(t, "showeverything")
    t.eval("(require 'org-agenda)")
    t.set("org-agenda-custom-commands", [['(("x" "Block" ((todo "WAIT") (tags-todo "urgent")))
      ("u" "Urgent at work" tags-todo "@work|urgent"))]])
    local path = t.open("uc_ag.org",
      "* TODO Write report :@work:\n* WAIT Call Bob :urgent:\n* NEXT Buy milk :@home:\n* DONE Old :urgent:\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    local function squeezed()
      return vim.tbl_map(function(l) return (l:gsub("%s+", " ")) end, t.lines())
    end
    t.answer("x")
    t.command("org-agenda")
    local lines = squeezed()
    t.eq(lines[1], "Global list of TODO items of type: WAIT", "first block")
    t.eq(lines[2], " uc_ag: WAIT Call Bob :urgent:")
    assert(lines[4]:match("^=+$"), "block separator: " .. tostring(lines[4]))
    t.eq({ lines[5], lines[6] }, { "Headlines with TAGS match: urgent", " uc_ag: WAIT Call Bob :urgent:" })
    vim.cmd("only")
    t.answer("u")
    t.command("org-agenda")
    lines = squeezed()
    t.eq(lines[1], "Headlines with TAGS match: @work|urgent")
    t.eq({ lines[3], lines[4] }, { " uc_ag: TODO Write report :@work:", " uc_ag: WAIT Call Bob :urgent:" })
    t.eq(lines[5] == nil or lines[5] == "", true, "nothing else listed")
  end,
}
