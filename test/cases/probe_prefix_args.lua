-- Prefix arguments: C-u typed before C-c keys and M-x, Neovim counts, and
-- M-x org-... commands whose completion prompts reach Neovim.
-- Expected: emacs -Q --batch -l test/init.el running the same Emacs keys
-- (C-u, C-u C-u, C-u N) with execute-kbd-macro.
local api = vim.api
local mirror = require("emacs.mirror")
local rpc = require("emacs.rpc")

local TS = "%[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]"
local STATE_NOTE = '^%- State "DONE"       from "TODO"       ' .. TS .. " \\\\$"

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false), (what or "") .. " Emacs agrees")
end

-- Replace the note buffer's last line with `text`, then C-c C-c.
local function finish_note(t, text)
  t.eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "*Org Note*", "note buffer shown")
  t.eq(t.lines()[1], '# Insert note for state change from "TODO" to "DONE".', "note header")
  api.nvim_buf_set_lines(0, -2, -1, false, { text })
  t.keys("C-c C-c")
end

-- `lines` against `want`, where a want entry starting with "^" is a pattern.
local function match(t, lines, want)
  t.eq(#lines, #want, "line count: " .. vim.inspect(lines))
  for i, w in ipairs(want) do
    if w:sub(1, 1) == "^" then
      assert(lines[i]:find(w), ("line %d: %s"):format(i, lines[i]))
    else
      t.eq(lines[i], w, "line " .. i)
    end
  end
end

local function prompts(t)
  return vim.tbl_map(function(a) return a.method .. " " .. a.params.prompt end, t.asked())
end

return {
  -- Emacs: C-u C-c C-t d forces a state-change note though nothing logs.
  ["typed C-u C-c C-t takes a state note without org-log-done"] = function(t)
    local path = t.open("pa_cu_todo.org", "* TODO A\n")
    t.answer("C-t", "d")
    t.feed("<C-u><C-c>")
    finish_note(t, "hi")
    match(t, t.lines(), { "* DONE A", STATE_NOTE, "  hi" })
    agree(t, path)
  end,

  -- Emacs: with org-log-done note, C-u gives a State note, not a CLOSING NOTE.
  ["C-u C-c C-t with org-log-done note stores a State note under CLOSED"] = function(t)
    t.set("org-log-done", "'note")
    local path = t.open("pa_cu_note.org", "* TODO A\n")
    t.answer("d")
    t.keys("C-c C-t", 4)
    finish_note(t, "hi")
    match(t, t.lines(), { "* DONE A", "^CLOSED: " .. TS .. "$", STATE_NOTE, "  hi" })
    agree(t, path)
  end,

  ["C-u C-u C-c C-t switches to the next keyword set"] = function(t)
    t.set("org-todo-keywords", [['((sequence "TODO(t)" "|" "DONE(d)") (sequence "BUG(b)" "|" "FIXED(f)"))]])
    local path = t.open("pa_nextset.org", "* TODO A\n")
    t.answer("C-t")
    t.feed("<C-u><C-u><C-c>")
    t.eq(t.lines(), { "* BUG A" })
    agree(t, path)
  end,

  -- Emacs: C-u 2 C-c C-t is the second keyword, C-u 3 the third.
  ["a count to C-c C-t picks that keyword"] = function(t)
    local path = t.open("pa_nth.org", "* A\n* B\n")
    t.keys("C-c C-t", 2)
    t.cursor(2)
    t.keys("C-c C-t", 3)
    t.eq(t.lines(), { "* NEXT A", "* DONE B" })
    agree(t, path)
  end,

  -- Emacs: C-c C-t d is blocked by the open child; C-u C-u C-u gets past it.
  ["C-u C-u C-u C-c C-t marks a blocked parent DONE"] = function(t)
    t.set("org-enforce-todo-dependencies", "t")
    t.eval("(add-hook 'org-blocker-hook #'org-block-todo-from-children-or-siblings-or-parent)")
    t.after(function()
      t.eval("(remove-hook 'org-blocker-hook #'org-block-todo-from-children-or-siblings-or-parent)")
    end)
    local path = t.open("pa_block.org", "* TODO P\n** TODO c\n")
    t.answer("d")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* TODO P", "** TODO c" }, "blocked")
    t.answer("C-t", "d")
    t.feed("<C-u><C-u><C-u><C-c>")
    t.eq(t.lines(), { "* DONE P", "** TODO c" })
    agree(t, path)
  end,

  ["typed C-u C-c C-c removes an item's checkbox"] = function(t)
    local path = t.open("pa_box.org", "* L\n- [ ] one\n- [X] two\n")
    t.cursor(3)
    t.answer("C-c")
    t.feed("<C-u><C-c>")
    t.eq(t.lines(), { "* L", "- [ ] one", "- two" })
    agree(t, path)
  end,

  -- Emacs: C-u M-RET in a list makes a heading after the subtree, not an item.
  ["typed C-u M-RET in a list inserts a heading after the subtree"] = function(t)
    local path = t.open("pa_mret.org", "* H\n- a\n- b\n* I\n")
    t.cursor(2, 2)
    t.feed("<C-u><M-CR>")
    t.eq(t.lines(), { "* H", "- a", "- b", "* ", "* I" })
    agree(t, path)
  end,

  -- org-archive-subtree-default passes C-u on through call-interactively.
  ["typed C-u C-c C-x C-a asks about each DONE child"] = function(t)
    local src = t.open("pa_arch.org", "* P\n** DONE d1\n** TODO t1\n** DONE d2\n")
    local archive = src .. "_archive"
    os.remove(archive)
    t.set("org-archive-location", '"%s_archive::"')
    t.answer("C-x", "C-a", true, false)
    t.feed("<C-u><C-c>")
    t.eq(vim.tbl_filter(function(p) return p:find("^confirm") end, prompts(t)),
      { "confirm Move subtree to archive? (no open TODO items)", "confirm Move subtree to archive? (no open TODO items)" })
    t.eq(t.lines(), { "* P", "** TODO t1", "** DONE d2" })
    local heads = vim.tbl_filter(function(l) return l:match("^%*") end,
      api.nvim_buf_get_lines(vim.fn.bufnr(archive), 0, -1, false))
    t.eq(heads, { "* DONE d1" }, "archive headings")
    agree(t, src)
    agree(t, archive, "archive")
  end,

  -- Emacs: "M-x " completes commands, then "Property: " offers the
  -- buffer's keys and "Foo value: " Foo's values.
  ["M-x org-set-property asks through completing_read with the buffer's keys"] = function(t)
    local path = t.open("pa_mx_prop.org", "* A\n:PROPERTIES:\n:Foo: 1\n:END:\n* B\n")
    t.cursor(5)
    t.answer("org-set-property", "Foo", "2")
    t.keys("M-x")
    -- "Property: " shows the last property set, by any test, as its default.
    local seen = prompts(t)
    seen[2] = seen[2]:gsub(" %[.-%]: $", ": ")
    t.eq(seen, { "completing_read M-x ", "completing_read Property: ", "completing_read Foo value: " })
    local asked = t.asked()
    assert(vim.tbl_contains(asked[2].params.candidates, "Foo"), vim.inspect(asked[2].params.candidates))
    t.eq(asked[3].params.candidates, { "1" }, "Foo's values")
    t.eq(t.lines(), { "* A", ":PROPERTIES:", ":Foo: 1", ":END:", "* B", ":PROPERTIES:", ":Foo:      2", ":END:" })
    agree(t, path)
  end,

  -- What Tab in Neovim's prompt asks of Emacs while the reader waits:
  -- Emacs's TAB extends "org-set-prop" to the shared "org-set-property".
  ["Tab at the M-x prompt completes from Emacs's command table"] = function(t)
    local path = t.open("pa_mx_tab.org", "* A\n")
    local ui = require("emacs.ui")
    local got
    rpc.handlers.completing_read = function()
      got = { ui.complete("org-set-prop"), ui.complete("org-set-property-") }
      return "org-todo"
    end
    t.answer("t")
    t.keys("M-x")
    t.eq(got, { { "org-set-property" }, { "org-set-property-and-value" } })
    t.eq(t.lines(), { "* TODO A" })
    agree(t, path)
  end,

  -- Emacs: the read-char menu answers a, then A (reversed).
  ["M-x org-sort takes its menu answer as a key"] = function(t)
    local path = t.open("pa_mx_sort.org", "* P\n** b\n** c\n** a\n")
    t.answer("org-sort", "a")
    t.keys("M-x")
    t.eq(prompts(t)[2]:match("^read_key Sort children: %[a%]lpha") ~= nil, true, prompts(t)[2])
    t.eq(t.lines(), { "* P", "** a", "** b", "** c" }, "a")
    t.answer("org-sort", "A")
    t.keys("M-x")
    t.eq(t.lines(), { "* P", "** c", "** b", "** a" }, "A")
    agree(t, path)
  end,

  -- Emacs: the prompt names the argument, "C-u M-x ", "2 M-x ", "16 M-x ",
  -- and the command gets it (C-u org-todo takes a note).
  ["C-u and counts before M-x reach the prompt and the command"] = function(t)
    local path = t.open("pa_mx_arg.org", "* TODO A\n* TODO B\n* TODO C\n")
    t.answer("org-todo", "d")
    t.feed("<C-u><M-x>")
    finish_note(t, "hi")
    t.cursor(4)
    t.answer("org-todo")
    t.keys("M-x", 2)
    t.cursor(5)
    t.answer("org-todo")
    t.keys("M-x", 16)
    t.eq(vim.tbl_filter(function(p) return p:find("M%-x") end, prompts(t)),
      { "completing_read C-u M-x ", "completing_read 2 M-x ", "completing_read 16 M-x " })
    match(t, t.lines(), { "* DONE A", STATE_NOTE, "  hi", "* NEXT B", "* TODO C" })
    agree(t, path)
  end,
}
