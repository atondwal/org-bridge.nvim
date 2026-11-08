-- Other plugins in the same Neovim: global <Tab>/<C-c> maps, an autopair
-- InsertCharPre, FileType option and treesitter autocmds, a statusline,
-- 'paste', and a whitespace-stripping BufWritePre. Expected text: emacs -Q
-- --batch -l test/init.el (electric-pair-local-mode for the autopair cases).
local api = vim.api
local mirror = require("emacs.mirror")

-- Keys as typed; "x" ends Insert mode when the keys run out.
local function type(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function agree(t, path, what)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), (what or "") .. " Emacs agrees")
end

-- An augroup for the simulated plugin, cleared after the test.
local function plugin_group(t)
  local group = api.nvim_create_augroup("plugin_interplay", { clear = true })
  t.after(function() api.nvim_del_augroup_by_id(group) end)
  return group
end

-- A global map the "other plugin" made; counts its uses in `hits[name]`.
local function global_map(t, hits, mode, lhs, name)
  vim.keymap.set(mode, lhs, function() hits[name] = (hits[name] or 0) + 1 end)
  t.after(function() vim.keymap.del(mode, lhs) end)
end

-- An autopair plugin: "[" types "[]" and leaves the cursor between them.
local function autopair(t)
  api.nvim_create_autocmd("InsertCharPre", {
    group = plugin_group(t),
    callback = function()
      if vim.v.char ~= "[" then return end
      vim.v.char = "[]"
      api.nvim_feedkeys(api.nvim_replace_termcodes("<Left>", true, false, true), "ni", false)
    end,
  })
end

