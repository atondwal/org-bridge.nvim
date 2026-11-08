-- The export dispatcher (C-c C-e). Expectations come from emacs -Q --batch
-- with org 9.6: the menu is *Org Export Dispatcher*, read with
-- read-char-exclusive; *Org ASCII Export* is a writable text-mode buffer.
local api = vim.api

local DOC = "#+TITLE: Probe\n* Heading One\nSome *bold* text.\n* Heading Two\nMore.\n"

local function html_path(t) return t.WORK .. "/exp.html" end

local function open(t)
  vim.fn.delete(html_path(t))
  return t.open("exp.org", DOC), api.nvim_get_current_buf()
end

local function read_html(t)
  assert(vim.fn.filereadable(html_path(t)) == 1, "exp.html written next to exp.org")
  return table.concat(vim.fn.readfile(html_path(t)), "\n")
end

return {
  ["C-c C-e shows the dispatcher menu as read_key context"] = function(t)
    open(t)
    t.answer("q")
    t.keys("C-c C-e")
    local q = t.asked()[1]
    t.eq(q.method, "read_key")
    t.eq(q.params.prompt, "Export command: ")
    local ctx = q.params.context or ""
    assert(ctx:find("[h] Export to HTML", 1, true), "menu shown: " .. vim.inspect(q))
    assert(ctx:find("[A] As ASCII buffer", 1, true), "sub-entries shown: " .. ctx)
  end,

  ["h h writes an html file next to the org file"] = function(t)
    local _, buf = open(t)
    t.answer("h", "h")
    t.keys("C-c C-e")
    local html = read_html(t)
    assert(html:find("<html", 1, true), "full document")
    assert(html:find("<b>bold</b>", 1, true), "body exported:\n" .. html)
    t.eq(api.nvim_get_current_buf(), buf, "org file still selected")
    t.eq(#api.nvim_list_wins(), 1, "dispatcher window gone")
  end,

  ["C-b toggles body-only before h h"] = function(t)
    open(t)
    t.answer("C-b", "h", "h")
    t.keys("C-c C-e")
    t.eq(#t.asked(), 3)
    assert(t.asked()[2].params.context:find("Body only:    On", 1, true), "menu redrawn with option on")
    local html = read_html(t)
    assert(not html:find("<html", 1, true), "body only:\n" .. html)
  end,

  ["q at the first level aborts without exporting"] = function(t)
    local _, buf = open(t)
    t.answer("h", "q", "q")
    t.keys("C-c C-e")
    t.eq(#t.asked(), 3, "second q leaves the submenu, third aborts")
    t.eq(vim.fn.filereadable(html_path(t)), 0)
    t.eq(api.nvim_get_current_buf(), buf)
    t.eq(#api.nvim_list_wins(), 1)
  end,



  ["t A shows the ASCII export in a split mirror"] = function(t)
    local _, file_buf = open(t)
    t.answer("t", "A")
    t.keys("C-c C-e")
    assert(api.nvim_buf_get_name(0):find("Org ASCII Export", 1, true),
      "ascii buffer focused: " .. api.nvim_buf_get_name(0))
    local text = table.concat(t.lines(), "\n")
    assert(text:find("PROBE", 1, true) and text:find("Heading One", 1, true), "ascii text:\n" .. text)
    t.eq(#vim.fn.win_findbuf(file_buf), 1, "file window kept")
    t.eq(#api.nvim_list_wins(), 2)
    -- Emacs shows it in text-mode, writable, where q inserts a q.
    t.eq(t.eval([[(with-current-buffer "*Org ASCII Export*" buffer-read-only)]]), "nil")
    t.eq(vim.bo.modifiable, true)
  end,

  ["& opens the export stack read-only, and q closes it"] = function(t)
    local _, file_buf = open(t)
    t.answer("&")
    t.keys("C-c C-e")
    local stack = api.nvim_get_current_buf()
    assert(api.nvim_buf_get_name(stack):find("Org Export Stack", 1, true), "stack focused")
    t.eq(vim.bo.modifiable, false)
    t.eq(#vim.fn.win_findbuf(file_buf), 1, "file window kept")
    api.nvim_feedkeys("q", "x", false)
    t.eq(#vim.fn.win_findbuf(stack), 0)
    t.eq(api.nvim_get_current_buf(), file_buf)
  end,

  ["# inserts an export template into the file mirror"] = function(t)
    open(t)
    t.answer("#", "default")
    t.keys("C-c C-e")
    t.eq(t.asked()[2].method, "completing_read")
    t.eq(t.asked()[2].params.prompt, "Options category: ")
    local lines = t.lines()
    assert(lines[1]:find("^#%+options: "), "template at point:\n" .. table.concat(lines, "\n"))
    assert(vim.tbl_contains(lines, "#+TITLE: Probe"), "original text kept")
  end,


  ["C-u C-c C-e repeats the last export without asking"] = function(t)
    open(t)
    t.answer("h", "h")
    t.keys("C-c C-e")
    vim.fn.delete(html_path(t))
    t.keys("C-c C-e", 4)
    t.eq(#t.asked(), 2, "no new prompts")
    read_html(t)
  end,
}
