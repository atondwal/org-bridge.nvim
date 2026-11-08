-- The C-c C-v babel keys beyond running a block: tangle, expand, block
-- navigation, demarcate, describe bindings, insert header arg, check, and
-- the results commands. Expected values come from emacs -Q --batch -l
-- test/init.el with the commands run through command-execute.
local api = vim.api

local function src(header, body) return ("#+begin_src %s\n%s\n#+end_src\n"):format(header, body) end

local function cursor() return api.nvim_win_get_cursor(0) end

local function messages() return vim.fn.execute("messages") end

-- Lines of every window whose buffer name contains name.
local function shown(name)
  local out = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_name(buf):find(name, 1, true) then out[#out + 1] = api.nvim_buf_get_lines(buf, 0, -1, false) end
  end
  return out
end

local function current_name() return vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t") end

local NAV = "* A\n#+name: first\n" .. src("emacs-lisp", "1") .. "text\n#+name: second\n" .. src("emacs-lisp", "2")
  .. src("sh", "3")

local NAMED_RESULTS = "* A\n#+name: one\n" .. src("emacs-lisp", "1") .. "\n#+RESULTS: one\n: 1\n"
  .. "* B\n#+name: two\n" .. src("emacs-lisp", "2") .. "\n#+RESULTS: two\n: 2\n"

return {
  ["C-c C-v t joins blocks into one file, skips :tangle no, applies :shebang"] = function(t)
    local out = t.WORK .. "/joined.sh"
    os.remove(out)
    t.open("tangle_join.org", "* A\n" .. src(("sh :tangle %s :shebang \"#!/bin/sh\""):format(out), "echo one")
      .. src("sh :tangle no", "echo skip") .. src("sh :tangle " .. out, "echo two"))
    vim.cmd("messages clear")
    t.keys("C-c C-v t")
    t.eq(t.read_file(out), "#!/bin/sh\necho one\n\necho two\n")
    t.eq(vim.fn.getfperm(out):sub(3, 3), "x", ":shebang makes the file executable")
    assert(messages():find("Tangled 2 code blocks from tangle_join.org", 1, true), "message: " .. messages())
  end,

  ["C-c C-v v shows the noweb- and :var-expanded body in a selected preview"] = function(t)
    t.open("expand.org", "#+name: lib\n" .. src("emacs-lisp", "(setq y 1)")
      .. src("emacs-lisp :var x=2 :noweb yes", "<<lib>>\n(+ x y)"))
    t.cursor(6)
    t.keys("C-c C-v v")
    t.eq(shown("Org-Babel Preview"), { { "(let ((x '2))", "(setq y 1)", "(+ x y)", ")" } })
    t.eq(current_name(), "*Org-Babel Preview expand.org[ emacs-lisp ]*", "preview window selected")
  end,

  ["C-c C-v n and p take a count"] = function(t)
    t.open("nav_count.org", NAV)
    t.keys("C-c C-v n", 2)
    t.eq(cursor(), { 8, 0 }, "2 n")
    t.cursor(12)
    t.keys("C-c C-v p", 2)
    t.eq(cursor(), { 3, 0 }, "2 p")
  end,

  ["C-c C-v n past the last block and p before the first say so"] = function(t)
    t.open("nav_edge.org", NAV)
    t.cursor(12)
    vim.cmd("messages clear")
    t.keys("C-c C-v n")
    t.eq(cursor(), { 12, 0 }, "n stays")
    assert(messages():find("No further code blocks", 1, true), "n message: " .. messages())
    t.cursor(4)
    t.keys("C-c C-v p")
    t.eq(cursor(), { 4, 0 }, "p stays")
    assert(messages():find("No previous code blocks", 1, true), "p message: " .. messages())
  end,

  ["C-c C-v g offers the block names and jumps backwards to one"] = function(t)
    t.open("goto_named.org", NAV)
    t.cursor(12)
    t.answer("first")
    t.keys("C-c C-v g")
    local q = t.asked()[1]
    t.eq({ q.method, q.params.prompt, q.params.candidates, q.params.require_match },
      { "completing_read", "source-block name: ", { "second", "first" }, true })
    t.eq(cursor(), { 3, 0 })
  end,

  ["C-c C-v d mid-line splits there, keeping the column as indentation"] = function(t)
    t.open("demarc_mid.org", src("emacs-lisp :results silent", "(a) (b)"))
    t.cursor(2, 4)
    t.keys("C-c C-v d")
    t.eq(t.lines(), { "#+begin_src emacs-lisp :results silent", "(a) ", "#+end_src", "",
      "#+begin_src emacs-lisp :results silent", "    (b)", "#+end_src" })
    -- Emacs's point is after "#+end_src"; Normal mode shows the last char.
    t.eq({ cursor(), t.eval("(current-column)") }, { { 3, 8 }, "9" })
  end,

  ["C-c C-v d outside a block asks the language and inserts an empty block"] = function(t)
    t.open("demarc_new.org", "* H\nplain text\n")
    t.cursor(2)
    t.answer("sh")
    t.keys("C-c C-v d")
    t.eq(t.asked()[1].params.prompt, "Lang: ")
    t.eq(t.lines(), { "* H", "#+begin_src sh", "#+end_src", "plain text" })
    t.eq({ cursor(), t.eval("(current-column)") }, { { 2, 13 }, "14" }, "point at end of the begin line")
  end,

  ["C-c C-v h lists the C-c C-v bindings in *Help*"] = function(t)
    t.open("describe.org", "* H\n")
    t.keys("C-c C-v h")
    t.eq(current_name(), "describe.org", "org window stays selected")
    local help = shown("*Help*")
    t.eq(#help, 1, "one *Help* window")
    t.eq({ unpack(help[1], 1, 7) }, { "\f", "  `org-mode' Major Mode Bindings Starting With C-c C-v:", "",
      "Key             Binding", string.rep("-", 79), "C-c C-v C-a\torg-babel-sha1-hash",
      "C-c C-v C-b\torg-babel-execute-buffer" })
  end,

  ["C-c C-v j asks a header arg and its value, appends both to the header"] = function(t)
    t.open("header_arg.org", src("emacs-lisp", "1"))
    t.cursor(2)
    t.answer("cache", "yes")
    t.keys("C-c C-v j")
    local q = t.asked()
    t.eq({ q[1].params.prompt, q[2].params.prompt, q[2].params.candidates },
      { "Header Arg: ", "Value: ", { "default", "no", "yes" } })
    t.eq(t.lines(), { "#+begin_src emacs-lisp :cache yes ", "1", "#+end_src" })
    t.eq(cursor(), { 2, 0 })
  end,

  ["C-c C-v c flags a misspelt header arg and passes a clean one"] = function(t)
    t.open("check_bad.org", src("emacs-lisp :result silent", "1"))
    t.cursor(2)
    vim.cmd("messages clear")
    t.keys("C-c C-v c")
    assert(messages():find([[Supplied header ""result"" is suspiciously close to ""results""]], 1, true),
      "misspelt: " .. messages())
    t.open("check_ok.org", src("emacs-lisp :results silent", "1"))
    t.cursor(2)
    vim.cmd("messages clear")
    t.keys("C-c C-v c")
    assert(messages():find("No suspicious header arguments found.", 1, true), "clean: " .. messages())
  end,

  ["C-c C-v o shows a table result as TSV in *Org Babel Results*"] = function(t)
    t.open("open_result.org", src("emacs-lisp", "(list (list 1 2) (list 3 4))") .. "\n#+RESULTS:\n| 1 | 2 |\n| 3 | 4 |\n")
    t.cursor(2)
    t.keys("C-c C-v o")
    t.eq(current_name(), "*Org Babel Results*", "results window selected")
    t.eq(t.lines(), { "1\t2", "3\t4" })
    t.eq(#t.asked(), 0, "existing result, no evaluation")
  end,

  ["C-c C-v o on a file-link result visits the file"] = function(t)
    t.file("result.txt", "hello\n")
    t.open("open_file.org", src("emacs-lisp", "1") .. "\n#+RESULTS:\n[[file:result.txt]]\n")
    t.cursor(2)
    t.keys("C-c C-v o")
    t.eq({ current_name(), t.lines() }, { "result.txt", { "hello" } })
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "in another window")
  end,

  ["C-c C-v r offers the result names and jumps to one"] = function(t)
    t.open("goto_result.org", NAMED_RESULTS)
    t.answer("two")
    t.keys("C-c C-v r")
    local q = t.asked()[1]
    t.eq({ q.params.prompt, q.params.candidates, q.params.require_match },
      { "Source-block name: ", { "two", "one" }, true })
    t.eq(cursor(), { 15, 0 })
  end,

  ["C-c C-v r reveals a result inside a folded subtree"] = function(t)
    t.open("goto_result_fold.org", NAMED_RESULTS)
    t.keys("S-TAB")
    t.eq(t.folds(), { "1-8", "9-16" }, "overview")
    t.answer("two")
    t.keys("C-c C-v r")
    t.eq(cursor(), { 15, 0 })
    t.eq(t.folds(), { "1-8" }, "B unfolded")
  end,
}
