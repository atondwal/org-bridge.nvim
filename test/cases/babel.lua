-- Org babel: C-c C-c and the C-c C-v prefix on source blocks. Expected
-- values were produced with yes-or-no-p stubbed.
local api = vim.api

local ELISP = "* H\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n"
local TWO_BLOCKS = "* A\n#+begin_src emacs-lisp\n(* 6 7)\n#+end_src\n* B\n#+begin_src sh\necho two\n#+end_src\n"

local function ask(lang) return ("Evaluate this %s code block on your system? "):format(lang) end

local function load_shell(t)
  t.eval("(org-babel-do-load-languages 'org-babel-load-languages '((emacs-lisp . t) (shell . t)))")
end

local function prompts(t)
  local out = {}
  for _, q in ipairs(t.asked()) do out[#out + 1] = q.method .. ": " .. q.params.prompt end
  return out
end

return {
  ["C-c C-c asks, then inserts #+RESULTS: below the block"] = function(t)
    t.open("babel_el.org", ELISP)
    t.cursor(3)
    t.answer(true)
    t.keys("C-c C-c")
    t.eq(prompts(t), { "confirm: " .. ask("emacs-lisp") })
    t.eq(t.lines(), { "* H", "#+begin_src emacs-lisp", "(+ 1 2)", "#+end_src", "", "#+RESULTS:", ": 3" })
    t.eq(api.nvim_win_get_cursor(0), { 3, 0 }, "point stays in the block")
    t.eq(vim.bo.modified, true)
  end,

  ["answering no leaves the buffer alone"] = function(t)
    t.open("babel_no.org", ELISP)
    t.cursor(3)
    t.answer(false)
    t.keys("C-c C-c")
    t.eq(t.lines(), vim.split(ELISP, "\n", { trimempty = true }))
    t.eq(vim.bo.modified, false)
    assert(vim.fn.execute("messages"):find("Evaluation of this emacs-lisp code block is aborted.", 1, true),
      "abort message echoed")
  end,

  ["org-confirm-babel-evaluate nil runs without asking"] = function(t)
    t.open("babel_noconfirm.org", ELISP)
    t.cursor(3)
    t.set("org-confirm-babel-evaluate", "nil")
    t.keys("C-c C-c")
    t.eq(#t.asked(), 0)
    t.eq(t.lines()[7], ": 3")
  end,

  ["re-running replaces the old result, and C-c C-v k removes it"] = function(t)
    t.open("babel_rerun.org", ELISP .. "\n#+RESULTS:\n: 3\n")
    t.cursor(3)
    vim.cmd("normal! f1r2")
    t.eq(t.lines()[3], "(+ 2 2)")
    t.answer(true)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "* H", "#+begin_src emacs-lisp", "(+ 2 2)", "#+end_src", "", "#+RESULTS:", ": 4" })
    t.keys("C-c C-v k")
    t.eq(t.lines(), { "* H", "#+begin_src emacs-lisp", "(+ 2 2)", "#+end_src" }, "blank line removed too")
  end,

  ["a shell block runs once shell is loaded"] = function(t)
    load_shell(t)
    t.open("babel_sh.org", "#+begin_src sh\necho hi\n#+end_src\n")
    t.answer(true)
    t.keys("C-c C-c")
    t.eq(prompts(t), { "confirm: " .. ask("sh") })
    t.eq(t.lines(), { "#+begin_src sh", "echo hi", "#+end_src", "", "#+RESULTS:", ": hi" })
  end,

  ["a failing shell block shows *Org-Babel Error Output* in a split"] = function(t)
    load_shell(t)
    t.open("babel_sherr.org", "#+begin_src sh\necho out; echo oops >&2; exit 1\n#+end_src\n")
    local org = api.nvim_get_current_buf()
    t.answer(true)
    t.keys("C-c C-c")
    t.eq(api.nvim_get_current_buf(), org, "org buffer stays selected")
    t.eq(t.lines(org), { "#+begin_src sh", "echo out; echo oops >&2; exit 1", "#+end_src", "", "#+RESULTS:", ": out" })
    local names = {}
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      names[#names + 1] = vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(w)), ":t")
    end
    assert(vim.tbl_contains(names, "*Org-Babel Error Output*"), "error window: " .. vim.inspect(names))
  end,

  ["C-c C-v b executes every block, asking for each"] = function(t)
    load_shell(t)
    t.open("babel_buf.org", TWO_BLOCKS)
    t.answer(true, false)
    t.keys("C-c C-v b")
    t.eq(prompts(t), { "confirm: " .. ask("emacs-lisp"), "confirm: " .. ask("sh") })
    t.eq(t.lines(), { "* A", "#+begin_src emacs-lisp", "(* 6 7)", "#+end_src", "", "#+RESULTS:", ": 42", "",
      "* B", "#+begin_src sh", "echo two", "#+end_src" })
    t.eq(api.nvim_win_get_cursor(0), { 1, 0 })
  end,

  ["<C-c> typed in Neovim reads C-v b and runs the buffer"] = function(t)
    load_shell(t)
    t.open("babel_keymap.org", TWO_BLOCKS)
    t.answer("C-v", "b", true, true)
    api.nvim_feedkeys("\3", "x", false)
    t.eq(prompts(t), { "read_key: C-c-", "read_key: C-c C-v-", "confirm: " .. ask("emacs-lisp"),
      "confirm: " .. ask("sh") })
    t.eq(t.lines()[7], ": 42")
    t.eq(t.lines()[15], ": two")
  end,

  ["with use-short-answers the evaluation prompt takes y, as in Emacs"] = function(t)
    t.open("short.org", "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n")
    t.set("use-short-answers", "t")
    t.answer(true)
    t.keys("C-c C-c")
    t.eq(t.asked()[1].params.typed, false, "not typed yes/no")
    t.eq(t.lines()[6], ": 3")
  end,
}
