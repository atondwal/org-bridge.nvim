-- Org configuration changed while running: #+TODO/#+STARTUP/#+TAGS/#+PROPERTY
-- refreshed with C-c C-c, variables set with :EmacsEval then org-mode-restart,
-- M-x org-indent-mode, org-agenda-files, and a face changed with set-face-attribute.
-- Expected text: emacs -Q --batch -l test/init.el, the same keys as commands.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

local function marks(row)
  return api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })
end

-- Inline virtual text at the start of `row`, or nil.
local function inline_prefix(row)
  for _, m in ipairs(marks(row)) do
    if m[3] == 0 and m[4].virt_text_pos == "inline" then return m[4].virt_text[1][1] end
  end
end

local function conceals(row)
  local out = {}
  for _, m in ipairs(marks(row)) do
    if m[4].conceal then out[#out + 1] = { m[3], m[4].end_col, m[4].conceal } end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
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

-- Replace line `row` (1-based) as typed in Neovim.
local function set_line(row, text)
  api.nvim_buf_set_lines(0, row - 1, row, false, { text })
end

return {
  -- Emacs: C-c C-c restarts org with OPEN WAIT | CLOSED; S-right then gives
  -- "* OPEN TODO x" (TODO is no keyword now) and a second one WAIT.
  ["C-c C-c on an edited #+TODO: line switches the keywords"] = function(t)
    local path = t.open("lc_todo.org", "#+TODO: TODO DONE\n* TODO x\n")
    set_line(1, "#+TODO: OPEN WAIT | CLOSED")
    t.cursor(1)
    t.keys("C-c C-c")
    t.cursor(2)
    t.keys("S-<right>")
    t.eq(t.lines()[2], "* OPEN TODO x", "first S-right")
    t.keys("S-<right>")
    t.eq(t.lines()[2], "* WAIT TODO x", "second S-right")
    agree(t, path)
    t.eq(fg_at(1, 2), api.nvim_get_hl(0, { name = "EmacsFace_org_todo", link = false }).fg, "WAIT in org-todo")
  end,

  -- Emacs: before the restart S-right uses the old keywords (NEXT); after
  -- M-x org-mode-restart it uses A B | C and NEXT is plain text.
  ["org-todo-keywords set with :EmacsEval apply after M-x org-mode-restart"] = function(t)
    local path = t.open("lc_kw.org", "* TODO x\n")
    t.set("org-todo-keywords", [['((sequence "A" "B" "|" "C"))]])
    t.keys("S-<right>")
    t.eq(t.lines(), { "* NEXT x" }, "buffer keeps its keywords until restart")
    t.command("org-mode-restart")
    t.keys("S-<right>")
    t.eq(t.lines(), { "* A NEXT x" }, "after restart")
    agree(t, path)
  end,

  -- Emacs: a file visited afresh picks up the new keywords.
  ["org-todo-keywords set with :EmacsEval apply to a file re-opened in Neovim"] = function(t)
    local path = t.file("lc_reopen.org", "* TODO x\n")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    vim.cmd("silent bwipeout!")
    t.set("org-todo-keywords", [['((sequence "A" "B" "|" "C"))]])
    t.open("lc_reopen.org", "* TODO x\n")
    t.keys("S-<right>")
    t.eq(t.lines(), { "* A TODO x" })
    agree(t, path)
  end,

  -- Emacs: indent on gives "text" under ** B line-prefix "    "; noindent
  -- and C-c C-c turn org-indent-mode off and the prefix goes.
  ["#+STARTUP: indent / noindent with C-c C-c add and remove the prefixes"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    local path = t.open("lc_startup.org", "#+STARTUP: showeverything\n* A\nbody\n** B\ntext\n")
    set_line(1, "#+STARTUP: indent")
    t.cursor(1)
    t.keys("C-c C-c")
    t.eq(t.eval('(with-current-buffer "lc_startup.org" org-indent-mode)'), "t", "org-indent-mode")
    t.eq(inline_prefix(4), "    ", "prefix of text under ** B")
    set_line(1, "#+STARTUP: noindent")
    t.cursor(1)
    t.keys("C-c C-c")
    t.eq(t.eval('(with-current-buffer "lc_startup.org" org-indent-mode)'), "nil", "org-indent-mode off")
    t.eq(inline_prefix(4), nil, "prefix gone")
    agree(t, path)
  end,

  -- Emacs: M-x org-indent-mode adds "    " before "text"; a second one
  -- removes every line-prefix.
  ["M-x org-indent-mode toggles the prefixes in Neovim"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    local path = t.open("lc_indent.org", "* A\nbody\n** B\ntext\n")
    t.command("org-indent-mode")
    t.eq(inline_prefix(3), "    ", "on")
    t.command("org-indent-mode")
    t.eq(inline_prefix(3), nil, "off")
    t.eq(inline_prefix(1), nil, "off, body under * A")
    agree(t, path)
  end,

  -- Emacs: after C-c C-c the tag alist is alpha(a) beta(b); C-c C-q b RET
  -- tags the heading :beta:.
  ["C-c C-c on an edited #+TAGS: line gives fast tag keys"] = function(t)
    local path = t.open("lc_tags.org", "#+TAGS: alpha(a)\n* Task\n")
    set_line(1, "#+TAGS: alpha(a) beta(b)")
    t.cursor(1)
    t.keys("C-c C-c")
    t.cursor(2)
    t.answer("b", "RET")
    t.keys("C-c C-q")
    t.eq(t.lines()[2], t.aligned("* Task", ":beta:"))
    agree(t, path)
  end,

  -- Emacs: after C-c C-c Effort_ALL has 0:30; S-right twice on the
  -- property goes 0:10 -> 0:20 -> 0:30 and realigns the value.
  ["C-c C-c on an edited #+PROPERTY: line extends the allowed values"] = function(t)
    local path = t.open("lc_prop.org", "#+PROPERTY: Effort_ALL 0:10 0:20\n* Task\n:PROPERTIES:\n:Effort: 0:10\n:END:\n")
    set_line(1, "#+PROPERTY: Effort_ALL 0:10 0:20 0:30")
    t.cursor(1)
    t.keys("C-c C-c")
    t.cursor(4)
    t.keys("S-<right>")
    t.keys("S-<right>")
    t.eq(t.lines()[4], ":Effort:   0:30")
    agree(t, path)
  end,

  -- Emacs: with the variable set, org-mode-restart hides the * markers;
  -- unset and restarted again, they show.
  ["org-hide-emphasis-markers toggled then org-mode-restart conceals and unconceals"] = function(t)
    t.config("conceal", true)
    local path = t.open("lc_emph.org", "x *bold* y\n")
    t.eq(conceals(0), {}, "markers shown at first")
    t.set("org-hide-emphasis-markers", "t")
    t.command("org-mode-restart")
    t.eq(conceals(0), { { 2, 3, "" }, { 7, 8, "" } }, "hidden after restart")
    t.eval("(setq org-hide-emphasis-markers nil)")
    t.command("org-mode-restart")
    t.eq(conceals(0), {}, "shown again after the second restart")
    agree(t, path)
  end,

  -- Emacs: r in the agenda rebuilds it from the new org-agenda-files.
  ["r in the agenda uses org-agenda-files changed since it opened"] = function(t)
    local a = t.file("lc_a.org", "* TODO Alpha task\n")
    local b = t.file("lc_b.org", "* TODO Beta task\n")
    local path = t.open("lc_home.org", "* Home\n")
    t.set("org-agenda-files", ("(list %q)"):format(a))
    t.answer("t")
    t.command("org-agenda")
    assert(t.find_line("Alpha task"), "first agenda:\n" .. table.concat(t.lines(), "\n"))
    t.eval(("(setq org-agenda-files (list %q))"):format(b))
    t.feed("r")
    assert(t.find_line("Beta task") and not t.find_line("Alpha task"),
      "rebuilt agenda:\n" .. table.concat(t.lines(), "\n"))
    vim.cmd("wincmd p")
    agree(t, path)
  end,

  -- Emacs redraws at once when a face changes; Neovim should at least show
  -- the new color after the next command.
  ["set-face-attribute on org-level-1 recolors the heading in Neovim"] = function(t)
    local path = t.open("lc_face.org", "* A\nbody\n")
    local old = t.eval("(prin1-to-string (face-attribute 'org-level-1 :foreground))")
    t.after(function() t.eval(("(set-face-attribute 'org-level-1 nil :foreground (read %s))"):format(old)) end)
    fg_at(0, 2)
    t.eval([[(set-face-attribute 'org-level-1 nil :foreground "red")]])
    t.command("ignore")
    t.eq(fg_at(0, 2), api.nvim_get_color_by_name("red"), "heading fg")
    agree(t, path)
  end,

  -- Emacs's M-: evaluates in the selected window's buffer; :EmacsEval from
  -- Neovim's buffer should see that buffer, so (org-indent-mode) or
  -- setq-local acts on the file being edited.
  [":EmacsEval runs in the Emacs mirror of Neovim's current buffer"] = function(t)
    local path = t.open("lc_first.org", "* First\n")
    t.open("lc_second.org", "* Second\n")
    vim.cmd("silent buffer " .. vim.fn.bufnr(path))
    t.eq(t.eval("(buffer-name)"), '"lc_first.org"')
    agree(t, path)
  end,
}
