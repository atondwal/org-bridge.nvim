-- Display-only org features: what Emacs draws without changing the text.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")

local function marks(row)
  return api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })
end

-- Concealed ranges on `row` as { start_col, end_col, replacement } triples.
local function conceals(row)
  local out = {}
  for _, m in ipairs(marks(row)) do
    if m[4].conceal then out[#out + 1] = { m[3], m[4].end_col, m[4].conceal } end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

-- Text of the inline virtual text at the start of `row`, or nil.
local function inline_prefix(row)
  for _, m in ipairs(marks(row)) do
    if m[3] == 0 and m[4].virt_text_pos == "inline" then
      local s = ""
      for _, chunk in ipairs(m[4].virt_text) do s = s .. chunk[1] end
      return s
    end
  end
end

local INDENT_DOC = "#+STARTUP: indent\n* A\ntext a\n** B\ntext b\n"

return {
  -- As Emacs's display, only text on screen gets faces: an overview of a
  -- long file asks for its headings' lines, not the bodies folded away.
  ["in an overview, faces are fetched for the headings shown, not folded bodies"] = function(t)
    local body = ("body *bold*\n"):rep(300)
    t.open("overview.org", "* A\n" .. body .. "* B\n" .. body .. "* C\n" .. body)
    t.keys("<backtab>")
    t.eq(vim.fn.foldclosed(2), 1, "A folded")
    local buf = api.nvim_get_current_buf()
    mirror.state[buf].spans = nil
    mirror.refresh_spans(buf)
    for _, row in ipairs({ 0, 301, 602 }) do
      local faced = vim.tbl_filter(function(m) return m[4].hl_group end, marks(row))
      assert(#faced > 0, "heading on line " .. (row + 1) .. " has its face")
    end
    local fetched = 0
    for _, r in ipairs(mirror.state[buf].spans.ranges) do fetched = fetched + r[2] - r[1] + 1 end
    assert(fetched < 100, "lines fetched: " .. fetched)
  end,

  -- Emacs adds these from an idle timer (org-indent-initialize-agent); the
  -- bridge runs short idle timers at the end of each RPC, so they are set
  -- when t.open returns.
  ["#+STARTUP: indent gives body lines a line-prefix in Emacs"] = function(t)
    t.open("indent.org", INDENT_DOC)
    t.eq(t.eval('(with-current-buffer "indent.org" org-indent-mode)'), "t", "org-indent-mode")
    t.eq(t.eval([[(with-current-buffer "indent.org"
      (save-excursion (goto-char (point-min)) (forward-line 4)
        (substring-no-properties (or (get-text-property (point) 'line-prefix) "none"))))]]),
      '"    "', "line-prefix of the body under ** B")
  end,

  ["org-indent line-prefix shows in Neovim as inline virtual text"] = function(t)
    if vim.fn.has("nvim-0.10") == 0 then t.skip("inline virtual text needs Neovim 0.10") end
    t.open("indent2.org", INDENT_DOC)
    t.eval('(with-current-buffer "indent2.org" (org-indent-indent-buffer))')
    mirror.state[api.nvim_get_current_buf()].spans = nil
    mirror.refresh_spans(api.nvim_get_current_buf())
    t.eq({ inline_prefix(2), inline_prefix(4) }, { "  ", "    " }, "body prefixes")
    -- A heading's prefix is stars in the background's color; spaces look the
    -- same and keep a cursor there visible.
    t.eq(inline_prefix(3), " ", "** B's prefix")
  end,

  ["org-hide-emphasis-markers conceals the markers"] = function(t)
    t.set("org-hide-emphasis-markers", "t")
    t.config("conceal", true)
    t.open("emph.org", "x *bold* /it/ y\n")
    t.eq(conceals(0), { { 2, 3, "" }, { 7, 8, "" }, { 9, 10, "" }, { 12, 13, "" } })
  end,

  -- Emacs: `_` gets invisible, `\alpha` a composition drawn as α.
  ["C-c C-x \\ (pretty entities) conceals sub markers and shows entities"] = function(t)
    t.config("conceal", true)
    t.open("pretty.org", "x \\alpha y a_1\n")
    t.keys("C-c C-x \\")
    t.eq(t.eval('(with-current-buffer "pretty.org" org-pretty-entities)'), "t")
    local c = conceals(0)
    t.eq(vim.tbl_filter(function(r) return r[1] == 12 end, c), { { 12, 13, "" } }, "a_1 marker")
    t.eq(vim.tbl_filter(function(r) return r[1] == 2 end, c), { { 2, 8, "α" } }, "\\alpha")
  end,

  ["a custom org-ellipsis ends the fold text"] = function(t)
    t.set("org-ellipsis", '" ▼"')
    t.open("ellipsis.org", "* A\nbody\n* B\n")
    t.keys("TAB")
    t.eq(t.folds(), { "1-2" })
    t.eq(vim.fn.foldtextresult(1), "* A ▼")
  end,

  -- Emacs draws org-hide in the background color. Painted so in Neovim, a
  -- cursor on a star vanishes where the terminal inverts the cell's colors;
  -- spaces drawn over the stars look the same and keep it visible.
  ["org-hide-leading-stars draws leading stars as spaces"] = function(t)
    t.set("org-hide-leading-stars", "t")
    t.open("stars.org", "* A\n*** B\n")
    local cover
    for _, m in ipairs(marks(1)) do
      if m[3] == 0 and m[4].virt_text_pos == "overlay" then cover = m[4] end
    end
    assert(cover, "nothing drawn over the leading stars")
    t.eq(cover.virt_text, { { "  " } })
    t.eq(cover.hl_mode, "combine", "the line's own highlight (cursorline) shows through")
  end,

  -- Emacs draws a face past the text when the newline has it and the face
  -- is :extend (org-block is); other faces on a newline stop at the text.
  ["an :extend face on the newline fills the window line, others don't"] = function(t)
    t.open("extend.org", "* A\n#+begin_src text\ncode\n#+end_src\n")
    t.eval([[(with-current-buffer "extend.org"
      (overlay-put (make-overlay 1 5) 'face 'bold)
      (overlay-put (make-overlay 1 5) 'face 'nvb-test-undefined-face))]])
    t.command("ignore")
    local function extended(row)
      for _, m in ipairs(marks(row)) do
        if m[4].hl_eol then return m[4].hl_group end
      end
    end
    t.eq(extended(2), "EmacsFace_org_block", "org-block on the newline")
    t.eq(extended(0), nil, "bold on the newline")
    -- An undefined face (also on row 0) is skipped, as it was for the text.
  end,

  -- Column view draws its table with overlays on unchanged text.
  ["column view: org-column face, S-right cycles TODO, C-c C-c quits"] = function(t)
    t.open("cv.org", "* TODO A\n:PROPERTIES:\n:Effort: 1:00\n:END:\n* B\n")
    t.keys("C-c C-x C-c")
    local column_face = false
    -- Column cells are display overlays: drawn as virtual text in their face.
    for _, m in ipairs(marks(0)) do
      local vt = m[4].virt_text
      if m[4].hl_group == "EmacsFace_org_column" or (vt and vt[1][2] == "EmacsFace_org_column") then
        column_face = true
      end
    end
    t.cursor(1, 1)
    t.keys("S-<right>")
    t.eq(t.lines()[1], "* NEXT A")
    t.keys("C-c C-c")
    t.eq(t.eval([[(with-current-buffer "cv.org"
      (length (seq-filter (lambda (o) (overlay-get o 'display)) (overlays-in (point-min) (point-max)))))]]),
      "0", "column overlays left")
    assert(column_face, "no org-column highlight right after C-c C-x C-c")
  end,

  -- The outline interface runs a recursive edit with its own keymap.
  ["C-c C-j (org-goto) reaches the chosen heading with both interfaces"] = function(t)
    t.open("goto.org", "* A\n** A1\n* B\n** B1\n")
    t.eval("(require 'org-goto)")
    t.set("org-goto-interface", "'outline-path-completion")
    -- Earlier tests' refile answers would be the prompt's default.
    t.set("org-refile-history", "nil")
    t.answer("B/B1")
    t.keys("C-c C-j")
    t.eq(api.nvim_win_get_cursor(0)[1], 4, "outline-path-completion")
    t.eq(t.asked()[1].params.prompt, "Goto: ")
    t.cursor(1)
    t.set("org-goto-interface", "'outline")
    t.answer("<down>", "RET")
    local ok, err = pcall(t.keys, "C-c C-j")
    assert(ok, "org-goto outline interface: " .. tostring(err))
    t.eq(api.nvim_win_get_cursor(0)[1], 3, "outline interface")
  end,

  -- Lines a fold hides must not also be concealed: Neovim can open the fold
  -- (search, :normal! zo) while Emacs keeps it closed.
  ["lines inside a fold Neovim opened are not blanked"] = function(t)
    t.open("blank.org", t.DOC)
    t.keys("<backtab>")
    vim.cmd("normal! zR")
    local mirror = require("emacs.mirror")
    mirror.state[api.nvim_get_current_buf()].spans = nil
    mirror.refresh_spans(api.nvim_get_current_buf())
    for _, m in ipairs(api.nvim_buf_get_extmarks(0, NS, 0, -1, { details = true })) do
      local line = api.nvim_buf_get_lines(0, m[2], m[2] + 1, false)[1]
      assert(not (m[4].conceal and m[3] == 0 and (m[4].end_col or 0) >= #line),
        "line " .. (m[2] + 1) .. " concealed whole")
    end
  end,

  ["column view leaves keys Emacs doesn't bind to Neovim"] = function(t)
    t.open("cvkeys.org", "* TODO A\n:PROPERTIES:\n:Effort: 1:00\n:END:\n")
    t.keys("C-c C-x C-c")
    t.eq(vim.fn.maparg("G", "n", false, true).buffer, nil, "G stays a motion")
    t.eq(vim.fn.maparg("e", "n", false, true).buffer, 1, "e edits the value")
    t.keys("q")
  end,
}
