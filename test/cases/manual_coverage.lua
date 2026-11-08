-- One test per Org manual feature no other case file reaches: comments,
-- cloning, citations, publishing, inline tasks, alphabetic lists, targets,
-- macros, completion, tags sparse trees, agenda sorting, clock report and
-- diary, table export. Expectations: emacs -Q --batch -l test/init.el
-- running the same keys (key-binding + command-execute, an undo boundary
-- per command, prompts answered as here).
local api = vim.api
local mirror = require("emacs.mirror")
local rpc = require("emacs.rpc")

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(vim.fn.bufnr(path)), (what or "") .. " Emacs agrees")
end

local function press(keys) api.nvim_feedkeys(keys, "x", false) end

local function today() return os.date("%Y-%m-%d %a") end

-- Opens the agenda dispatcher and picks key.
local function agenda(t, key)
  t.answer(key)
  t.command("org-agenda")
  assert(api.nvim_buf_get_name(0):find("Org Agenda", 1, true), "agenda shown: " .. api.nvim_buf_get_name(0))
end

local BIB = table.concat({
  "@book{knuth84,", "  author = {Donald Knuth},", "  title = {The TeXbook},", "  year = {1984}", "}",
  "@article{turing36,", "  author = {Alan Turing},", "  title = {On Computable Numbers},", "  year = {1936}", "}", "",
}, "\n")

