-- Navigation by headings, elements, links and blocks; transposing and
-- narrowing to an element; indirect subtree buffers; copying visible text.
-- M-}, C-M-t and C-x n aren't Neovim keys here, so tests send them with t.keys.

local DOC = table.concat({
  "* A",
  "para one",
  "line two",
  "",
  "para two",
  "** A1",
  "- item 1",
  "- item 2",
  "#+BEGIN_SRC sh",
  "echo hi",
  "#+END_SRC",
  "** A2",
  "see [[https://a.example][a]] and [[file:x.org][x]]",
  "#+BEGIN_QUOTE",
  "q",
  "#+END_QUOTE",
  "* B",
  "body b",
  "",
}, "\n")

local LINES = vim.split(DOC:sub(1, -2), "\n")

local function cursor() return vim.api.nvim_win_get_cursor(0) end

-- Cursor after each of keys, run one command at a time.
local function walk(t, keys)
  local out = {}
  for _, k in ipairs(keys) do
    t.keys(k)
    out[#out + 1] = cursor()
  end
  return out
end

local function messages() return vim.fn.execute("messages") end

local function has_message(text)
  local msgs = messages()
  assert(msgs:find(text, 1, true), ("message %q shown: %s"):format(text, msgs))
end

-- Accessible region in Emacs as "first-last" lines (last = point-max's line).
local function restriction(t, path)
  return vim.json.decode(t.eval(([[(with-current-buffer (get-file-buffer %q)
    (format "%%d-%%d" (line-number-at-pos (point-min) t) (line-number-at-pos (point-max) t)))]]):format(path)))
end

return {
  ["C-c C-f and C-c C-b move between same-level headings"] = function(t)
    t.open("samelevel.org", DOC)
    local f = "C-c C-f"
    t.eq(walk(t, { f, f }), { { 17, 0 }, { 17, 0 } }, "A to B, then no further sibling")
    t.eq(walk(t, { "C-c C-b" }), { { 1, 0 } })
    t.cursor(6)
    t.eq(walk(t, { f, "C-c C-b" }), { { 12, 0 }, { 6, 0 } }, "A1 and A2")
    -- From body text the current heading counts: q is in A2, so back is A1.
    t.cursor(15)
    t.eq(walk(t, { "C-c C-b" }), { { 6, 0 } }, "from inside A2")
    t.eq(t.lines(), LINES)
  end,

  ["M-} and M-{ move by org element"] = function(t)
    t.open("element.org", DOC)
    t.cursor(2)
    t.eq(walk(t, { "M-}", "M-}", "M-}" }), { { 5, 0 }, { 6, 0 }, { 12, 0 } }, "paragraphs, then headings")
    t.cursor(7, 3)
    t.eq(walk(t, { "M-}", "M-}", "M-}", "M-}" }), { { 8, 0 }, { 9, 0 }, { 12, 0 }, { 17, 0 } },
      "item, block, heading")
    vim.cmd("messages clear")
    t.eq(walk(t, { "M-}" }), { { 17, 0 } })
    has_message("Cannot move further down")
    t.cursor(16)
    t.eq(walk(t, { "M-{", "M-{", "M-{", "M-{", "M-{" }), { { 14, 0 }, { 13, 0 }, { 12, 0 }, { 6, 0 }, { 1, 0 } })
    vim.cmd("messages clear")
    t.eq(walk(t, { "M-{" }), { { 1, 0 } })
    has_message("Cannot move further up")
  end,

  ["C-c C-^ goes up the element tree, C-c C-_ down"] = function(t)
    t.open("updown.org", DOC)
    t.cursor(8, 4)
    local up = "C-c C-^"
    -- paragraph, item, list, heading A1, heading A
    t.eq(walk(t, { up, up, up, up }), { { 8, 0 }, { 7, 0 }, { 6, 0 }, { 1, 0 } })
    vim.cmd("messages clear")
    t.eq(walk(t, { up }), { { 1, 0 } })
    has_message("No surrounding element")
    t.cursor(6)
    t.eq(walk(t, { "C-c C-_" }), { { 7, 0 } }, "A1 into its list")
    t.cursor(2)
    vim.cmd("messages clear")
    t.eq(walk(t, { "C-c C-_" }), { { 2, 0 } }, "a paragraph has no inner element")
    has_message("No inner element")
  end,

  ["C-c C-x C-n and C-c C-x C-p visit links and wrap on the next press"] = function(t)
    t.open("links.org", DOC)
    local n, p = "C-c C-x C-n", "C-c C-x C-p"
    vim.cmd("messages clear")
    t.eq(walk(t, { n, n, n }), { { 13, 4 }, { 13, 33 }, { 13, 33 } })
    has_message("No further link found")
    -- Pressed again right after failing, org wraps to the start.
    t.eq(walk(t, { n }), { { 13, 4 } }, "wrapped")
    has_message("Link search wrapped back to beginning of buffer")
    t.cursor(17)
    t.eq(walk(t, { p, p }), { { 13, 33 }, { 13, 4 } })
    vim.cmd("messages clear")
    t.eq(walk(t, { p, p }), { { 13, 4 }, { 13, 33 } }, "fails, then wraps to the end")
    has_message("Link search wrapped back to end of buffer")
  end,

  ["C-c M-f and C-c M-b move between blocks"] = function(t)
    t.open("blocks.org", DOC)
    t.eq(walk(t, { "C-c M-f", "C-c M-f" }), { { 9, 0 }, { 14, 0 } }, "src then quote block")
    vim.cmd("messages clear")
    t.eq(walk(t, { "C-c M-f" }), { { 14, 0 } })
    has_message("No further code blocks")
    t.eq(walk(t, { "C-c M-b" }), { { 9, 0 } })
    vim.cmd("messages clear")
    t.eq(walk(t, { "C-c M-b" }), { { 9, 0 } })
    has_message("No previous code blocks")
  end,

  ["C-M-t swaps an element with the one before it"] = function(t)
    local path = t.open("transpose.org", DOC)
    t.cursor(5)
    t.keys("C-M-t")
    -- The blank line after "line two" travels with its paragraph.
    t.eq({ unpack(t.lines(), 1, 6) }, { "* A", "para two", "", "para one", "line two", "** A1" })
    t.eq(cursor(), { 6, 0 })
    t.eq(t.emacs_lines(path), t.lines())
    t.cursor(9)
    t.keys("C-M-t")
    t.eq({ unpack(t.lines(), 6, 11) }, { "** A1", "#+BEGIN_SRC sh", "echo hi", "#+END_SRC", "- item 1", "- item 2" },
      "src block before the list")
    t.eq(cursor(), { 12, 0 })
    -- The first paragraph inside an item has nothing before it.
    t.open("transpose_first.org", DOC)
    t.cursor(8, 2)
    vim.cmd("messages clear")
    t.keys("C-M-t")
    t.eq(t.lines(), LINES)
    has_message("Cannot drag element backward")
  end,

  ["C-x n e narrows Emacs to the element and C-x n w widens"] = function(t)
    local path = t.open("narrowelt.org", DOC)
    t.cursor(9)
    t.keys("C-x n e")
    t.eq(restriction(t, path), "9-12", "the src block")
    -- A documented limitation: Neovim keeps showing the whole file.
    t.eq(t.lines(), LINES)
    t.eq(cursor(), { 9, 0 })
    t.cursor(2)
    vim.cmd("messages clear")
    t.keys("M-}")
    has_message("Cursor is outside the narrowed region")
    t.keys("C-x n w")
    t.eq(restriction(t, path), "1-19")
    t.cursor(2)
    t.keys("C-x n e")
    t.eq(restriction(t, path), "2-5", "a paragraph with its blank line")
    t.keys("C-x n w")
    t.cursor(7)
    t.keys("C-x n e")
    t.eq(restriction(t, path), "7-9", "an item narrows to its list")
  end,

  ["C-x n w from outside the restriction keeps the cursor"] = function(t)
    local path = t.open("widenout.org", DOC)
    t.cursor(9)
    t.keys("C-x n e")
    t.cursor(2)
    t.keys("C-x n w")
    t.eq(restriction(t, path), "1-19")
    t.eq(cursor(), { 2, 0 })
  end,

  ["C-c C-x b shows the subtree in an indirect buffer whose edits reach the file"] = function(t)
    local path = t.open("indirect.org", DOC)
    local base = vim.api.nvim_get_current_buf()
    t.cursor(6)
    t.keys("C-c C-x b")
    -- Emacs pops the indirect buffer in another window and keeps the
    -- original window selected.
    t.eq(vim.api.nvim_get_current_buf(), base, "original window stays current")
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 2, "a second window")
    local other
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) ~= base then other = w end
    end
    assert(other, "a window on another buffer")
    local ibuf = vim.api.nvim_win_get_buf(other)
    t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ibuf), ":t"), "indirect.org::A1")
    t.eq(t.lines(ibuf), { "** A1", "- item 1", "- item 2", "#+BEGIN_SRC sh", "echo hi", "#+END_SRC" })
    -- Edit in the indirect buffer: the base buffer, in both editors, follows.
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_set_cursor(other, { 2, 0 })
    vim.api.nvim_buf_set_lines(ibuf, 1, 2, false, { "- item one" })
    t.keys("C-c C-_")
    t.eq(t.emacs_lines(path)[7], "- item one", "Emacs's base buffer")
    t.eq(t.lines(base)[7], "- item one", "Neovim's file buffer")
    t.eq(vim.bo[base].modified, true)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(base))
    vim.cmd("write")
    t.eq(vim.split(t.read_file(path), "\n")[7], "- item one", "saved")
  end,

  ["C-c C-x v copies the visible text into the unnamed register"] = function(t)
    t.open("copyvis.org", DOC)
    t.cursor(6)
    t.keys("TAB")
    t.eq(t.folds(), { "6-11" }, "A1 folded")
    t.cursor(5)
    t.answer("C-x", "v") -- the rest of C-c C-x v, read by Emacs
    t.feed("Vjj<C-c>")
    t.eq(vim.fn.getreg('"'), "para two\n** A1\n** A2\n")
    t.eq(vim.fn.getregtype('"'), "V")
    t.eq(t.eval("(substring-no-properties (current-kill 0))"), "\"para two\n** A1\n** A2\n\"", "Emacs's kill ring")
    t.eq(t.lines(), LINES, "buffer unchanged")
  end,
}
