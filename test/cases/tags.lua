-- Tags: C-c C-q, C-c C-c on a heading, alignment, folds.

return {
  ["C-c C-q without a tag alist reads tags and aligns them"] = function(t)
    t.open("tags.org", "* Task\nbody\n")
    t.answer("work:home")
    t.keys("C-c C-q")
    t.eq(t.lines(), { t.aligned("* Task", ":work:home:"), "body" })
    local q = t.asked()[1]
    t.eq({ q.method, q.params.prompt }, { "read_string", "Tags: " })
  end,

  ["C-c C-q with #+TAGS fast keys toggles tags from a menu"] = function(t)
    t.open("fast.org", "#+TAGS: work(w) home(h)\n* Task\nbody\n")
    t.cursor(2)
    t.answer("w", "h", "RET")
    t.keys("C-c C-q")
    t.eq(t.lines()[2], t.aligned("* Task", ":work:home:"))
    local q = t.asked()[1]
    t.eq(q.method, "read_key")
    assert(q.params.context and q.params.context:find("work"), "menu shown: " .. vim.inspect(q))
  end,

  ["tags past the tags column get one space"] = function(t)
    local head = "* A much longer heading text that goes past the tags column here"
    t.open("long.org", head .. "\n")
    t.answer("x")
    t.keys("C-c C-q")
    t.eq(t.lines(), { t.aligned(head, ":x:") })
  end,

  ["a positive org-tags-column left-aligns tags"] = function(t)
    t.set("org-tags-column", "20")
    t.open("col.org", "* Task\n")
    t.answer("a")
    t.keys("C-c C-q")
    t.eq(t.lines(), { "* Task              :a:" })
  end,

  ["C-c C-c on a heading replaces its tags"] = function(t)
    t.open("ctrlc.org", "* Task :old:\nbody\n")
    t.answer("new")
    t.keys("C-c C-c")
    t.eq(t.lines(), { t.aligned("* Task", ":new:"), "body" })
    t.eq(t.asked()[1].params.initial, ":old:", "current tags offered")
  end,

  ["tagging a folded heading keeps it folded"] = function(t)
    t.open("fold.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" }, "folded")
    t.answer("work")
    t.keys("C-c C-q")
    t.eq(t.lines()[1], t.aligned("* A", ":work:"))
    t.eq(t.folds(), { "1-4" }, "still folded")
    t.eq(vim.fn.foldtextresult(1), t.aligned("* A", ":work:") .. "...", "fold text shows tags")
  end,

  ["tagging and clearing in overview keeps every fold"] = function(t)
    t.open("overview.org", t.DOC)
    t.keys("<backtab>")
    t.eq(t.folds(), { "1-4", "5-6" }, "overview")
    t.cursor(5)
    t.answer("x:y")
    t.keys("C-c C-q")
    t.eq(t.lines()[5], t.aligned("* B", ":x:y:"))
    t.eq(t.folds(), { "1-4", "5-6" }, "after tagging B")
    t.cursor(5)
    t.answer("")
    t.keys("C-c C-q")
    t.eq(t.lines()[5], "* B")
    t.eq(t.folds(), { "1-4", "5-6" }, "after clearing B")
  end,

  ["tags get the org-tag face"] = function(t)
    t.open("face.org", "* Task\n")
    t.answer("work")
    t.keys("C-c C-q")
    local line = t.lines()[1]
    local col = line:find(":work:", 1, true) - 1
    local ns = vim.api.nvim_create_namespace("emacs")
    local groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
      if m[2] == 0 and m[3] <= col + 1 and (m[4].end_col or 0) > col + 1 then
        groups[#groups + 1] = m[4].hl_group
      end
    end
    assert(vim.tbl_contains(groups, require("emacs.faces").group("org-tag")),
      "org-tag highlight on the tag: " .. vim.inspect(groups))
  end,

  ["the Tags: prompt completes against the buffer's tags"] = function(t)
    t.open("crm.org", "* A :work:\n* B\n")
    t.cursor(2)
    local seen
    local rpc = require("emacs.rpc")
    local scripted = rpc.handlers.read_string
    t.after(function() rpc.handlers.read_string = scripted end)
    rpc.handlers.read_string = function(p)
      seen = p.completion and require("emacs.ui").complete("wo")
      return "work"
    end
    t.keys("C-c C-q")
    t.eq(seen, { "work" })
  end,

  ["Escape in the fast tag menu leaves no overlay behind"] = function(t)
    t.open("fastq.org", "#+TAGS: work(w) home(h)\n* A\n")
    t.cursor(2)
    t.answer(t.QUIT)
    t.keys("C-c C-q")
    t.eq(t.eval([[(with-current-buffer "fastq.org"
      (length (seq-filter (lambda (o) (overlay-get o 'display)) (overlays-in (point-min) (point-max)))))]]), "0")
  end,
}
