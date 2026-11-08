-- Sparse trees: the C-c / dispatcher, regexp and TODO trees, the occur
-- highlights, and C-c C-c removing them. Expected folds and spans are
-- nvb--hidden-ranges / nvb--spans in Emacs after the same keys.
local DOC = table.concat({
  "* TODO Alpha",
  "alpha body foo",
  "** Alpha child",
  "child text",
  "** NEXT Alpha two",
  "more foo here",
  "* DONE Beta",
  "beta body",
  "** TODO Beta child",
  "bc text",
  "* Gamma :work:",
  "gamma foo",
  "** Gamma child",
  "gc text",
  "",
}, "\n")

-- Occur highlights in the current buffer as { line, start, end } (0-based).
-- Spans split where font-lock faces change, so adjacent ones are merged.
local function highlights()
  local ns = vim.api.nvim_create_namespace("emacs")
  local group = require("emacs.faces").group("secondary-selection")
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    if m[4].hl_group == group then
      local prev = out[#out]
      if prev and prev[1] == m[2] and prev[3] == m[3] then
        prev[3] = m[4].end_col
      else
        out[#out + 1] = { m[2], m[3], m[4].end_col }
      end
    end
  end
  return out
end

local FOO_FOLDS = { "3-4", "7-10", "13-14" }
local FOO_MATCHES = { { 1, 11, 14 }, { 5, 5, 8 }, { 11, 6, 9 } }
local TODO_FOLDS = { "1-4", "5-6", "7-8", "9-10", "11-14" }
local TODO_MATCHES = { { 0, 0, 7 }, { 4, 0, 8 }, { 8, 0, 8 } }
local function foo_tree(t, name)
  t.open(name, DOC)
  t.answer("r", "foo")
  t.keys("C-c /")
end

local function todo_tree(t, name)
  t.open(name, DOC)
  t.answer("t")
  t.keys("C-c /")
end

return {
  ["C-c / r asks for a regexp and folds all but the matches"] = function(t)
    foo_tree(t, "regexp.org")
    t.eq(t.folds(), FOO_FOLDS)
    local key, regexp = t.asked()[1], t.asked()[2]
    t.eq(key.method, "read_key")
    assert(key.params.prompt:find("^Sparse tree: %[r%]egexp"), "dispatcher prompt: " .. vim.inspect(key))
    t.eq({ regexp.method, regexp.params.prompt }, { "read_string", "Regexp: " })
  end,

  ["regexp matches reach Neovim as secondary-selection spans"] = function(t)
    foo_tree(t, "hl.org")
    t.eq(highlights(), FOO_MATCHES)
  end,

  ["C-c / t folds to the TODO tree and echoes the count"] = function(t)
    todo_tree(t, "todo.org")
    t.eq(t.folds(), TODO_FOLDS)
    assert(vim.fn.execute("messages"):find("3 TODO entries found", 1, true), "count echoed")
  end,

  ["TODO tree matches reach Neovim as secondary-selection spans"] = function(t)
    todo_tree(t, "todohl.org")
    t.eq(highlights(), TODO_MATCHES)
  end,

  ["C-c C-c removes the highlights and keeps the folds"] = function(t)
    todo_tree(t, "clear.org")
    t.eq(highlights(), TODO_MATCHES, "highlights before C-c C-c")
    t.cursor(1)
    t.keys("C-c C-c")
    t.eq(t.eval("org-occur-highlights"), "nil", "Emacs dropped its overlays")
    t.eq(highlights(), {}, "Neovim dropped the spans")
    t.eq(t.folds(), TODO_FOLDS)
  end,

  ["C-c / T reads a keyword with completion"] = function(t)
    t.open("kwd.org", DOC)
    t.answer("T", "NEXT")
    t.keys("C-c /")
    t.eq(t.asked()[2].method, "completing_read")
    t.eq(t.folds(), { "1-4", "5-6", "7-10", "11-14" })
  end,

  ["an unknown dispatcher key reports Emacs's error"] = function(t)
    t.open("bad.org", DOC)
    t.answer("x")
    t.keys("C-c /")
    assert(vim.fn.execute("messages"):find('No such sparse tree command "x"', 1, true),
      "error echoed: " .. vim.fn.execute("messages"))
  end,

  -- Typing " bar" at the end of line 2 in Emacs drops the highlights (org's
  -- before-change hook) and reveals Alpha child; Gamma child stays folded.
  -- The tree is built with org-occur directly: C-c / r has its own bug.
  ["an edit in Neovim changes folds like the same edit in Emacs"] = function(t)
    local path = t.open("edit.org", DOC)
    t.eval(('(with-current-buffer (find-buffer-visiting "%s") (org-occur "foo"))'):format(path))
    t.command("ignore")
    t.eq(t.folds(), FOO_FOLDS, "occur folds")
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "alpha body foo bar" })
    require("emacs.mirror").sync()
    t.eq(t.eval("org-occur-highlights"), "nil", "Emacs dropped its overlays")
    t.eq(t.folds(), { "7-10", "13-14" })
  end,
}
