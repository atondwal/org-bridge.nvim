-- Export to files from the dispatcher: markdown, LaTeX, ASCII, body-only HTML,
-- subtree (C-s), visible-only (C-v) and async (C-a). Expected file contents:
-- the same keys in emacs -Q --batch -l test/init.el, with ox-md loaded.
local api = vim.api
local mirror = require("emacs.mirror")

local DOC = table.concat({
  "#+TITLE: Probe",
  "#+AUTHOR: Tester",
  "#+OPTIONS: toc:nil num:nil",
  "* One",
  "Some *bold* and /it/ text.",
  "** Sub",
  "- item a",
  "- item b",
  "* Two",
  "| a | b |",
  "|---+---|",
  "| 1 | 2 |",
  "",
}, "\n")

-- The table as ox-md writes it (ox-html's, with a blank line before <tbody>).
local MD_TABLE = {
  '<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">',
  "", "",
  "<colgroup>",
  '<col  class="org-right" />',
  "",
  '<col  class="org-right" />',
  "</colgroup>",
  "<thead>",
  "<tr>",
  '<th scope="col" class="org-right">a</th>',
  '<th scope="col" class="org-right">b</th>',
  "</tr>",
  "</thead>",
  "",
  "<tbody>",
  "<tr>",
  '<td class="org-right">1</td>',
  '<td class="org-right">2</td>',
  "</tr>",
  "</tbody>",
  "</table>",
  "",
}

-- ox-ascii's title block for DOC.
local TXT_TITLE = {
  "                                ________", "",
  "                                 PROBE", "",
  "                                 Tester",
  "                                ________", "", "",
}

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do vim.list_extend(out, list) end
  return out
end

local MD = concat({ "", "", "# One", "", "Some **bold** and *it* text.", "", "",
  "## Sub", "", "-   item a", "-   item b", "", "", "# Two", "" }, MD_TABLE)

-- Opens name.org holding DOC, with any earlier export of it deleted.
local function open(t, name, ext)
  vim.fn.delete(t.WORK .. "/" .. name .. "." .. ext)
  return t.open(name .. ".org", DOC)
end

-- The exported file's lines; random org-export ids (org1a2b3c4) become ID.
local function exported(t, name, ext)
  local path = t.WORK .. "/" .. name .. "." .. ext
  assert(vim.fn.filereadable(path) == 1, path .. " written next to the org file")
  local text = t.read_file(path):gsub("org%x%x%x%x%x%x%x", "ID"):gsub("\n$", "")
  return vim.split(text, "\n", { plain = true })
end

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- ox-md isn't in org-export-backends by default; load registers it.
local function use_md(t)
  t.eval([[(load "ox-md" nil t)]])
  t.after(function()
    t.eval([[(setq org-export-registered-backends
      (seq-remove (lambda (b) (eq (org-export-backend-name b) 'md)) org-export-registered-backends))]])
  end)
end

local function export(t, ...)
  t.answer(...)
  t.keys("C-c C-e")
end

return {
  ["m m writes the markdown batch Emacs writes"] = function(t)
    use_md(t)
    local path = open(t, "md", "md")
    export(t, "m", "m")
    t.eq(exported(t, "md", "md"), MD, "md.md")
    agree(t, path)
  end,

  ["l l writes a .tex like batch Emacs and runs no LaTeX"] = function(t)
    local path = open(t, "tex", "tex")
    export(t, "l", "l")
    local lines = exported(t, "tex", "tex")
    assert(vim.tbl_contains(lines, "\\title{Probe}") and vim.tbl_contains(lines, "\\author{Tester}"),
      "preamble:\n" .. table.concat(lines, "\n"))
    local body = vim.list_slice(lines, assert(vim.fn.index(lines, "\\begin{document}") + 1))
    t.eq(body, {
      "\\begin{document}", "", "\\maketitle",
      "\\section*{One}", "\\label{sec:ID}", "Some \\textbf{bold} and \\emph{it} text.",
      "\\subsection*{Sub}", "\\label{sec:ID}",
      "\\begin{itemize}", "\\item item a", "\\item item b", "\\end{itemize}",
      "\\section*{Two}", "\\label{sec:ID}",
      "\\begin{center}", "\\begin{tabular}{rr}", "a & b\\\\[0pt]", "\\hline", "1 & 2\\\\[0pt]",
      "\\end{tabular}", "\\end{center}", "\\end{document}",
    }, "tex body")
    t.eq(vim.fn.filereadable(t.WORK .. "/tex.pdf"), 0, "no pdf")
    agree(t, path)
  end,

  ["t a writes the .txt batch Emacs writes"] = function(t)
    local path = open(t, "txt", "txt")
    export(t, "t", "a")
    t.eq(exported(t, "txt", "txt"), concat(TXT_TITLE, {
      "One", "===", "", "  Some *bold* and /it/ text.", "", "",
      "Sub", "~~~", "", "  - item a", "  - item b", "", "",
      "Two", "===", "", "   a  b ", "  ------", "   1  2 ",
    }), "txt.txt")
    agree(t, path)
  end,

  ["C-b h h writes body-only html without toc or numbers"] = function(t)
    local path = open(t, "body", "html")
    export(t, "C-b", "h", "h")
    t.eq(exported(t, "body", "html"), {
      '<div id="outline-container-ID" class="outline-2">',
      '<h2 id="ID">One</h2>',
      '<div class="outline-text-2" id="text-ID">',
      "<p>", "Some <b>bold</b> and <i>it</i> text.", "</p>", "</div>",
      '<div id="outline-container-ID" class="outline-3">',
      '<h3 id="ID">Sub</h3>',
      '<div class="outline-text-3" id="text-ID">',
      '<ul class="org-ul">', "<li>item a</li>", "<li>item b</li>", "</ul>",
      "</div>", "</div>", "</div>",
      '<div id="outline-container-ID" class="outline-2">',
      '<h2 id="ID">Two</h2>',
      '<div class="outline-text-2" id="text-ID">',
      '<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">',
      "", "",
      "<colgroup>", '<col  class="org-right" />', "", '<col  class="org-right" />', "</colgroup>",
      "<thead>", "<tr>",
      '<th scope="col" class="org-right">a</th>', '<th scope="col" class="org-right">b</th>',
      "</tr>", "</thead>",
      "<tbody>", "<tr>",
      '<td class="org-right">1</td>', '<td class="org-right">2</td>',
      "</tr>", "</tbody>", "</table>", "</div>", "</div>",
    }, "body.html")
    agree(t, path)
  end,

  ["C-s m m exports the subtree at Neovim's cursor"] = function(t)
    use_md(t)
    local path = open(t, "sub", "md")
    t.cursor(11)
    export(t, "C-s", "m", "m")
    t.eq(exported(t, "sub", "md"), MD_TABLE, "only * Two's body; its heading is the title")
    agree(t, path)
  end,

  ["C-s t A shows the subtree as ASCII in a split that matches Emacs"] = function(t)
    local path = open(t, "suba", "txt")
    local file_buf = api.nvim_get_current_buf()
    t.cursor(5)
    export(t, "C-s", "t", "A")
    local want = {
      "                                ________", "",
      "                                  ONE", "",
      "                                 Tester",
      "                                ________", "", "",
      "Some *bold* and /it/ text.", "", "",
      "Sub", "===", "", "  - item a", "  - item b",
    }
    t.eq(t.lines(), want, "Neovim's *Org ASCII Export*")
    t.eq(t.emacs_lines("*Org ASCII Export*"), want, "Emacs's *Org ASCII Export*")
    api.nvim_set_current_win(vim.fn.win_findbuf(file_buf)[1])
    agree(t, path)
  end,

  ["C-v skips a subtree folded with zc"] = function(t)
    use_md(t)
    local path = open(t, "vis", "md")
    t.cursor(4)
    t.feed("zc")
    t.eq(t.folds(), { "4-8" }, "* One folded")
    export(t, "C-v", "m", "m")
    t.eq(exported(t, "vis", "md"), concat({ "", "", "# One", "", "", "# Two", "" }, MD_TABLE), "vis.md")
    agree(t, path)
  end,

  ["unsaved Neovim edits are exported; the org file stays unsaved"] = function(t)
    use_md(t)
    local path = open(t, "edit", "md")
    api.nvim_buf_set_lines(0, 4, 5, false, { "Edited *in* Neovim." })
    export(t, "m", "m")
    local want = vim.deepcopy(MD)
    want[5] = "Edited **in** Neovim."
    t.eq(exported(t, "edit", "md"), want, "edit.md")
    t.eq(vim.bo.modified, true, "org buffer still modified")
    t.eq(t.read_file(path), DOC, "org file on disk untouched")
    agree(t, path)
  end,

  ["a Visual selection then C-c C-e t a exports only the region"] = function(t)
    local path = open(t, "region", "txt")
    t.cursor(4)
    t.answer("C-e", "t", "a")
    t.feed("Vj<C-c>")
    t.eq(exported(t, "region", "txt"), concat(TXT_TITLE,
      { "One", "===", "", "  Some *bold* and /it/ text." }), "region.txt")
    t.feed("<Esc>")
    agree(t, path)
  end,

  ["C-a m m exports in a child Emacs without hanging"] = function(t)
    use_md(t)
    local init = t.file("async-init.el",
      "(setq native-comp-jit-compilation nil load-no-native t)\n(require 'org)\n(require 'ox-md)\n")
    t.set("org-export-async-init-file", ("%q"):format(init))
    local path = open(t, "async", "md")
    export(t, "C-a", "m", "m")
    t.eq(t.eval("(+ 1 2)"), "3", "Emacs answers while the child runs")
    vim.wait(20000, function() return vim.fn.filereadable(t.WORK .. "/async.md") == 1 end, 50)
    t.eq(exported(t, "async", "md"), MD, "async.md")
    agree(t, path)
  end,
}