-- Lines inside closed Neovim folds, minus each fold's first (shown) line.
local function vim_hidden()
  local out = {}
  for l = 1, vim.fn.line("$") do
    local fs = vim.fn.foldclosed(l)
    if fs ~= -1 and fs ~= l then out[#out + 1] = l end
  end
  return out
end

local HIDDEN_EXPR = [[(with-current-buffer (get-file-buffer %q)
  (save-excursion (goto-char (point-min))
    (let ((n 1) out)
      (while (not (eobp))
        (when (invisible-p (point)) (push n out))
        (forward-line 1) (setq n (1+ n)))
      (concat "[" (mapconcat #'number-to-string (nreverse out) ",") "]"))))]]

local function folds_agree(t, path, what)
  local emacs = vim.json.decode(vim.json.decode(t.eval(HIDDEN_EXPR:format(path))))
  t.eq(vim_hidden(), emacs, (what or "") .. " Emacs hides the same lines")
end

local INDENTED = "* A\n  a1\n  a2\n* B\n  b1\n  b2\n"

-- A formatter-on-save plugin: BufWritePre strips trailing whitespace.
local function strip_on_save(t)
  api.nvim_create_autocmd("BufWritePre", {
    group = plugin_group(t), pattern = "*.org",
    command = [[keeppatterns %s/\s\+$//e]],
  })
end

local TRAILING = "* A  \nbody  \n* B\n"

return {
  -- Emacs: TAB in a table cell realigns and moves to the next field.
  ["a global Insert <Tab> map loses to org's in org buffers and still works elsewhere"] = function(t)
    local hits = {}
    global_map(t, hits, "i", "<Tab>", "tab")
    local path = t.open("pi_tab.org", "| a | bb |\n| ccc | d |\n")
    t.cursor(1, 2)
    type("i<Tab><Esc>")
    t.eq(t.lines(), { "| a   | bb |", "| ccc | d  |" }, "org-cycle realigned the table")
    t.eq(hits.tab, nil, "the global map did not run in the org buffer")
    agree(t, path)
    t.open("pi_tab.txt", "plain\n")
    type("i<Tab><Esc>")
    t.eq(hits.tab, 1, "the global map runs in a non-org buffer")
    t.eq(t.lines(), { "plain" })
  end,

  -- Emacs: C-c C-t t on * B gives * TODO B.
  ["a global Normal <C-c> map loses to org's C-c and still works elsewhere"] = function(t)
    local hits = {}
    global_map(t, hits, "n", "<C-c>", "cc")
    local path = t.open("pi_cc.org", t.DOC)
    t.cursor(5)
    t.answer("C-t", "t")
    type("<C-c>")
    t.eq(t.lines()[5], "* TODO B")
    t.eq(hits.cc, nil, "the global map did not run in the org buffer")
    agree(t, path)
    vim.cmd("silent write")
    vim.cmd("bwipeout")
    vim.cmd("enew")
    type("<C-c>")
    t.eq(hits.cc, 1, "the global map runs once the org buffer is gone")
  end,

  -- Emacs with electric-pair-local-mode: [ x at a heading's end gives
  -- "* Head[x]", at a body line's end "body[x]".
  ["an autopair InsertCharPre pairs [ on a heading and a body line"] = function(t)
    autopair(t)
    local path = t.open("pi_pair.org", "* Head\nbody\n")
    type("A[x<Esc>")
    t.eq(t.lines()[1], "* Head[x]", "heading")
    t.cursor(2)
    type("A[x<Esc>")
    t.eq(t.lines()[2], "body[x]", "body line")
    agree(t, path)
  end,

  -- Emacs with electric-pair-local-mode: [ x after "a" in "| a | b |"
  -- gives "| a[x] | b |" (point before the ]).
  ["an autopair InsertCharPre on a table row types the pair once, in Emacs too"] = function(t)
    autopair(t)
    local path = t.open("pi_pair_table.org", "| a | b |\n")
    t.cursor(1, 2)
    type("a[x<Esc>")
    t.eq(t.lines(), { "| a[x] | b |" })
    agree(t, path)
  end,

  -- Emacs: org-startup-folded nil shows everything; TAB on * A folds it.
  ["a FileType org autocmd setting foldmethod=indent, conceallevel=0, wrap, spell"] = function(t)
    api.nvim_create_autocmd("FileType", {
      group = plugin_group(t), pattern = "org",
      callback = function()
        vim.wo.foldmethod = "indent"
        vim.wo.conceallevel = 0
        vim.wo.wrap = true
        vim.wo.spell = true
      end,
    })
    local path = t.open("pi_ft_indent.org", INDENTED)
    t.after(function() vim.wo.spell = false end)
    t.eq(t.folds(), {}, "nothing folded at startup, as in Emacs")
    folds_agree(t, path, "startup:")
    t.cursor(1)
    type("<Tab>")
    t.eq(t.folds(), { "1-3" }, "TAB folds A")
    folds_agree(t, path, "after TAB:")
    t.cursor(4)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[4], "* TODO B")
    agree(t, path)
  end,

  -- Emacs: everything visible at startup; TAB on * B folds B only.
  ["a FileType org autocmd setting foldmethod=expr leaves org's folds in charge"] = function(t)
    api.nvim_create_autocmd("FileType", {
      group = plugin_group(t), pattern = "org",
      callback = function()
        vim.wo.foldmethod = "expr"
        vim.wo.foldexpr = [[getline(v:lnum)=~'^\*'?'>1':'=']]
        vim.wo.foldlevel = 0
      end,
    })
    local path = t.open("pi_ft_expr.org", INDENTED)
    t.after(function() vim.wo.foldlevel = 0 end)
    t.eq(t.folds(), {}, "nothing folded at startup, as in Emacs")
    folds_agree(t, path, "startup:")
    t.cursor(4)
    type("<Tab>")
    t.eq(t.folds(), { "4-6" }, "TAB folds B")
    folds_agree(t, path, "after TAB:")
    t.answer("t")
    t.cursor(1)
    t.keys("C-c C-t")
    t.eq(t.lines()[1], "* TODO A")
    agree(t, path)
  end,

  -- Neovim ships no org parser, so a stand-in language shows whether the
  -- bridge stops a highlighter another plugin starts, also after :e!.
  ["vim.treesitter.start from a FileType org autocmd is stopped, also after :e!"] = function(t)
    local tried_org
    api.nvim_create_autocmd("FileType", {
      group = plugin_group(t), pattern = "org",
      callback = function(ev)
        tried_org = pcall(vim.treesitter.start, ev.buf, "org")
        pcall(vim.treesitter.start, ev.buf, "markdown")
      end,
    })
    local path = t.open("pi_ts.org", t.DOC)
    local buf = api.nvim_get_current_buf()
    vim.wait(50)
    t.eq(tried_org, false, "no org parser (the plugin's start fails quietly)")
    t.eq(vim.treesitter.highlighter.active[buf] ~= nil, false, "highlighter stopped after open")
    vim.cmd("edit!")
    vim.wait(50)
    t.eq(vim.treesitter.highlighter.active[buf] ~= nil, false, "highlighter stopped after :e!")
    t.answer("t")
    t.cursor(5)
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    agree(t, path)
  end,

  -- The statusline is evaluated on every redraw, including while Emacs
  -- waits for a key (here org-todo's selection key).
  ["a statusline calling emacs.statusline() evaluates mid-prompt and shows the clock"] = function(t)
    local old = vim.o.statusline
    vim.o.statusline = "%{v:lua.require'emacs'.statusline()}"
    t.after(function() vim.o.statusline = old end)
    t.after(function() t.eval("(when (org-clocking-p) (org-clock-out))") end)
    local path = t.open("pi_status.org", "* Task\n* B\n")
    t.keys("C-c C-x C-i")
    local function drawn() return api.nvim_eval_statusline(vim.o.statusline, {}).str end
    assert(drawn():find("Task"), "statusline: " .. drawn())
    local rpc = require("emacs.rpc")
    local read_key = rpc.handlers.read_key
    local mid
    rpc.handlers.read_key = function(p)
      mid = drawn()
      return read_key(p)
    end
    t.answer("t")
    t.cursor(t.find_line("^%* B"))
    t.keys("C-c C-t")
    assert(mid and mid:find("Task"), "mid-prompt statusline: " .. tostring(mid))
    t.eq(t.lines()[t.find_line("B$")], "* TODO B")
    agree(t, path)
  end,

  -- Emacs: yanking "| a | b |\n| cc | d |" inserts it as is.
  [":set paste: typed table text goes in literally"] = function(t)
    vim.o.paste = true
    t.after(function() vim.o.paste = false end)
    local path = t.open("pi_paste.org", "* T\n\n")
    t.cursor(2)
    type("i| a | b |<CR>| cc | d |<Esc>")
    t.eq(t.lines(), { "* T", "| a | b |", "| cc | d |" })
    agree(t, path)
  end,

  -- Emacs with delete-trailing-whitespace on before-save-hook: the hook
  -- strips the buffer itself, so the file, the buffer and later commands
  -- all see stripped text.
  ["a BufWritePre that strips whitespace during an Emacs save keeps both sides equal"] = function(t)
    strip_on_save(t)
    local path = t.open("pi_strip_emacs.org", TRAILING)
    t.cursor(3)
    t.answer("t")
    t.keys("C-c C-t")
    t.keys("C-x C-s")
    t.eq(t.read_file(path), "* A\nbody\n* TODO B\n", "file on disk")
    t.eq(t.lines(), { "* A", "body", "* TODO B" }, "Neovim")
    agree(t, path, "after the save:")
    t.cursor(1)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines(), { "* TODO A", "body", "* TODO B" }, "a later command")
    agree(t, path, "after a later command:")
  end,
}
