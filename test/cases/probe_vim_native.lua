-- Vim's own edits on org text (block append/delete in tables, :g/normal,
-- J, <<, :sort, ddp, p into folds, :put, :m on a range, :norm with org keys),
-- then a check that Emacs has the same text and reads the same structure.
-- Org-side expectations: emacs -Q --batch -l test/init.el.
local mirror = require("emacs.mirror")

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- Evaluate expr in path's Emacs buffer at the start of line n; prin1 text.
local function at_line(t, path, n, expr)
  return vim.json.decode(t.eval(([[(with-current-buffer (get-file-buffer %q)
    (save-excursion (goto-char (point-min)) (forward-line %d) (format "%%S" %s)))]]):format(path, n - 1, expr)))
end

-- Lines Emacs hides (folded), as "(2 3 4)".
local function emacs_hidden(t, path)
  return vim.json.decode(t.eval(([[(with-current-buffer (get-file-buffer %q)
    (save-excursion (goto-char (point-min))
      (let (r (n 1))
        (while (not (eobp))
          (when (invisible-p (point)) (push n r))
          (forward-line 1) (setq n (1+ n)))
        (format "(%%s)" (mapconcat #'number-to-string (nreverse r) " ")))))]]):format(path)))
end

-- Lines inside Neovim's closed folds (all but each fold's first), same form.
local function nvim_hidden(t)
  local out = {}
  for _, r in ipairs(t.folds()) do
    local a, b = r:match("(%d+)-(%d+)")
    for l = tonumber(a) + 1, tonumber(b) do out[#out + 1] = tostring(l) end
  end
  return "(" .. table.concat(out, " ") .. ")"
end

-- The plugin's real prompt handlers (the harness stubs them), so :norm's
-- own keys answer C-c's second key and the TODO menu.
local function real_prompts()
  package.loaded["emacs.ui"] = nil
  require("emacs.ui")
end

return {
  -- Emacs, TAB after appending " 1 |" to each row: | a  | 1 | / | bb | 1 | ...
  ["<C-v>jj$A appends a column; TAB realigns it, org sees two columns"] = function(t)
    local path = t.open("block_append.org", "| a |\n| bb |\n| c |\n")
    t.feed("<C-v>jj$A 1 |<Esc>")
    t.eq(t.lines(), { "| a | 1 |", "| bb | 1 |", "| c | 1 |" }, "appended on every row")
    agree(t, path, "block append")
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| a  | 1 |", "| bb | 1 |", "| c  | 1 |" }, "TAB")
    agree(t, path, "TAB")
    t.eq(at_line(t, path, 1, "(length (car (org-table-to-lisp)))"), "2")
  end,

  ["<C-v>jj3ld over a column and its bar leaves org a one-column table"] = function(t)
    local path = t.open("block_delete.org", "| a | x |\n| b | y |\n| c | z |\n")
    t.cursor(1, 4)
    t.feed("<C-v>jj3ld")
    t.eq(t.lines(), { "| a |", "| b |", "| c |" })
    agree(t, path)
    t.eq(at_line(t, path, 1, "(length (car (org-table-to-lisp)))"), "1")
  end,

  -- Emacs leaves a tag typed after the title where it was typed: org
  -- realigns only tags that were already there (org-fix-tags-on-the-fly).
  [":g/^\\*/normal A :x: adds a tag org reads, left unaligned as in Emacs"] = function(t)
    local path = t.open("g_tags.org", "* A\nbody a\n* B\n")
    vim.cmd([[g/^\*/normal A :x:]])
    t.eq(t.lines(), { "* A :x:", "body a", "* B :x:" })
    agree(t, path)
    t.eq(at_line(t, path, 3, "(org-get-tags)"), '("x")')
  end,

  -- :normal ends Insert mode, which is when Emacs realigns existing tags.
  -- Emacs, typing " new" after each title: the tags move to column 77.
  [":g/^\\*/normal 0lla new realigns each heading's existing tags"] = function(t)
    local path = t.open("g_retag.org", "* A :t:\nbody a\n* B :t:\n")
    vim.cmd([[g/^\*/normal 0lla new]])
    t.eq(t.lines(), { t.aligned("* A new", ":t:"), "body a", t.aligned("* B new", ":t:") })
    agree(t, path)
  end,

  ["J on a body line swallows the next heading; org counts one entry"] = function(t)
    local path = t.open("join_next.org", "* A\nbody a\n* B\nbody b\n")
    t.cursor(2)
    t.feed("J")
    t.eq(t.lines(), { "* A", "body a * B", "body b" })
    agree(t, path)
    t.eq(at_line(t, path, 1, "(length (org-map-entries t))"), "1")
  end,

  -- With shiftwidth 8, << removes all of the item's two spaces.
  ["<< on a nested item makes it top-level in org's list"] = function(t)
    local path = t.open("dedent.org", "* L\n- a\n  - sub\n- b\n")
    local parent = "(org-list-get-parent (point-at-bol) (org-list-struct) (org-list-parents-alist (org-list-struct)))"
    t.eq(at_line(t, path, 3, parent), "5", "a child of - a before")
    t.cursor(3)
    t.feed("<<")
    t.eq(t.lines(), { "* L", "- a", "- sub", "- b" })
    agree(t, path)
    t.eq(at_line(t, path, 3, parent), "nil", "no parent after")
  end,

  -- Emacs's C-c ^ a on P gives the same order.
  [":sort on sibling headings matches org-sort-entries alphabetically"] = function(t)
    local path = t.open("sort_heads.org", "* P\n** C\n** A\n** B\n")
    vim.cmd("2,4sort")
    t.eq(t.lines(), { "* P", "** A", "** B", "** C" })
    agree(t, path)
  end,

  ["ddp on an open heading moves only that line"] = function(t)
    local path = t.open("ddp_head.org", "* A\nbody a\n* B\nbody b\n")
    t.feed("ddp")
    t.eq(t.lines(), { "body a", "* A", "* B", "body b" })
    agree(t, path)
    t.eq(at_line(t, path, 1, "(org-before-first-heading-p)"), "t", "body a is now before the first heading")
  end,

  -- A closed fold is one line to dd, so p puts the subtree after * B.
  ["ddp on a closed fold moves the subtree below the next line"] = function(t)
    local path = t.open("ddp_fold.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    t.feed("ddp")
    t.eq(t.lines(), { "* B", "* A", "body a", "** A1", "text", "body b" })
    agree(t, path)
    t.eq(nvim_hidden(t), emacs_hidden(t, path), "both hide the same lines")
  end,

  ["p of a yanked subtree on a closed child fold pastes it inside the parent"] = function(t)
    local path = t.open("p_fold.org", "* A\nbody a\n** A1\ntext\n* B\n** X\nx body\n")
    t.cursor(6)
    t.feed("yj")
    t.cursor(3)
    t.keys("TAB")
    t.eq(t.folds(), { "3-4" }, "A1 folded")
    t.feed("p")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "** X", "x body", "* B", "** X", "x body" })
    agree(t, path)
    t.eq(at_line(t, path, 5, "(org-get-outline-path)"), '("A")', "X is a child of A")
    t.eq(nvim_hidden(t), emacs_hidden(t, path), "both hide the same lines")
    t.eq(nvim_hidden(t), "(4)", "the pasted subtree is visible")
  end,

  -- Vim puts after a closed fold's last line, not inside it.
  [":2put on a closed fold puts after it; both sides hide the same lines"] = function(t)
    local path = t.open("put_fold.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    vim.cmd("2put ='inside'")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "inside", "* B", "body b" })
    agree(t, path)
    t.eq(nvim_hidden(t), emacs_hidden(t, path), "both hide the same lines")
  end,

  [":2,3m$ moves a child subtree's lines under the last heading"] = function(t)
    local path = t.open("move_range.org", "* A\n** A1\ntext\n* B\nbody b\n** B1\n")
    vim.cmd("2,3m$")
    t.eq(t.lines(), { "* A", "* B", "body b", "** B1", "** A1", "text" })
    agree(t, path)
    t.eq(at_line(t, path, 5, "(org-get-outline-path)"), '("B")')
  end,

  [":2,3norm <C-c><C-t>t marks each heading in the range TODO"] = function(t)
    local path = t.open("norm_todo.org", "* A\n* B\n* C\n")
    real_prompts()
    vim.cmd([[exe "2,3norm \<C-c>\<C-t>t"]])
    t.eq(t.lines(), { "* A", "* TODO B", "* TODO C" })
    agree(t, path)
  end,

  [":%norm <S-Right>A! mixes an org key and Vim typing on each line"] = function(t)
    local path = t.open("norm_mix.org", "* A\n* B\n")
    vim.cmd([[exe "%norm \<S-Right>A!"]])
    t.eq(t.lines(), { "* TODO A!", "* TODO B!" })
    agree(t, path)
  end,
}
