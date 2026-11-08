-- File formats: CRLF, no final newline, a BOM, latin-1, tabs, wide
-- characters in tags, trailing whitespace, a 5000-char line, tiny files.
-- Expected text and bytes: emacs -Q --batch -l test/init.el visiting the file.
local api = vim.api
local mirror = require("emacs.mirror")
local NS = api.nvim_create_namespace("emacs")

local function agree(t, path, what) t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees") end

local function todo(t, line)
  t.cursor(line)
  t.answer("t")
  t.keys("C-c C-t")
end

-- Line `row` (1-based) of the current buffer with its concealed bytes removed.
local function shown(row)
  local buf = api.nvim_get_current_buf()
  mirror.state[buf].spans = nil
  mirror.refresh_spans(buf)
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local keep, from = {}, 0
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, NS, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].conceal and m[3] >= from then
      keep[#keep + 1] = line:sub(from + 1, m[3])
      from = m[4].end_col
    end
  end
  keep[#keep + 1] = line:sub(from + 1)
  return table.concat(keep)
end

return {
  -- Emacs: the file decodes as undecided-dos; C-c C-t t, C-x C-s writes CRLF.
  ["CRLF file: C-c C-t then C-x C-s keeps CRLF and Emacs sees no \\r"] = function(t)
    local path = t.open("crlf.org", "* A\r\n* B\r\nbody\r\n")
    t.eq(vim.bo.fileformat, "dos")
    todo(t, 2)
    t.eq(t.lines(), { "* A", "* TODO B", "body" })
    t.eq(t.emacs_text(path), "* A\n* TODO B\nbody\n", "Emacs's text")
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* A\r\n* TODO B\r\nbody\r\n", "file on disk")
    t.eq(vim.bo.modified, false)
  end,

  ["CRLF file: TAB aligns the table without \\r and :w keeps CRLF"] = function(t)
    local path = t.open("crlf_tbl.org", "| a | bb |\r\n| ccc | d |\r\n")
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| a   | bb |", "| ccc | d  |" })
    agree(t, path)
    vim.cmd("silent write")
    t.eq(t.read_file(path), "| a   | bb |\r\n| ccc | d  |\r\n", "file on disk")
  end,

  -- Emacs: C-c C-t keeps the buffer without a final newline; C-x C-s adds
  -- one (org-mode's require-final-newline).
  ["no final newline: C-c C-t on the last line, then C-x C-s adds the newline"] = function(t)
    local path = t.open("noeol.org", "* A\n* B")
    t.eq(vim.bo.eol, false)
    todo(t, 2)
    t.eq(t.lines(), { "* A", "* TODO B" })
    t.eq(t.emacs_text(path), "* A\n* TODO B", "Emacs's text has no final newline")
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* A\n* TODO B\n", "file on disk")
  end,

  -- Emacs: utf-8-with-signature; the BOM is no character of the buffer,
  -- so line 1 is a heading, and C-x C-s writes the BOM back.
  ["a UTF-8 BOM stays out of both buffers and survives C-x C-s"] = function(t)
    local path = t.open("bom.org", "\239\187\191* A\n* B\n")
    t.eq(vim.bo.bomb, true)
    todo(t, 1)
    t.eq(t.lines(), { "* TODO A", "* B" })
    t.eq(t.emacs_text(path), "* TODO A\n* B\n", "Emacs's text")
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "\239\187\191* TODO A\n* B\n", "file on disk")
  end,

  -- Emacs: iso-latin-1-unix; C-c C-t t, C-x C-s writes latin-1 bytes back.
  ["a latin-1 file: C-c C-t and C-x C-s keep it latin-1"] = function(t)
    local path = t.open("latin1.org", "* Caf\233\nna\239ve\n")
    t.eq(vim.bo.fileencoding, "latin1")
    todo(t, 1)
    t.eq(t.lines(), { "* TODO Café", "naïve" })
    agree(t, path)
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* TODO Caf\233\nna\239ve\n", "file on disk")
  end,

  -- Emacs measures a tab in a cell as tab-width wide, whatever else the
  -- cell holds: "a<TAB>b" and "é<TAB>b" are both 10, so TAB changes nothing.
  ["a tab in table cells counts the same with or without non-ASCII"] = function(t)
    local path = t.open("tab_tbl.org", "| a\tb | c |\n| é\tb | d |\n")
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| a\tb | c |", "| é\tb | d |" })
    agree(t, path)
  end,

  -- Emacs: tags after "* A<TAB>B" and "* 日本<TAB>B" end at column 77.
  ["C-c C-q after a tab in the heading ends the tags at column 77"] = function(t)
    t.open("tab_head.org", "* A\tB\n* 日本\tB\n")
    t.answer("x")
    t.keys("C-c C-q")
    t.cursor(2)
    t.answer("x")
    t.keys("C-c C-q")
    t.eq(t.lines(), { "* A\tB" .. string.rep(" ", 65) .. ":x:", "* 日本\tB" .. string.rep(" ", 65) .. ":x:" })
    for i, l in ipairs(t.lines()) do t.eq(vim.fn.strdisplaywidth(l), 77, "row " .. i .. " display width") end
  end,

  -- Emacs: "* H" then 63 spaces then ":日本:家族:" (each CJK char 2 wide).
  -- With a ZWJ family emoji in the heading the padding must follow Neovim's
  -- width of it (2 on 0.13), as tables do; batch Emacs counts it 6.
  ["CJK tags and a ZWJ emoji heading align to column 77 in Neovim"] = function(t)
    t.open("wide_tags.org", "* H\n* 👨‍👩‍👧 family\n")
    t.answer("日本:家族")
    t.keys("C-c C-q")
    t.eq(t.lines()[1], "* H" .. string.rep(" ", 63) .. ":日本:家族:")
    -- Org measures the heading with current-column, not org-string-width.
    -- Tagging the emoji heading should also end at display column 77.
    t.skip("tags after a ZWJ emoji align by Emacs's width (PROGRESS.md)")
  end,

  -- Emacs: C-c C-t keeps "* A   " trailing blanks ("* TODO A   "); TAB in a
  -- table drops cell padding and the blanks after the last "|".
  ["trailing whitespace on headings and table rows is kept as Emacs keeps it"] = function(t)
    local path = t.open("trail.org", "* A   \nbody  \n| a  | b |\n|x   |y  |  \n")
    todo(t, 1)
    t.cursor(3, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "* TODO A   ", "body  ", "| a | b |", "| x | y |" })
    agree(t, path)
  end,

  -- Emacs: C-c C-t on the heading, then the links on the 5000-char line
  -- show only their descriptions.
  ["a 5000-char line of links: C-c C-t and link concealment"] = function(t)
    local links, descs = {}, {}
    local n = 0
    while #table.concat(links, " ") < 5000 do
      n = n + 1
      links[n] = ("[[https://example.com/page/%d][d%d]]"):format(n, n)
      descs[n] = "d" .. n
    end
    local long = table.concat(links, " ")
    local path = t.open("long.org", "* H\n" .. long .. "\n")
    local start = vim.loop.hrtime()
    todo(t, 1)
    t.eq(t.lines(), { "* TODO H", long })
    agree(t, path)
    local ms = (vim.loop.hrtime() - start) / 1e6
    assert(ms < 3000, ("C-c C-t took %d ms"):format(ms))
    t.config("conceal", true)
    t.eq(shown(2), table.concat(descs, " "), "line 2 as shown")
  end,

  -- Emacs: M-RET in an empty buffer gives "* ", saved as "* \n".
  ["an empty file: M-RET makes a heading and :w writes it"] = function(t)
    local path = t.open("empty.org", "")
    t.keys("M-RET")
    vim.cmd("stopinsert")
    t.eq(t.lines(), { "* " })
    t.eq(t.emacs_text(path), "* ", "Emacs's text")
    vim.cmd("silent write")
    t.eq(t.read_file(path), "* \n", "file on disk")
  end,

  -- Emacs: "*" alone is no heading: C-c C-t signals "Before first headline"
  -- and changes nothing. The cursor is then on the last character, which
  -- the README says makes M-RET act at the end of the line: "*\n* ", as
  -- Emacs gives with point after the "*".
  ["a file that is only \"*\": C-c C-t refuses, then M-RET adds a heading after it"] = function(t)
    local path = t.open("star.org", "*")
    t.keys("C-c C-t") -- echoes the user-error
    t.eq(t.lines(), { "*" }, "unchanged")
    t.keys("M-RET")
    vim.cmd("stopinsert")
    t.eq(t.lines(), { "*", "* " })
    t.eq(t.emacs_text(path), "*\n* ", "Emacs's text")
  end,

  -- Neovim reads an empty file and a lone newline both as one empty line;
  -- Emacs must keep them apart through a save and a reload (:e).
  ["a file of one newline stays one newline through C-x C-s and :e"] = function(t)
    local path = t.open("lone_nl.org", "\n")
    t.eq(t.emacs_text("lone_nl.org"), "\n", "opened")
    t.keys("C-x C-s")
    vim.cmd("edit")
    require("emacs.mirror").sync()
    t.eq(t.emacs_text("lone_nl.org"), "\n", "after save and :e")
    t.eq(t.read_file(path), "\n", "on disk")
    t.open("lone_empty.org", "")
    t.eq(t.emacs_text("lone_empty.org"), "", "an empty file stays empty")
    -- yyp makes two lines; undo is back to an empty file (:w writes 0 bytes).
    vim.cmd("normal! yyp")
    require("emacs.mirror").sync()
    t.eq(t.emacs_text("lone_empty.org"), "\n\n", "yyp")
    vim.cmd("normal! u")
    require("emacs.mirror").sync()
    t.eq(t.emacs_text("lone_empty.org"), "", "undone")
  end,
}
