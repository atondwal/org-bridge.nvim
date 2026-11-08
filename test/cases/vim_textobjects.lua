-- Vim text objects and operators on org text: ip/ap around headings and
-- folds, it/i[/i< on HTML, links and timestamps, words in tags, table cells
-- and concealed links, >, gq (org-fill-paragraph) and = on a src block.
local mirror = require("emacs.mirror")

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- Lines Emacs hides (folded), as "(2 3 4)".
local function emacs_hidden(t, path)
  return vim.json.decode(t.eval(([[(with-current-buffer (get-file-buffer %q)
    (save-excursion (goto-char (point-min))
      (let (r (n 1))
        (while (not (eobp))
          (when (invisible-p (point)) (push n r))
          (forward-line 1) (setq n (1+ n)))
        (format "(%%s)" (mapconcat #'number-to-string (nreverse r) " ")))))]]):format(path, path)))
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

local function col_of(t, lnum, s) return (t.lines()[lnum]:find(s, 1, true)) - 1 end

-- Lines of buf with a conceal extmark.
local function concealed_lines(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if m[4].conceal then out[m[2] + 1] = true end
  end
  return vim.tbl_keys(out)
end

return {
  -- Vim paragraphs end only at blank lines, so ap runs through headings.
  -- org's element (M-h, org-mark-element) on "body a" is just "body a\n".
  ["dap on a body paragraph takes the adjoining headings too"] = function(t)
    local path = t.open("to_dap.org", t.DOC)
    t.cursor(2)
    t.feed("dap")
    t.eq(t.lines(), { "" }, "Vim's paragraph is the whole file (no blank lines)")
    agree(t, path)
  end,

  ["yap then p on a closed fold pastes after the subtree, still folded"] = function(t)
    local path = t.open("to_yap.org", "* A\nbody a\n** A1\ntext\n* B\n\npara one\npara two\n")
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" }, "A folded")
    t.cursor(7)
    t.feed("yap")
    t.cursor(1)
    t.feed("p")
    t.eq(t.lines(), { "* A", "body a", "** A1", "text", "", "para one", "para two",
      "* B", "", "para one", "para two" }, "pasted after the fold's last line")
    agree(t, path)
    t.eq(nvim_hidden(t), emacs_hidden(t, path), "both hide the same lines")
    t.eq(nvim_hidden(t), "(2 3 4)", "pasted lines visible")
  end,

  ["dap on a closed fold deletes the whole fold"] = function(t)
    local path = t.open("to_dapfold.org", "* A\nbody a\n\nmore a\n* B\nbody b\n")
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" }, "A folded")
    t.cursor(1)
    t.feed("dap")
    -- A closed fold counts as one line: ap is the fold, B stays.
    t.eq(t.lines(), { "* B", "body b" }, "the subtree, as org-cut-subtree would")
    agree(t, path)
    t.eq(nvim_hidden(t), emacs_hidden(t, path), "both hide the same lines")
  end,

  -- Typing on a heading goes through Emacs, which realigns the tags.
  -- Expected: emacs -Q --batch, "work" deleted, then p l a y self-inserted.
  ["ciw on a tag: the new tag is typed by Emacs and the tags realigned"] = function(t)
    local path = t.open("to_tag.org", t.aligned("* Head", ":work:home:") .. "\n")
    t.cursor(1, col_of(t, 1, "work"))
    t.feed("diw")
    t.eq(t.lines()[1]:match(":.*"), "::home:", "diw leaves an empty tag")
    agree(t, path, "after diw")
    t.feed("iplay<Esc>")
    t.eq(t.lines(), { t.aligned("* Head", ":play:home:") })
    agree(t, path)
  end,

  -- Expected: emacs -Q --batch, "abc" deleted, then x y self-inserted
  -- (org overwrites the cell's padding).
  ["ciw in a table cell: Emacs types into the emptied cell"] = function(t)
    local path = t.open("to_cell.org", "| abc | d |\n| ccc | e |\n")
    t.cursor(1, 2)
    t.feed("ciwxy<Esc>")
    t.eq(t.lines(), { "| xy | d |", "| ccc | e |" })
    agree(t, path)
  end,

  ["di[ in a link description and di< in a timestamp"] = function(t)
    local path = t.open("to_brackets.org", "see [[https://a.org][desc]] on <2026-11-07 Sat>\n")
    t.cursor(1, col_of(t, 1, "desc"))
    t.feed("di[")
    t.eq(t.lines()[1], "see [[https://a.org][]] on <2026-11-07 Sat>", "innermost [] only")
    agree(t, path, "after di[")
    t.cursor(1, col_of(t, 1, "2026"))
    t.feed("di<")
    t.eq(t.lines()[1], "see [[https://a.org][]] on <>")
    agree(t, path)
  end,

  ["dit and dat on HTML in an export block; di| is no text object"] = function(t)
    local path = t.open("to_html.org",
      "#+begin_export html\n<p><b>bold</b> text</p>\n#+end_export\n| a | b |\n")
    t.cursor(2, col_of(t, 2, "bold"))
    t.feed("dit")
    t.eq(t.lines()[2], "<p><b></b> text</p>", "dit")
    t.feed("dat")
    t.eq(t.lines()[2], "<p> text</p>", "dat")
    agree(t, path, "after dat")
    t.cursor(4, 2)
    t.feed("di|")
    t.eq(t.lines()[4], "| a | b |", "Vim has no i| object: nothing deleted")
    t.eq(vim.fn.mode(), "n")
    agree(t, path)
  end,

  -- concealcursor is empty, so the cursor line shows the brackets and w,
  -- $ and iw land where the user sees.
  ["dw on a concealed link: the cursor line shows it raw, conceal follows the edit"] = function(t)
    if not mirror.config.conceal then t.skip("conceal off before 0.13") end
    local path = t.open("to_link.org", "first\nsee [[https://example.com][Example]] now\nlast\n")
    t.cursor(1)
    mirror.refresh_spans(vim.api.nvim_get_current_buf())
    t.eq(concealed_lines(0), { 2 }, "link brackets concealed off the cursor line")
    t.eq(vim.wo.concealcursor, "", "cursor line shown unconcealed")
    t.cursor(2, col_of(t, 2, "[["))
    t.feed("dw")
    t.eq(t.lines()[2], "see https://example.com][Example]] now", "dw takes the [[ run")
    agree(t, path)
    t.cursor(1)
    mirror.refresh_spans(vim.api.nvim_get_current_buf())
    -- Org now sees a bare URL: nothing on line 2 is concealed.
    t.eq(concealed_lines(0), {}, "no stale conceal on the broken link")
  end,

  -- ip runs through the heading above the list (no blank line), so >ip
  -- turns "* L" into body text. M-S-right is org's list shift.
  [">ip on a list shifts the heading above it as well"] = function(t)
    local path = t.open("to_shift.org", "* L\n- a\n  - b\n- c\n")
    vim.bo.shiftwidth, vim.bo.expandtab = 2, true
    t.cursor(2)
    t.feed(">ip")
    t.eq(t.lines(), { "  * L", "  - a", "    - b", "  - c" })
    agree(t, path)
  end,

  -- Expected: emacs -Q --batch, org-fill-paragraph with the line as region.
  ["gq on a list item and a paragraph line uses org's fill; a heading stays"] = function(t)
    local item = "- one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
    local heading = "* " .. string.rep("long ", 20)
    local path = t.open("to_gq.org", "* L\n" .. item .. "\n- b\n" .. heading .. "\naaa\nbbb\nccc\n")
    -- textwidth is ignored: org fills to fill-column (70).
    vim.bo.textwidth = 30
    t.cursor(2)
    t.feed("gqq")
    t.eq(t.lines(), { "* L", "- one two three four five six seven eight nine ten eleven twelve",
      "  thirteen fourteen", "- b", heading, "aaa", "bbb", "ccc" }, "gqq on the item")
    agree(t, path, "after item")
    t.cursor(5)
    t.feed("gqq")
    t.eq(t.lines()[5], heading, "heading not filled")
    -- gqq on one line fills the whole paragraph it is in, joining lines.
    t.cursor(6)
    t.feed("gqq")
    t.eq({ unpack(t.lines(), 6) }, { "aaa bbb ccc" }, "gqq on a paragraph's first line")
    agree(t, path)
  end,

  -- gq goes to org's fill, but = is Neovim's C-indenting. Expected: C-M-\
  -- (org-indent-region) on the block's lines in emacs -Q --batch.
  ["= on a src block indents like Emacs's C-M-\\"] = function(t)
    local path = t.open("to_indent.org",
      "* S\n#+begin_src emacs-lisp\n(defun f (x)\n(if x\n1\n2))\n#+end_src\n")
    t.cursor(2)
    t.feed("=5j")
    agree(t, path)
    t.eq(t.lines(), { "* S", "#+begin_src emacs-lisp", "  (defun f (x)", "    (if x",
      "\t1", "      2))", "#+end_src" })
  end,

  -- Org's own text objects: ar/ir a subtree, ae/ie the element at point.
  ["dar deletes the subtree at the cursor, children included"] = function(t)
    local path = t.open("to_dar.org", "* A\na body\n** A1\na1 body\n* B\nb body\n")
    t.cursor(2)
    t.feed("dar")
    t.eq(t.lines(), { "* B", "b body" })
    agree(t, path)
  end,

  ["dir keeps the heading; yar then p copies a subtree"] = function(t)
    local path = t.open("to_dir.org", "* A\na body\n** A1\n* B\n")
    t.cursor(1)
    t.feed("dir")
    t.eq(t.lines(), { "* A", "* B" }, "dir")
    t.cursor(2)
    t.feed("yarP")
    t.eq(t.lines(), { "* A", "* B", "* B" }, "yar P")
    agree(t, path)
  end,

  ["ie and ae pick the element: a list, a src block's body"] = function(t)
    local path = t.open("to_elem.org", "* H\nintro\n- one\n- two\n\n#+begin_src sh\necho\n#+end_src\n")
    t.cursor(3)
    t.feed("dae")
    t.eq(t.lines(), { "* H", "intro", "#+begin_src sh", "echo", "#+end_src" }, "dae on a list")
    t.cursor(4)
    t.feed("cieecho hi<Esc>")
    t.eq(t.lines(), { "* H", "intro", "#+begin_src sh", "echo hi", "#+end_src" }, "cie in a src block")
    agree(t, path)
  end,

  ["var in Visual mode selects the subtree's lines"] = function(t)
    t.open("to_vis.org", "* A\nbody\n* B\n")
    t.cursor(2)
    t.feed("var<Esc>")
    t.eq({ vim.fn.line("'<"), vim.fn.line("'>") }, { 1, 2 })
  end,
}
