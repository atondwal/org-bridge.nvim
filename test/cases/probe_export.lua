-- Export dispatcher probes beyond export_files.lua: full HTML files, UTF-8,
-- export buffers (h H, t A, l L), C-s with C-b, C-v with HTML, and a document
-- without #+TITLE or #+OPTIONS. Expected values: the same keys in
-- emacs -Q --batch -l test/init.el (org 9.6.15).
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
  "Plain — dash.",
  "",
}, "\n")

-- No title, default toc and section numbers; the author keeps user-full-name out.
local PLAIN = "#+AUTHOR: Tester\n* One\nSome text.\n** Sub\nDeep.\n* Two\nMore.\n"

-- ox-html's body for DOC, after <h1 class="title"> (random ids are ID).
local HTML_BODY = {
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
  "<p>", "Plain — dash.", "</p>", "</div>", "</div>",
}

-- A full ox-html document for DOC, its 185 lines of <style> left out.
local HTML_PAGE = vim.list_extend({
  '<?xml version="1.0" encoding="utf-8"?>',
  '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"',
  '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">',
  '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">',
  "<head>",
  "<!-- DATE -->",
  '<meta http-equiv="Content-Type" content="text/html;charset=utf-8" />',
  '<meta name="viewport" content="width=device-width, initial-scale=1" />',
  "<title>Probe</title>",
  '<meta name="author" content="Tester" />',
  '<meta name="generator" content="Org Mode" />',
  "<style>", "</style>",
  "</head>", "<body>",
  '<div id="content" class="content">',
  '<h1 class="title">Probe</h1>',
}, vim.list_extend(vim.deepcopy(HTML_BODY), {
  "</div>",
  '<div id="postamble" class="status">',
  '<p class="author">Author: Tester</p>',
  '<p class="date">Created: DATE</p>',
  '<p class="validation"><a href="https://validator.w3.org/check?uri=referer">Validate</a></p>',
  "</div>", "</body>", "</html>",
}))

-- ox-ascii's body for DOC after the title block, in ASCII and UTF-8.
local TXT_BODY = {
  "One", "===", "", "  Some *bold* and /it/ text.", "", "",
  "Sub", "~~~", "", "  - item a", "  - item b", "", "",
  "Two", "===", "", "  Plain — dash.",
}
local UTF8 = {
  "                                ━━━━━━━━",
  "                                 PROBE", "",
  "                                 Tester",
  "                                ━━━━━━━━", "", "",
  "One", "═══", "", "  Some *bold* and /it/ text.", "", "",
  "Sub", "───", "", "  • item a", "  • item b", "", "",
  "Two", "═══", "", "  Plain — dash.",
}

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do vim.list_extend(out, list) end
  return out
end

local ASCII = concat({
  "                                ________", "",
  "                                 PROBE", "",
  "                                 Tester",
  "                                ________", "", "",
}, TXT_BODY)

-- Opens name.org holding text (default DOC), with any earlier export deleted.
local function open(t, name, ext, text)
  vim.fn.delete(t.WORK .. "/" .. name .. "." .. ext)
  return t.open(name .. ".org", text or DOC), api.nvim_get_current_buf()
end

-- Random org-export ids become ID and timestamps DATE.
local function normalize(lines)
  return vim.tbl_map(function(l)
    return (l:gsub("org%x%x%x%x%x%x%x", "ID"):gsub("%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d", "DATE"))
  end, lines)
end

