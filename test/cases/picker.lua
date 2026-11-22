-- completing_read through a picker (fzf in a real UI). fzf.vim isn't
-- loaded headless, so these stub ui.picker and check what it is given.
local rpc = require("emacs.rpc")
local ui = require("emacs.ui")

-- Route completing_read to ui's handler with `pick` as the picker; the
-- specs it was called with are returned.
local function use_picker(t, pick)
  local specs = {}
  rpc.handlers.completing_read = ui.completing_read
  rpc.handlers.read_string = ui.read_string
  ui.picker = function(spec)
    specs[#specs + 1] = spec
    return pick(spec)
  end
  t.after(function() ui.picker = nil end)
  return specs
end

return {
  ["M-x sends each command's key binding in the org buffer"] = function(t)
    t.open("mx.org", "* A\n")
    t.answer("org-toggle-comment")
    t.keys("M-x")
    local q = t.asked()[1].params
    t.eq(q.dynamic, false)
    local binding = {}
    for i, c in ipairs(q.candidates) do binding[c] = q.bindings[i] end
    -- Org's keys, not the minibuffer's or only the global map's.
    t.eq({ binding["org-time-stamp-inactive"], binding["org-toggle-comment"], binding["org-agenda-list"] },
      { "C-c !", "C-c ;", "" })
    t.eq(t.lines(), { "* COMMENT A" })
  end,

  ["the picker gets history first and its answer runs; nil quits"] = function(t)
    t.open("mxpick.org", "* A\n")
    t.set("extended-command-history", "nil")
    local answer = "org-toggle-comment"
    local specs = use_picker(t, function() return answer end)
    t.keys("M-x")
    t.eq(t.lines(), { "* COMMENT A" })
    t.eq(specs[1].bindings["org-toggle-comment"], "C-c ;")
    t.keys("M-x")
    t.eq(specs[2].items[1], "org-toggle-comment", "the last command first")
    t.eq(t.lines(), { "* A" })
    answer = nil
    t.keys("M-x")
    t.eq(t.lines(), { "* A" }, "cancelled: the third M-x ran nothing")
  end,

  -- Without fast tag selection, org reads tags with completing-read-multiple.
  ["org tags: the heading's tags start ticked; the ticked ones are set"] = function(t)
    t.open("tags.org", "* A :work:\n")
    t.eval([[(setq org-tag-alist '(("home") ("urgent") ("work")) org-use-fast-tag-selection nil)]])
    local picked = { "work", "urgent" }
    local specs = use_picker(t, function() return picked end)
    t.keys("C-c C-q")
    t.eq({ specs[1].multi, specs[1].selected, specs[1].items[1] }, { true, 1, "work" })
    t.eq(t.lines(), { t.aligned("* A", ":work:urgent:") })
    picked = nil
    t.keys("C-c C-q")
    t.eq(t.lines(), { t.aligned("* A", ":work:urgent:") }, "cancelled: tags unchanged")
  end,

  ["outline paths completed in steps skip the picker for Tab completion"] = function(t)
    t.open("steps.org", t.DOC)
    t.eval([[(setq org-refile-targets '((nil :maxlevel . 2)) org-refile-history nil)]])
    t.set("org-refile-use-outline-path", "t")
    t.set("org-outline-path-complete-in-steps", "t")
    t.answer("B/")
    t.keys("C-c C-w")
    t.eq(t.asked()[1].params.dynamic, true)
    t.eq(t.lines(), { "* B", "body b", "** A", "body a", "*** A1", "text" })

    use_picker(t, function() error("picker used for a dynamic table") end)
    t.feed(":lua _G.answer = require('emacs.ui').completing_read("
      .. "{ prompt = 'P: ', candidates = { 'B/' }, dynamic = true })<CR>B/<CR>")
    t.eq(_G.answer, "B/")
    _G.answer = nil
  end,
}
