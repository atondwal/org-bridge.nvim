-- C-c ' edit buffers typed into in Insert mode: emacs-lisp, example, LaTeX
-- and export blocks, footnotes, the formula editor; C-c ', C-c C-k and
-- C-x C-s; src indentation (preserve, content indentation, -i, list items).
-- The python src basics are in src_edit.lua.
local api = vim.api

-- Type keys as in Insert mode. 'autoindent' is off so the typed indentation
-- is exactly what the batch reference inserted.
local function type_keys(keys)
  vim.bo.autoindent = false
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function split(text) return vim.split(text, "\n", { plain = true, trimempty = true }) end

-- Open text, put the cursor at (line, col) and C-c ' there.
local function edit(t, name, text, line, col)
  local path = t.open(name, text)
  local org = api.nvim_get_current_buf()
  t.cursor(line, col)
  t.keys("C-c '")
  assert(api.nvim_get_current_buf() ~= org, "edit buffer focused")
  return path, org
end

local function back_in(t, org)
  t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
  t.eq(#api.nvim_tabpage_list_wins(0), 1, "edit window closed")
end

local ELISP = "* H\n#+begin_src emacs-lisp\n  (+ 1 2)\n#+end_src\n"
local FOOTNOTE = "* H\nsee[fn:1] here\n\n* Footnotes\n\n[fn:1] one\n"
local DEEP = "* H\n#+begin_src python\n    x = 1\n  y = 2\n#+end_src\n"

return {
  ["emacs-lisp block: Insert typing, then C-c ' writes it back indented"] = function(t)
    local path, org = edit(t, "pes_el.org", ELISP, 3, 4)
    assert(api.nvim_buf_get_name(0):find("*Org Src pes_el.org[ emacs-lisp ]*", 1, true), api.nvim_buf_get_name(0))
    t.eq(vim.bo.filetype, "lisp")
    t.eq(t.lines(), { "(+ 1 2)" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 2 })
    type_keys("o(* 3 4)<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "#+begin_src emacs-lisp", "  (+ 1 2)", "  (* 3 4)", "#+end_src" })
    t.eq(api.nvim_win_get_cursor(0), { 4, 8 })
    t.eq(t.read_file(path), ELISP, "exit does not save")
  end,

  ["emacs-lisp block: C-c C-k after typing leaves the org buffer unchanged"] = function(t)
    local _, org = edit(t, "pes_elk.org", ELISP, 3, 4)
    vim.bo[org].modified = false
    type_keys("o(* 3 4)<Esc>")
    t.keys("C-c C-k")
    back_in(t, org)
    t.eq(t.lines(), split(ELISP))
    t.eq(api.nvim_win_get_cursor(0), { 3, 0 })
    t.eq(vim.bo[org].modified, false)
  end,

  ["emacs-lisp block: C-x C-s saves the edit into the file and stays"] = function(t)
    local path, org = edit(t, "pes_els.org", ELISP, 3, 4)
    local src = api.nvim_get_current_buf()
    type_keys("o(* 3 4)<Esc>")
    t.keys("C-x C-s")
    t.eq(api.nvim_get_current_buf(), src, "still editing")
    t.eq(t.lines(), { "(+ 1 2)", "(* 3 4)" })
    t.eq(t.read_file(path), "* H\n#+begin_src emacs-lisp\n  (+ 1 2)\n  (* 3 4)\n#+end_src\n")
    t.eq(vim.bo[org].modified, false)
    t.keys("C-c '")
    back_in(t, org)
  end,

  -- Emacs: C-c C-k after C-x C-s keeps what was saved, drops the rest.
  ["python block: C-x C-s, more typing, C-c C-k keeps only the saved edit"] = function(t)
    local text = "* H\n#+begin_src python\n  x = 1\n#+end_src\n"
    local path, org = edit(t, "pes_py.org", text, 3, 2)
    type_keys("oif x:<CR>    print(x)<Esc>")
    t.keys("C-x C-s")
    type_keys("Goz = 0<Esc>")
    t.keys("C-c C-k")
    back_in(t, org)
    local saved = { "* H", "#+begin_src python", "  x = 1", "  if x:", "      print(x)", "#+end_src" }
    t.eq(t.lines(), saved)
    t.eq(t.read_file(path), table.concat(saved, "\n") .. "\n")
    t.eq(api.nvim_win_get_cursor(0), { 3, 0 })
  end,

  -- Emacs indents example contents by org-edit-src-content-indentation and
  -- comma-escapes a line that would read as a heading.
  ["example block: typed lines come back indented, a heading escaped"] = function(t)
    local text = "* H\n#+begin_example\nfoo\n#+end_example\n"
    local _, org = edit(t, "pes_ex.org", text, 3, 0)
    assert(api.nvim_buf_get_name(0):find("[ example ]", 1, true), api.nvim_buf_get_name(0))
    t.eq(t.lines(), { "foo" })
    type_keys("o* not a heading<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "#+begin_example", "  foo", "  ,* not a heading", "#+end_example" })
    t.eq(api.nvim_win_get_cursor(0), { 4, 17 })
  end,

  ["example block: C-c C-k drops typed text"] = function(t)
    local text = "* H\n#+begin_example\nfoo\n#+end_example\n"
    local _, org = edit(t, "pes_exk.org", text, 3, 0)
    type_keys("ix<Esc>")
    t.keys("C-c C-k")
    back_in(t, org)
    t.eq(t.lines(), split(text))
  end,

  ["LaTeX environment: the edit holds the whole environment"] = function(t)
    local text = "* H\n\\begin{equation}\nx=1\n\\end{equation}\n"
    local _, org = edit(t, "pes_tex.org", text, 3, 0)
    assert(api.nvim_buf_get_name(0):find("[ LaTeX environment ]", 1, true), api.nvim_buf_get_name(0))
    t.eq(t.lines(), { "\\begin{equation}", "x=1", "\\end{equation}" })
    t.eq(api.nvim_win_get_cursor(0), { 2, 0 })
    type_keys("oy=2<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "\\begin{equation}", "x=1", "y=2", "\\end{equation}" })
    t.eq(api.nvim_win_get_cursor(0), { 4, 2 })
  end,

  -- Unlike src and example blocks, export contents are not reindented.
  ["export block: edits in the backend's mode, written back unindented"] = function(t)
    local text = "* H\n#+begin_export html\n<b>x</b>\n#+end_export\n"
    local _, org = edit(t, "pes_exp.org", text, 3, 0)
    assert(api.nvim_buf_get_name(0):find("*Org Src pes_exp.org[ html ]*", 1, true), api.nvim_buf_get_name(0))
    t.eq(t.lines(), { "<b>x</b>" })
    type_keys("o<i>y</i><Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "#+begin_export html", "<b>x</b>", "<i>y</i>", "#+end_export" })
    t.eq(api.nvim_win_get_cursor(0), { 4, 7 })
  end,

  ["footnote: C-c C-k after typing leaves the definition"] = function(t)
    local _, org = edit(t, "pes_fnk.org", FOOTNOTE, 2, 5)
    type_keys("A two<Esc>")
    t.keys("C-c C-k")
    back_in(t, org)
    t.eq(t.lines(), split(FOOTNOTE))
    t.eq(api.nvim_win_get_cursor(0), { 2, 5 })
  end,

  ["footnote: C-x C-s saves the typed definition and stays"] = function(t)
    local path, org = edit(t, "pes_fns.org", FOOTNOTE, 2, 5)
    local fn = api.nvim_get_current_buf()
    t.eq(api.nvim_win_get_cursor(0), { 1, 7 })
    type_keys("A two<Esc>")
    t.keys("C-x C-s")
    t.eq(api.nvim_get_current_buf(), fn, "still editing")
    t.eq(t.lines(), { "[fn:1] one two" })
    t.eq(t.read_file(path), "* H\nsee[fn:1] here\n\n* Footnotes\n\n[fn:1] one two\n")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(vim.bo[org].modified, false)
  end,

  -- In *Edit Formulas* C-x C-s, like C-c ', installs and closes; nothing is saved.
  ["formula editor: Insert typing, C-x C-s installs and closes"] = function(t)
    local text = "| a | b |\n|---+---|\n| 1 |   |\n#+TBLFM: $2=$1*2\n"
    local path, org = edit(t, "pes_tbl.org", text, 4, 0)
    t.eq(t.lines(), { "# Column Formulas", "$2 = $1*2" })
    type_keys("GA3<Esc>")
    t.keys("C-x C-s")
    back_in(t, org)
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 |   |", "#+TBLFM: $2=$1*23" })
    t.eq(api.nvim_win_get_cursor(0), { 4, 0 })
    t.eq(t.read_file(path), text)
  end,

  ["formula editor: Insert typing, C-c ' installs"] = function(t)
    local text = "| a | b |\n|---+---|\n| 1 |   |\n#+TBLFM: $2=$1*2\n"
    local _, org = edit(t, "pes_tbl2.org", text, 4, 0)
    type_keys("GA3<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines()[4], "#+TBLFM: $2=$1*23")
  end,

  ["org-src-preserve-indentation t: edit and write back verbatim"] = function(t)
    t.set("org-src-preserve-indentation", "t")
    local _, org = edit(t, "pes_pre.org", DEEP, 3, 4)
    t.eq(t.lines(), { "    x = 1", "  y = 2" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 4 })
    type_keys("Goz = 3<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "#+begin_src python", "    x = 1", "  y = 2", "z = 3", "#+end_src" })
  end,

  -- Only the common indentation is stripped; the rest is kept relative.
  ["preserve nil: common indentation stripped, then restored"] = function(t)
    local _, org = edit(t, "pes_nopre.org", DEEP, 3, 4)
    t.eq(t.lines(), { "  x = 1", "y = 2" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 2 })
    type_keys("Goz = 3<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "#+begin_src python", "    x = 1", "  y = 2", "  z = 3", "#+end_src" })
  end,

  ["preserve nil: an unchanged edit leaves odd indentation alone"] = function(t)
    local _, org = edit(t, "pes_same.org", DEEP, 3, 4)
    vim.bo[org].modified = false
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), split(DEEP))
    t.eq(vim.bo[org].modified, false)
    t.eq(api.nvim_win_get_cursor(0), { 3, 4 })
  end,

  ["org-edit-src-content-indentation 4 reindents the body"] = function(t)
    t.set("org-edit-src-content-indentation", "4")
    local _, org = edit(t, "pes_ci4.org", "* H\n#+begin_src python\nx = 1\n#+end_src\n", 3, 0)
    type_keys("Goy = 2<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "#+begin_src python", "    x = 1", "    y = 2", "#+end_src" })
  end,

  ["content indentation 0 in a list item aligns with the block"] = function(t)
    t.set("org-edit-src-content-indentation", "0")
    local text = "- item\n  #+begin_src python\n    x = 1\n  #+end_src\n"
    local _, org = edit(t, "pes_ci0.org", text, 3, 4)
    t.eq(t.lines(), { "x = 1" })
    type_keys("Goy = 2<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "- item", "  #+begin_src python", "  x = 1", "  y = 2", "  #+end_src" })
  end,

  -- org-mode's indent-tabs-mode is t in emacs -Q: 8 columns become a tab.
  ["a list-item block indents past the block, with tabs at 8 columns"] = function(t)
    local text = "- item\n  #+begin_src python\n  x = 1\n  #+end_src\n"
    local _, org = edit(t, "pes_list.org", text, 3, 2)
    t.eq(t.lines(), { "x = 1" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 0 })
    type_keys("Goif x:<CR>    y = 2<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "- item", "  #+begin_src python", "    x = 1", "    if x:", "\ty = 2", "  #+end_src" })
  end,

  ["the -i switch preserves indentation for one block"] = function(t)
    local _, org = edit(t, "pes_sw.org", "* H\n#+begin_src python -i\n x = 1\n#+end_src\n", 3, 1)
    t.eq(t.lines(), { " x = 1" })
    type_keys("Goy = 2<Esc>")
    t.keys("C-c '")
    back_in(t, org)
    t.eq(t.lines(), { "* H", "#+begin_src python -i", " x = 1", "y = 2", "#+end_src" })
  end,
}
