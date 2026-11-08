-- Non-ASCII text: Neovim columns are bytes, Emacs positions are characters.
local api = vim.api
local mirror = require("emacs.mirror")
local faces = require("emacs.faces")
local NS = api.nvim_create_namespace("emacs")

-- Extmarks after a fresh span fetch, as { line, start, end } per face or
-- "conceal". Adjacent extmarks of one face are merged: Emacs splits a face
-- run wherever any other text property changes.
local function spans()
  local buf = api.nvim_get_current_buf()
  mirror.state[buf].spans = nil
  mirror.refresh_spans(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
    local key = m[4].conceal and "conceal" or m[4].hl_group
    out[key] = out[key] or {}
    local prev = out[key][#out[key]]
    if prev and prev[1] == m[2] and prev[3] == m[3] then
      prev[3] = m[4].end_col
    else
      table.insert(out[key], { m[2], m[3], m[4].end_col })
    end
  end
  return out
end

return {
  ["C-c C-t keeps the cursor on the same CJK character"] = function(t)
    t.open("todo.org", "* 日本語 見出し 🎉\nbody\n")
    t.cursor(1, 12) -- on 見
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[1], "* TODO 日本語 見出し 🎉")
    t.eq(api.nvim_win_get_cursor(0), { 1, 17 }, "still on 見")
  end,

  ["M-RET on an emoji splits the heading before it"] = function(t)
    -- A character after the emoji: on the last character, M-RET means
    -- "after this line" instead (Vim's cursor sits on that character).
    t.open("split.org", "* 日本語 🎉x\n")
    t.cursor(1, 12) -- on 🎉
    t.keys("M-RET")
    t.eq(t.lines(), { "* 日本語 ", "* 🎉x" })
    -- Emacs leaves point at the end of the new heading (byte 6); normal
    -- mode puts the cursor on the last character.
    t.eq(api.nvim_win_get_cursor(0)[1], 2)
  end,

  ["S-right after tabs, ZWJ emoji and combining marks changes the day under the cursor"] = function(t)
    t.open("date.org", "* H\n<2026-11-07 Sat> é\n")
    -- Typed in Neovim, so the multibyte prefix reaches Emacs by sync.
    api.nvim_buf_set_text(0, 1, 0, 1, 0, { "\tçà 日本 👨‍👩‍👧 e\u{301} " })
    t.cursor(2, 45) -- on the 7 of 07
    t.keys("S-<right>")
    t.eq(t.lines()[2], "\tçà 日本 👨‍👩‍👧 e\u{301} <2026-11-08 Sun> é")
    t.eq(api.nvim_win_get_cursor(0), { 2, 45 })
  end,

  ["a visual selection of CJK text becomes the link description"] = function(t)
    t.open("region.org", "* H\nsee 日本語 here\n")
    t.cursor(2, 4)
    t.answer("C-l", "https://w.com", "日本語")
    api.nvim_feedkeys("v2l" .. api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    t.eq(t.asked()[3].params.initial, "日本語", "description defaults to the region")
    t.eq(t.lines()[2], "see [[https://w.com][日本語]] here")
    t.eq(api.nvim_win_get_cursor(0), { 2, 32 }, "after the link")
  end,

  ["faces land on the right bytes after multibyte text"] = function(t)
    t.open("faces.org", "* TODO 日本 🎉 *太字* end\n")
    local got = spans()
    t.eq(got[faces.group("org-todo")], { { 0, 2, 6 } }, "org-todo")
    t.eq(got[faces.group("bold")], { { 0, 19, 27 } }, "bold")
  end,

  ["link brackets after multibyte text and tabs are concealed"] = function(t)
    t.open("conceal.org", "çé 日本語 [[https://x.com][リンク]] é\t[[a]] 終\n")
    local default = mirror.config.conceal
    mirror.config.conceal = true
    local ok, got = pcall(spans)
    mirror.config.conceal = default
    assert(ok, got)
    t.eq(got.conceal, { { 0, 15, 32 }, { 0, 41, 43 }, { 0, 47, 49 }, { 0, 50, 52 } })
    -- Emacs faces the brackets too, but the bridge sends no face for
    -- invisible text, so only the visible parts are highlighted.
    t.eq(got[faces.group("org-link")], { { 0, 32, 41 }, { 0, 49, 50 } }, "org-link")
  end,

  ["tables align wide characters by display width"] = function(t)
    t.open("table.org", "| 名前 | x |\n|-\n| ab | 🎉 |\n| é | naïve |\n")
    t.cursor(1, 2)
    t.keys("TAB")
    t.eq(t.lines(), { "| 名前 | x     |", "|------+-------|", "| ab   | 🎉    |", "| é    | naïve |" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 11 }, "next field")
    for i, l in ipairs(t.lines()) do
      t.eq(vim.fn.strdisplaywidth(l), 16, "row " .. i .. " display width in Neovim")
    end
  end,

  ["TAB folds a multibyte heading and keeps the cursor on its character"] = function(t)
    t.open("fold.org", "* 日本 🎉 見出し\nbody é\n** 子 🎉\n子 body\n* 次\n")
    t.cursor(1, 14) -- on 見
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 14 })
    t.keys("TAB")
    t.eq(t.folds(), { "3-4" }, "children")
  end,

  -- Emacs measures 👍🏽 as 4 columns and ❤️ as 1 (char-width-table, no
  -- grapheme clusters in batch); Neovim 0.13 shows both as 2, 0.9.5 shows
  -- 🇯🇵 as 4 where Emacs says 2.
  ["tables with emoji sequences line up in Neovim"] = function(t)
    t.open("emoji.org", "| a | b |\n| 👍🏽 | ❤️ |\n| xy | 🇯🇵 |\n")
    t.cursor(1, 2)
    t.keys("TAB")
    -- Org measures through Neovim, so the padding fits Neovim's widths
    -- (which differ between 0.9 and 0.13), not batch Emacs's.
    local widths = vim.tbl_map(vim.fn.strdisplaywidth, t.lines())
    t.eq(widths, { widths[1], widths[1], widths[1] }, "display widths")
  end,

  -- With 'fileencodings' utf-8 and ++bad=keep, Neovim keeps the raw bytes,
  -- which the UTF-8 socket can't carry: the bridge refuses the buffer.
  ["a buffer holding an invalid UTF-8 byte is refused clearly"] = function(t)
    local path = t.file("bad.org", "* H\xff caf\xe9\n<2026-11-07 Sat>\n")
    local fencs = vim.o.fileencodings
    vim.o.fileencodings = "utf-8"
    vim.cmd("silent edit ++bad=keep " .. vim.fn.fnameescape(path))
    vim.o.fileencodings = fencs
    t.cursor(2, 9)
    local ok, err = pcall(t.keys, "S-<right>")
    assert(not ok and tostring(err):find("not valid UTF%-8"), "refused: " .. tostring(err))
    t.eq(t.lines(), { "* H\xff caf\xe9", "<2026-11-07 Sat>" }, "untouched")
    t.eq(t.eval("(+ 1 1)"), "2", "Emacs still serving")
  end,
}