return {
  -- Manual 2.10 Comment Lines.
  ["C-c ; toggles COMMENT after the TODO keyword and back"] = function(t)
    local path = t.open("mc_comment.org", "* TODO A\nbody\n* B\n")
    t.keys("C-c ;")
    t.eq(t.lines()[1], "* TODO COMMENT A")
    t.cursor(3)
    t.keys("C-c ;")
    t.cursor(1)
    t.keys("C-c ;")
    t.eq(t.lines(), { "* TODO A", "body", "* COMMENT B" })
    agree(t, path)
  end,

  -- Manual 2.9 Structure Editing.
  ["C-c C-x c clones the subtree with a shifted timestamp"] = function(t)
    local path = t.open("mc_clone.org", "* Meet\n<2026-11-09 Mon>\n* Other\n")
    t.answer("2", "+1w")
    t.keys("C-c C-x c")
    t.eq(t.lines(), { "* Meet", "<2026-11-09 Mon>", "* Meet", "<2026-11-16 Mon>", "* Meet", "<2026-11-23 Mon>",
      "* Other" })
    t.eq(t.asked()[1].params.prompt, "Number of clones to produce: ")
    agree(t, path)
  end,

  -- Manual 15 Citation Handling. oc-basic offers "Author  Year  Title"
  -- strings; empty input ends the key loop.
  ["C-c C-x @ inserts a citation picked from the global bibliography"] = function(t)
    t.set("org-cite-global-bibliography", ("(list %q)"):format(t.file("mc_refs.bib", BIB)))
    local path = t.open("mc_cite.org", "See  here.\n")
    t.cursor(1, 4)
    local prompts = {}
    rpc.handlers.completing_read = function(p)
      prompts[#prompts + 1] = p.prompt
      if #prompts > 1 then return "" end
      for _, c in ipairs(p.candidates or {}) do
        if c:find("^Donald Knuth") then return c end
      end
      error("no Knuth candidate: " .. vim.inspect(p.candidates))
    end
    t.keys("C-c C-x @")
    t.eq(prompts, { "Key (empty input exits): ", "Key (empty input exits) knuth84: " })
    t.eq(t.lines(), { "See [cite:@knuth84] here." })
    t.eq(api.nvim_win_get_cursor(0), { 1, 19 }, "point after the citation, as in Emacs")
    agree(t, path)
  end,

  -- Manual 13.17 Publishing; the timestamp cache goes under the test dir.
  ["C-c C-e P f publishes the file into the project's directory"] = function(t)
    local base, out = t.WORK .. "/mc_pub", t.WORK .. "/mc_pubout"
    vim.fn.mkdir(base, "p")
    vim.fn.delete(out, "rf")
    t.eval("(require 'ox-publish)")
    t.set("org-publish-timestamp-directory", ("%q"):format(t.WORK .. "/mc_ts/"))
    t.set("org-publish-project-alist", ([['(("probe" :base-directory %q :publishing-directory %q
      :publishing-function org-ascii-publish-to-ascii :with-toc nil :section-numbers nil
      :with-author nil :with-date nil :with-title nil))]]):format(base, out))
    local path = t.open("mc_pub/page.org", "* Hello\nPublished text.\n")
    t.answer("P", "f")
    t.keys("C-c C-e")
    t.eq(t.read_file(out .. "/page.txt"), "Hello\n=====\n\n  Published text.\n")
    agree(t, path)
  end,

  -- Manual A.7 Inline tasks (org-inlinetask-min-level 15).
  ["C-c C-x t inserts an inline task above the body line"] = function(t)
    t.eval("(require 'org-inlinetask)")
    t.after(function()
      t.eval([[(progn (define-key org-mode-map (kbd "C-c C-x t") nil) (unload-feature 'org-inlinetask t))]])
    end)
    local path = t.open("mc_inline.org", "* H\nbody\n")
    t.cursor(2)
    t.keys("C-c C-x t")
    t.eq(t.lines(), { "* H", "*************** ", "*************** END", "body" })
    t.eq(api.nvim_win_get_cursor(0)[1], 2, "cursor on the task heading")
    agree(t, path)
  end,

  -- Manual 2.6 Plain Lists, with org-list-allow-alphabetical set before
  -- the file opens (its :set rebuilds the item regexps).
  ["alphabetic bullets: M-RET continues and renumbers, C-c - cycles to A."] = function(t)
    t.eval("(customize-set-variable 'org-list-allow-alphabetical t)")
    t.after(function() t.eval("(customize-set-variable 'org-list-allow-alphabetical nil)") end)
    local path = t.open("mc_alpha.org", "a. one\nb. two\n")
    t.cursor(1, 5)
    press(api.nvim_replace_termcodes("<M-CR>new<Esc>", true, false, true))
    t.eq(t.lines(), { "a. one", "b. new", "c. two" }, "M-RET")
    t.cursor(1)
    t.keys("C-c -")
    t.eq(t.lines(), { "A. one", "B. new", "C. two" }, "C-c -")
    agree(t, path)
  end,

  -- Manual 4.3 Internal Links and 4.4 Radio Targets.
  ["C-c C-o on radio text and on a [[target]] link jumps to the target"] = function(t)
    local path = t.open("mc_radio.org",
      "* H\n<<<Tokyo>>> is a city.\n* Notes\nI visit Tokyo often.\nsee [[dest]]\n* Far\n<<dest>> here\n")
    t.cursor(4, 9)
    t.keys("C-c C-o")
    t.eq(api.nvim_win_get_cursor(0), { 2, 0 }, "radio link")
    t.cursor(5, 6)
    t.keys("C-c C-o")
    t.eq(api.nvim_win_get_cursor(0), { 7, 0 }, "dedicated target")
    agree(t, path)
  end,

  -- Manual 13.5 Macro Replacement.
  ["{{{macros}}} expand on ASCII export"] = function(t)
    vim.fn.delete(t.WORK .. "/mc_macro.txt")
    local path = t.open("mc_macro.org", table.concat({
      "#+TITLE: Probe", "#+DATE: 2026-01-02", "#+MACRO: greet Hello, $1!",
      "#+OPTIONS: toc:nil num:nil title:nil author:nil date:nil",
      "{{{greet(World)}}} on {{{date}}} in {{{title}}}.", "",
    }, "\n"))
    t.answer("t", "a")
    t.keys("C-c C-e")
    t.eq(t.read_file(t.WORK .. "/mc_macro.txt"), "Hello, World! on 2026-01-02 in Probe.\n")
    agree(t, path)
  end,

  -- Manual 16.2 Completion. Normal mode can't put point at the end of a
  -- line, so this is an Insert-mode mapping a user would write for M-TAB.
  ["M-Tab in Insert mode completes #+ keywords and \\ entities"] = function(t)
    local path = t.open("mc_capf.org", "#+TIT\nA \\alp\n")
    t.cursor(1)
    t.feed("A<M-Tab><Esc>")
    t.cursor(2)
    t.feed("A<M-Tab><Esc>")
    t.eq(t.lines(), { "#+TITLE: ", "A \\alpha" })
    agree(t, path)
  end,

  -- Manual 2.7 Sparse Trees with 6.3 Tag Searches: B stays for its child.
  ["C-c / m shows only headings matching a tag query"] = function(t)
    local path = t.open("mc_sparse.org", "* A :work:\nbody a\n* B :home:\nbody b\n** B1 :work:\nbody b1\n* C\n")
    t.answer("m", "work")
    t.keys("C-c /")
    t.eq({ t.asked()[2].method, t.asked()[2].params.prompt }, { "completing_read", "Match: " })
    t.eq(t.folds(), { "1-2", "3-4", "5-6" })
    agree(t, path)
  end,

  -- Manual 5.4 Priorities, 11.4.3 Sorting: no cookie counts as [#B] and
  -- keeps file order among the B's.
  ["the TODO list sorts by priority cookie"] = function(t)
    local path = t.open("mc_prio.org", "* TODO [#C] Low\n* TODO Plain\n* TODO [#A] High\n* TODO [#B] Mid\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    agenda(t, "t")
    local items = {}
    for _, l in ipairs(t.lines()) do
      if l:find("^  mc_prio:") then items[#items + 1] = l end
    end
    t.eq(items, { "  mc_prio:    TODO [#A] High", "  mc_prio:    TODO Plain", "  mc_prio:    TODO [#B] Mid",
      "  mc_prio:    TODO [#C] Low" })
    agree(t, path)
  end,

  -- Manual 11.5.2 Agenda Commands: R toggles the clocktable under the day.
  ["R in the day agenda adds and removes the clock report"] = function(t)
    local d = today()
    local path = t.open("mc_clocked.org",
      ("* TODO Work\n:LOGBOOK:\nCLOCK: [%s 09:00]--[%s 10:30] =>  1:30\n:END:\n* TODO Rest\n"):format(d, d))
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.set("org-agenda-span", "'day")
    agenda(t, "a")
    t.eq(#t.lines(), 2, "day with nothing scheduled")
    press("R")
    t.eq({ unpack(t.lines(), 3) }, {
      "| File           | Headline         | Time   |",
      "|----------------+------------------+--------|",
      "|                | ALL *Total time* | *1:30* |",
      "|----------------+------------------+--------|",
      "| mc_clocked.org | *File time*      | *1:30* |",
      "|                | [[file:" .. path .. "::*Work][Work]]             | 1:30   |",
    })
    press("R")
    t.eq(#t.lines(), 2, "R again removes it")
    agree(t, path)
  end,

  -- Manual 11.3.1 Calendar/Diary Integration.
  ["org-agenda-include-diary shows diary entries in the day agenda"] = function(t)
    local path = t.open("mc_diary_tasks.org", "* TODO Nothing scheduled\n")
    local diary = t.file("mc_diary", os.date("%b ") .. tonumber(os.date("%d")) .. os.date(", %Y") .. " Dentist\n")
    t.set("org-agenda-files", ("(list %q)"):format(path))
    t.set("org-agenda-span", "'day")
    t.set("diary-file", ("%q"):format(diary))
    t.set("org-agenda-include-diary", "t")
    agenda(t, "a")
    t.eq({ unpack(t.lines(), 3) }, { "  Diary:      Dentist" })
    agree(t, path)
  end,

  -- Manual 3.6 Org Plot / 3.x table export (org-table-export).
  ["org-table-export writes the table as CSV"] = function(t)
    local out = t.WORK .. "/mc_tbl.csv"
    vim.fn.delete(out)
    local path = t.open("mc_tbl.org", "| name | n |\n|------+---|\n| a    | 1 |\n| b    | 2 |\n")
    t.cursor(3, 2)
    t.answer(out, "orgtbl-to-csv")
    t.command("org-table-export")
    t.eq(t.read_file(out), "name,n\na,1\nb,2\n")
    agree(t, path)
  end,
}
