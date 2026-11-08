-- Babel beyond basics: :results types and handlers, :var, noweb, #+call:,
-- sessions, tangling, and the C-c C-v keys. Expected text comes from
-- emacs -Q --batch -l test/init.el with yes-or-no-p stubbed to yes.
local api = vim.api

local function load_shell(t)
  t.eval("(org-babel-do-load-languages 'org-babel-load-languages '((emacs-lisp . t) (shell . t)))")
end

-- Open content with the cursor at line/col, answer yes to the one
-- confirmation, run keys.
local function run(t, name, content, line, keys, col)
  t.open(name, content)
  t.cursor(line, col)
  local before = #t.asked()
  t.answer(true)
  t.keys(keys or "C-c C-c")
  t.eq(#t.asked() - before, 1, "asked once")
end

local function src(header, body) return ("#+begin_src %s\n%s\n#+end_src\n"):format(header, body) end

local function split(s) return vim.split(s, "\n", { plain = true, trimempty = true }) end

local function cursor() return api.nvim_win_get_cursor(0) end

-- Lines of every window whose buffer name contains name.
local function shown(name)
  local out = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_name(buf):find(name, 1, true) then out[#out + 1] = api.nvim_buf_get_lines(buf, 0, -1, false) end
  end
  return out
end

local TABLE = "#+name: tbl\n| a | 1 |\n| b | 2 |\n\n"

return {
  [":results table, list, raw, drawer, file and silent format the value"] = function(t)
    run(t, "table.org", src("emacs-lisp :results value table", "'((1 2) (3 4))"), 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", "| 1 | 2 |", "| 3 | 4 |" }, "table")
    run(t, "list.org", src("emacs-lisp :results list", "'(\"x\" \"y\")"), 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", "- x", "- y" }, "list")
    run(t, "raw.org", src("emacs-lisp :results raw", "\"*bold* text\""), 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", "*bold* text" }, "raw")
    run(t, "drawer.org", src("emacs-lisp :results drawer", "\"in drawer\""), 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", ":results:", "in drawer", ":end:" }, "drawer")
    local out = t.WORK .. "/out.txt"
    os.remove(out)
    run(t, "file.org", src("emacs-lisp :results file :file " .. out, "\"content\""), 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", "[[file:" .. out .. "]]" }, "file")
    t.eq(t.read_file(out), "content", "file written")
    local silent = src("emacs-lisp :results silent", "(+ 40 2)")
    run(t, "silent.org", silent, 2)
    t.eq(t.lines(), split(silent), "silent")
    t.eq(vim.bo.modified, false, "silent leaves the buffer unmodified")
    assert(vim.fn.execute("messages"):find('"42"', 1, true), "silent echoes the value")
  end,

  [":results output keeps each line, and output table makes a table"] = function(t)
    load_shell(t)
    run(t, "out.org", src("sh :results output", "echo a\necho 'naïve café ☕'"), 2)
    t.eq({ unpack(t.lines(), 6) }, { "#+RESULTS:", ": a", ": naïve café ☕" }, "output")
    run(t, "outtbl.org", src("sh :results output table", "printf 'a b\\nc d\\n'"), 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", "| a | b |", "| c | d |" }, "output table")
  end,

  [":results append, prepend and replace treat the old result differently"] = function(t)
    load_shell(t)
    t.open("append.org", src("sh :results output append", "echo x"))
    t.cursor(2)
    t.answer(true, true)
    t.keys("C-c C-c")
    t.keys("C-c C-c")
    t.eq({ unpack(t.lines(), 4) }, { "", "#+RESULTS:", ": x", ": x" }, "append")
    run(t, "prepend.org", src("sh :results output prepend", "echo x") .. "\n#+RESULTS:\n: old\n", 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", ": x", ": old" }, "prepend")
    run(t, "replace.org", src("emacs-lisp :results replace", "(+ 1 1)") .. "\n#+RESULTS:\n: 99\n", 2)
    t.eq({ unpack(t.lines(), 5) }, { "#+RESULTS:", ": 2" }, "replace")
  end,

  [":var reads a named table, and :noweb yes expands a named block"] = function(t)
    run(t, "var.org", TABLE .. src("emacs-lisp :var data=tbl", "(apply #'+ (mapcar #'cadr data))"), 6)
    t.eq({ unpack(t.lines(), 9) }, { "#+RESULTS:", ": 3" }, "sum")
    run(t, "vartbl.org",
      TABLE .. src("emacs-lisp :var data=tbl", "(mapcar (lambda (r) (list (car r) (* 10 (cadr r)))) data)"), 6)
    t.eq({ unpack(t.lines(), 9) }, { "#+RESULTS:", "| a | 10 |", "| b | 20 |" }, "list of lists is a table")
    load_shell(t)
    run(t, "noweb.org", "#+name: greet\n" .. src("sh", "echo hello") .. "\n"
      .. src("sh :noweb yes :results output", "<<greet>>\necho world"), 7)
    t.eq({ unpack(t.lines(), 11) }, { "#+RESULTS:", ": hello", ": world" }, "noweb")
  end,

  ["#+call: and inline src_ blocks run with C-c C-c"] = function(t)
    run(t, "call.org", "#+name: dbl\n" .. src("emacs-lisp :var x=1", "(* 2 x)") .. "\n#+call: dbl(x=21)\n", 6)
    t.eq({ unpack(t.lines(), 6) }, { "#+call: dbl(x=21)", "", "#+RESULTS:", ": 42" }, "call")
    run(t, "inline.org", "Value src_emacs-lisp{(+ 1 2)} here\n", 1, "C-c C-c", 8)
    t.eq(t.lines(), { "Value src_emacs-lisp{(+ 1 2)} {{{results(=3=)}}} here" }, "inline")
  end,

  ["a :session shell block keeps its variables for the next block"] = function(t)
    load_shell(t)
    t.after(function()
      t.eval("(let ((b (get-buffer \"s1\")) (kill-buffer-query-functions nil)) (when b (kill-buffer b)))")
    end)
    run(t, "sess.org", src("sh :session s1 :results output", "X=5\necho $((X*2))") .. src("sh :session s1", "echo $X"), 2)
    t.eq({ unpack(t.lines(), 5, 8) }, { "", "#+RESULTS:", ": 10", "" }, "first")
    t.cursor(9)
    t.answer(true)
    t.keys("C-c C-c")
    t.eq({ unpack(t.lines(), 12) }, { "", "#+RESULTS:", ": 5" }, "second")
  end,

  ["C-c C-v t tangles with noweb to the :tangle path, C-u just one block"] = function(t)
    local out = t.WORK .. "/tangled.sh"
    os.remove(out)
    local content = "* A\n#+name: lib\n" .. src("sh", "echo lib")
      .. src("sh :tangle " .. out .. " :noweb yes", "<<lib>>\necho main")
    t.open("tangle.org", content)
    t.keys("C-c C-v t")
    t.eq(#t.asked(), 0)
    t.eq(t.read_file(out), "echo lib\necho main\n")
    t.eq(t.lines(), split(content), "org text unchanged")
    assert(vim.fn.execute("messages"):find("Tangled 1 code block from tangle.org", 1, true), "tangle message")
    local one, two = t.WORK .. "/one.sh", t.WORK .. "/two.sh"
    os.remove(one)
    os.remove(two)
    t.open("tangle1.org", src("sh :tangle " .. one, "echo one") .. src("sh :tangle " .. two, "echo two"))
    t.cursor(5)
    t.keys("C-c C-v t", 4)
    t.eq({ vim.fn.filereadable(one) == 1, t.read_file(two) }, { false, "echo two\n" }, "C-u tangles only this block")
  end,

  ["C-c C-v n, p, g and b leave point where Emacs does"] = function(t)
    t.open("nav.org", "* A\n#+name: first\n" .. src("emacs-lisp", "1") .. "text\n#+name: second\n" .. src("emacs-lisp", "2"))
    t.keys("C-c C-v n")
    t.eq(cursor(), { 3, 0 }, "first n")
    t.keys("C-c C-v n")
    t.eq(cursor(), { 8, 0 }, "second n")
    t.keys("C-c C-v p")
    t.eq(cursor(), { 3, 0 }, "p")
    t.answer("second")
    t.keys("C-c C-v g")
    t.eq(t.asked()[1].params.prompt, "source-block name: ")
    t.eq(cursor(), { 8, 0 }, "g")
    -- org-babel-execute-buffer restores point as a number, so the results
    -- it inserts above leave point 14 characters earlier in the text.
    t.open("bufpoint.org", src("emacs-lisp", "1") .. "text\n" .. src("emacs-lisp", "2"))
    t.cursor(6)
    t.answer(true, true)
    t.keys("C-c C-v b")
    t.eq(#t.lines(), 14)
    t.eq(cursor(), { 9, 6 }, "b")
  end,

  ["C-c C-v e runs the block, k removes its result, d splits it"] = function(t)
    local block = src("emacs-lisp :results drawer", "\"d\"")
    run(t, "kill.org", block .. "\n#+RESULTS:\n:results:\nold\n:end:\n\ntrailing\n", 2, "C-c C-v e")
    t.eq({ unpack(t.lines(), 4) }, { "", "#+RESULTS:", ":results:", "d", ":end:", "", "trailing" }, "e")
    t.keys("C-c C-v k")
    t.eq(t.lines(), { "#+begin_src emacs-lisp :results drawer", "\"d\"", "#+end_src", "", "trailing" }, "k")
    t.open("demarc.org", src("emacs-lisp", "(a)\n(b)"))
    t.cursor(3)
    t.keys("C-c C-v d")
    t.eq(t.lines(), { "#+begin_src emacs-lisp", "(a)", "#+end_src", "", "#+begin_src emacs-lisp", "(b)", "#+end_src" })
    t.eq(cursor(), { 4, 0 }, "d")
  end,

  ["C-c C-v v previews the expanded body, C-c C-v I shows header args"] = function(t)
    load_shell(t)
    t.open("view.org", src("sh :var n=3", "echo $n"))
    t.cursor(2)
    t.keys("C-c C-v v")
    t.eq(shown("Org-Babel Preview"), { { "n='3'", "echo $n" } }, "preview")
    t.open("info.org", src("emacs-lisp :results silent", "1"))
    t.cursor(2)
    t.keys("C-c C-v I")
    t.eq(shown("*Help*"), { { "Lang: emacs-lisp", "Properties:", "\t:header-args \tnil",
      "\t:header-args:emacs-lisp \tnil", "Header Arguments:", "\t:cache\t\tno", "\t:exports\tcode",
      "\t:hlines\t\tno", "\t:lexical\tno", "\t:noweb\t\tno", "\t:results\tsilent", "\t:session\tnone",
      "\t:tangle\t\tno" } }, "info")
  end,

  ["org-confirm-babel-evaluate as a function asks only when it returns t"] = function(t)
    load_shell(t)
    t.set("org-confirm-babel-evaluate", "(lambda (lang _body) (string= lang \"sh\"))")
    t.open("confirmfn.org", src("emacs-lisp", "(+ 1 1)") .. src("sh", "echo s"))
    t.cursor(2)
    t.keys("C-c C-c")
    t.eq(#t.asked(), 0, "elisp not asked")
    t.eq(t.lines()[6], ": 2")
    t.cursor(8)
    t.answer(true)
    t.keys("C-c C-c")
    t.eq(#t.asked(), 1, "sh asked")
    t.eq({ unpack(t.lines(), 8) }, { "#+begin_src sh", "echo s", "#+end_src", "", "#+RESULTS:", ": s" })
  end,

  ["TAB on #+RESULTS: hides the result, TAB on #+begin_src folds the block"] = function(t)
    t.open("hide.org", "* H\n" .. src("emacs-lisp", "(list 1 2 3)") .. "\n#+RESULTS:\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\nafter\n")
    t.cursor(6)
    t.keys("TAB")
    t.eq(t.folds(), { "6-8" }, "results")
    t.open("hideblk.org", "* H\n" .. src("emacs-lisp", "(list 1 2 3)\n(x)") .. "after\n")
    t.cursor(2)
    t.keys("TAB")
    t.eq(t.folds(), { "2-5" }, "block")
  end,
}