-- ox-html's <style> block is constant; keep only its tags.
local function drop_style(lines)
  local out, inside = {}, false
  for _, l in ipairs(lines) do
    if l == "</style>" then inside = false end
    if not inside then out[#out + 1] = l end
    if l == "<style>" then inside = true end
  end
  return out
end

local function exported(t, name, ext)
  local path = t.WORK .. "/" .. name .. "." .. ext
  assert(vim.fn.filereadable(path) == 1, path .. " written next to the org file")
  return normalize(vim.split((t.read_file(path):gsub("\n$", "")), "\n", { plain = true }))
end

-- The org buffer is DOC as it was, unmodified, and Emacs's copy matches.
local function unchanged(t, path, buf, text)
  api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
  mirror.sync()
  local want = vim.split((text or DOC):gsub("\n$", ""), "\n", { plain = true })
  t.eq(t.lines(), want, "org buffer unchanged")
  t.eq(vim.bo.modified, false, "org buffer not modified")
  t.eq(t.emacs_lines(path), want, "Emacs's org buffer unchanged")
  t.eq(t.eval(("(buffer-modified-p (get-file-buffer %q))"):format(path)), "nil")
end

-- The focused buffer's lines, normalized, after checking it mirrors Emacs's
-- export buffer name.
local function shown(t, name)
  assert(api.nvim_buf_get_name(0):find(name, 1, true), "export buffer focused: " .. api.nvim_buf_get_name(0))
  t.eq(t.lines(), t.emacs_lines(name), "Neovim shows Emacs's " .. name)
  return normalize(t.lines())
end

local function export(t, ...)
  t.answer(...)
  t.keys("C-c C-e")
end

return {
  ["h h writes the full HTML page batch Emacs writes"] = function(t)
    local path, buf = open(t, "page", "html")
    export(t, "h", "h")
    local lines = exported(t, "page", "html")
    t.eq(#lines, 232, "line count, <style> included")
    t.eq(drop_style(lines), HTML_PAGE, "page.html")
    unchanged(t, path, buf)
  end,

  ["t u writes the UTF-8 text batch Emacs writes"] = function(t)
    local path, buf = open(t, "utf", "txt")
    export(t, "t", "u")
    t.eq(exported(t, "utf", "txt"), UTF8, "utf.txt")
    unchanged(t, path, buf)
  end,

  ["h H shows the HTML page in an html buffer and writes no file"] = function(t)
    local path, buf = open(t, "hbuf", "html")
    export(t, "h", "H")
    t.eq(drop_style(shown(t, "*Org HTML Export*")), HTML_PAGE, "*Org HTML Export*")
    t.eq(t.eval([[(with-current-buffer "*Org HTML Export*" major-mode)]]), "mhtml-mode")
    local filetype = vim.bo.filetype
    t.eq(vim.bo.modifiable, true)
    t.eq(vim.fn.filereadable(t.WORK .. "/hbuf.html"), 0, "no file")
    t.eq(#api.nvim_list_wins(), 2, "split beside the org window")
    unchanged(t, path, buf)
    t.eq(filetype, "html", "Neovim's filetype for mhtml-mode")
  end,

  ["t A shows the whole document as ASCII"] = function(t)
    local path, buf = open(t, "abuf", "txt")
    export(t, "t", "A")
    t.eq(shown(t, "*Org ASCII Export*"), ASCII, "*Org ASCII Export*")
    t.eq(vim.bo.filetype, "text", "Emacs's text-mode")
    unchanged(t, path, buf)
  end,

  ["t U fills *Org ASCII Export* with the UTF-8 text"] = function(t)
    local path, buf = open(t, "ubuf", "txt")
    export(t, "t", "U")
    t.eq(shown(t, "*Org ASCII Export*"), UTF8, "*Org ASCII Export*")
    unchanged(t, path, buf)
  end,

  ["l L shows the LaTeX in a tex buffer"] = function(t)
    local path, buf = open(t, "lbuf", "tex")
    export(t, "l", "L")
    local lines = shown(t, "*Org LATEX Export*")
    t.eq(vim.list_slice(lines, vim.fn.index(lines, "\\begin{document}") + 1), {
      "\\begin{document}", "", "\\maketitle",
      "\\section*{One}", "\\label{sec:ID}", "Some \\textbf{bold} and \\emph{it} text.",
      "\\subsection*{Sub}", "\\label{sec:ID}",
      "\\begin{itemize}", "\\item item a", "\\item item b", "\\end{itemize}",
      "\\section*{Two}", "\\label{sec:ID}", "Plain — dash.", "\\end{document}",
    }, "LaTeX body")
    t.eq(t.eval([[(with-current-buffer "*Org LATEX Export*" major-mode)]]), "latex-mode")
    local filetype = vim.bo.filetype
    unchanged(t, path, buf)
    t.eq(filetype, "tex", "Neovim's filetype for latex-mode")
  end,

  ["C-s C-b h h writes only the subtree's body"] = function(t)
    local path, buf = open(t, "subbody", "html")
    t.cursor(9)
    export(t, "C-s", "C-b", "h", "h")
    t.eq(#t.asked(), 4)
    local menu = t.asked()[3].params.context
    assert(menu:find("Body only:    On", 1, true) and menu:find("Export scope: Subtree", 1, true),
      "both toggles shown:\n" .. menu)
    t.eq(exported(t, "subbody", "html"), { "<p>", "Plain — dash.", "</p>" }, "subbody.html")
    unchanged(t, path, buf)
  end,

  ["C-v C-b h h leaves out the text of a folded subtree"] = function(t)
    local path, buf = open(t, "vish", "html")
    t.cursor(4)
    t.feed("zc")
    t.eq(t.folds(), { "4-8" }, "* One folded")
    export(t, "C-v", "C-b", "h", "h")
    t.eq(exported(t, "vish", "html"), {
      '<div id="outline-container-ID" class="outline-2">',
      '<h2 id="ID">One</h2>',
      "</div>",
      '<div id="outline-container-ID" class="outline-2">',
      '<h2 id="ID">Two</h2>',
      '<div class="outline-text-2" id="text-ID">',
      "<p>", "Plain — dash.", "</p>", "</div>", "</div>",
    }, "vish.html")
    t.eq(t.folds(), { "4-8" }, "fold kept")
    unchanged(t, path, buf)
  end,

  ["without #+TITLE or #+OPTIONS t a has no title, a toc and numbers"] = function(t)
    local path, buf = open(t, "plain", "txt", PLAIN)
    export(t, "t", "a")
    t.eq(exported(t, "plain", "txt"), {
      "Tester", "", "",
      "Table of Contents", "_________________", "",
      "1. One", ".. 1. Sub", "2. Two", "", "",
      "1 One", "=====", "", "  Some text.", "", "",
      "1.1 Sub", "~~~~~~~", "", "  Deep.", "", "",
      "2 Two", "=====", "", "  More.",
    }, "plain.txt")
    unchanged(t, path, buf, PLAIN)
  end,

  ["without #+TITLE or #+OPTIONS h h has an empty title, a toc and numbers"] = function(t)
    local path, buf = open(t, "plainh", "html", PLAIN)
    export(t, "h", "h")
    local lines = exported(t, "plainh", "html")
    t.eq(lines[9], "<title>&lrm;</title>")
    assert(not vim.tbl_contains(lines, '<h1 class="title">Probe</h1>')
      and not table.concat(lines, "\n"):find('class="title"', 1, true), "no h1 title")
    local body = vim.list_slice(lines, vim.fn.index(lines, '<div id="content" class="content">') + 2)
    t.eq(vim.list_slice(body, 1, 18), {
      '<div id="table-of-contents" role="doc-toc">',
      "<h2>Table of Contents</h2>",
      '<div id="text-table-of-contents" role="doc-toc">',
      "<ul>",
      '<li><a href="#ID">1. One</a>',
      "<ul>",
      '<li><a href="#ID">1.1. Sub</a></li>',
      "</ul>",
      "</li>",
      '<li><a href="#ID">2. Two</a></li>',
      "</ul>",
      "</div>",
      "</div>",
      '<div id="outline-container-ID" class="outline-2">',
      '<h2 id="ID"><span class="section-number-2">1.</span> One</h2>',
      '<div class="outline-text-2" id="text-1">',
      "<p>", "Some text.",
    }, "toc and numbered headings")
    unchanged(t, path, buf, PLAIN)
  end,
}
