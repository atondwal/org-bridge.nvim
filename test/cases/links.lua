-- Links: C-c C-l inserts or edits a link, C-c C-o follows one.
local api = vim.api

local function asked_summary(t)
  local out = {}
  for _, q in ipairs(t.asked()) do
    out[#out + 1] = { q.method, q.params.prompt, q.params.initial }
  end
  return out
end

local OTHER = "* Other\nfirst\n* Deep\ndeep body\n"
local MAIN = "* Main\n[[file:other.org]]\n[[file:other.org::*Deep]]\nsee  here\n"

return {
  ["C-c C-l inserts a link with a description"] = function(t)
    t.open("ins.org", "* H\nsee  here\n")
    t.cursor(2, 4)
    t.answer("https://example.com", "Example")
    t.keys("C-c C-l")
    t.eq(t.lines()[2], "see [[https://example.com][Example]] here")
    t.eq(asked_summary(t), { { "completing_read", "Link: " }, { "read_string", "Description: " } })
  end,

  ["C-c C-l offers earlier links as prompt history"] = function(t)
    t.open("hist.org", "* H\none \ntwo \n")
    t.cursor(2, 3)
    t.answer("https://first.example", "")
    t.keys("C-c C-l")
    t.cursor(3, 3)
    t.answer("https://second.example", "")
    t.keys("C-c C-l")
    local history = t.asked()[#t.asked() - 1].params.history
    t.eq(history[1], "https://first.example")
  end,

  ["C-c C-l with an empty description inserts a bare link"] = function(t)
    t.open("bare.org", "* H\nsee  here\n")
    t.cursor(2, 4)
    t.answer("https://example.com", "")
    t.keys("C-c C-l")
    t.eq(t.lines()[2], "see [[https://example.com]] here")
  end,

  ["C-c C-l on a link edits its target and description"] = function(t)
    t.open("edit.org", "* H\nsee [[https://a.com][A]] end\n")
    t.cursor(2, 8)
    t.answer("https://b.com", "B")
    t.keys("C-c C-l")
    t.eq(t.lines()[2], "see [[https://b.com][B]] end")
    t.eq(asked_summary(t),
      { { "read_string", "Link: ", "https://a.com" }, { "read_string", "Description: ", "A" } })
  end,

  ["C-u C-c C-l reads a file name and inserts a relative file link"] = function(t)
    local other = t.file("other.org", OTHER)
    t.open("main.org", MAIN)
    t.cursor(4, 4)
    t.answer(other, "")
    t.keys("C-c C-l", 4)
    t.eq(t.lines()[4], "see [[file:other.org]] here")
    local q = t.asked()[1]
    t.eq({ q.method, q.params.prompt, q.params.completion }, { "read_string", "File: ", "file" })
  end,

  ["C-c C-o on an internal heading link moves the cursor"] = function(t)
    t.open("internal.org", "* H\nsee [[*Target]] here\n* Other\n* Target\nbody\n")
    t.cursor(2, 8)
    t.keys("C-c C-o")
    t.eq(api.nvim_win_get_cursor(0)[1], 4)
  end,

  ["C-c C-l on a visual selection uses it as the description"] = function(t)
    t.open("region.org", "* H\nsee word here\n")
    t.cursor(2, 4)
    t.answer("C-l", "https://w.com", "word")
    api.nvim_feedkeys("v3l" .. api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    t.eq(t.lines()[2], "see [[https://w.com][word]] here")
    t.eq(t.asked()[3].params.initial, "word", "description defaults to the region")
  end,

  ["C-c C-l offers link types as completions"] = function(t)
    t.open("cands.org", "* H\n")
    t.cursor(1, 2)
    t.answer("https://x.com", "")
    t.keys("C-c C-l")
    local cands = t.asked()[1].params.candidates
    assert(vim.tbl_contains(cands, "file:") and vim.tbl_contains(cands, "https:"), vim.inspect(cands))
  end,

  ["C-c & after following an internal link returns to it"] = function(t)
    t.open("back.org", "* H\nsee [[*Target]] here\n* Other\n* Target\nbody\n")
    t.cursor(2, 8)
    t.keys("C-c C-o")
    t.keys("C-c &")
    t.eq(api.nvim_win_get_cursor(0), { 2, 8 })
  end,

  -- org-link-frame-setup opens files with find-file-other-window.
  ["C-c C-o on a file link opens the file in another window"] = function(t)
    local other = t.file("other.org", OTHER)
    local main = t.open("main.org", MAIN)
    local main_buf = api.nvim_get_current_buf()
    t.cursor(2, 4)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), other)
    t.eq(t.lines(), vim.split(OTHER, "\n", { plain = true, trimempty = true }))
    t.eq(api.nvim_win_get_cursor(0)[1], 1)
    t.eq(vim.bo.modified, false, "freshly opened file is unmodified")
    t.eq(#vim.fn.win_findbuf(main_buf), 1, main .. " still shown")
  end,

  ["C-c C-o on a file::*heading link moves to the heading"] = function(t)
    local other = t.file("other.org", OTHER)
    t.open("main.org", MAIN)
    t.cursor(3, 4)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), other)
    t.eq(api.nvim_win_get_cursor(0)[1], 3)
  end,

  ["completion uses Emacs's styles (partial completion)"] = function(t)
    t.open("pc.org", "* A\n")
    t.eval("(setq nvb--completion (cons '(\"projects.org/Alpha/Tasks\" \"projects.org/Beta\") nil))")
    t.eq(require("emacs.ui").complete("pro/A/T"), { "projects.org/Alpha/Tasks" })
    t.eval("(setq nvb--completion nil)")
  end,
}
