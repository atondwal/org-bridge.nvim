-- Agenda bulk marks: m, u, U, *, %, M-m, the > marker, and B actions
-- that edit the files and redraw without marks. (agenda_views and
-- agenda_editing cover m + B t, the marker after m, B s and B r.)
local api = vim.api

-- a.org is open in Neovim; b.org is only an agenda file.
local function setup(t)
  local a = t.open("bulk_a.org", "* TODO Write report :work:\n* TODO Call Bob :home:\n* NEXT Plan trip :work:\n")
  local b = t.file("bulk_b.org", "* TODO Pay rent :home:\n* TODO Read book\n")
  t.eval(([[(setq org-agenda-files (list %q %q))]]):format(a, b))
  return a, b
end

-- The global TODO list: line 3 Write report, 4 Call Bob, 5 Plan trip,
-- 6 Pay rent, 7 Read book.
local function todo_list(t)
  t.answer("t")
  t.command("org-agenda")
end

local function press(keys) api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false) end

local function lines_of(path) return api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false) end

-- Whether agenda line `line` shows Emacs's "> " mark: as concealed text
-- or virtual text over its first two characters.
local function shows_mark(line)
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
    if m[4].conceal == ">" then return true end
    for _, chunk in ipairs(m[4].virt_text or {}) do
      if chunk[1] == "> " then return true end
    end
  end
  return false
end

-- Task names whose agenda line shows the mark, in agenda order.
local function marked()
  local out = {}
  for l = 1, api.nvim_buf_line_count(0) do
    if shows_mark(l) then
      local text = api.nvim_buf_get_lines(0, l - 1, l, false)[1]:gsub("%s+:[%w:]+:$", "")
      out[#out + 1] = text:match("[A-Z]+ (.*)$")
    end
  end
  return out
end

local function emacs_marked(t) return t.eval("(length org-agenda-bulk-marked-entries)") end

local function line() return api.nvim_win_get_cursor(0)[1] end

return {
  ["u unmarks the entry at point and moves down; U unmarks all"] = function(t)
    setup(t)
    todo_list(t)
    t.cursor(3)
    press("mm")
    t.eq(marked(), { "Write report", "Call Bob" })
    t.eq(line(), 5, "m moves down")
    t.cursor(4)
    press("u")
    t.eq(marked(), { "Write report" })
    t.eq(line(), 5, "u moves down")
    press("U")
    t.eq(marked(), {})
    t.eq(emacs_marked(t), "0")
  end,

  ["* marks every entry and keeps the cursor line"] = function(t)
    setup(t)
    todo_list(t)
    t.cursor(4)
    press("*")
    t.eq(marked(), { "Write report", "Call Bob", "Plan trip", "Pay rent", "Read book" })
    t.eq(line(), 4)
    t.eq(emacs_marked(t), "5")
  end,

  ["% marks the entries matching the regexp typed"] = function(t)
    setup(t)
    todo_list(t)
    t.answer("Bob\\|book")
    press("%")
    t.eq(marked(), { "Call Bob", "Read book" })
    t.eq(emacs_marked(t), "2")
  end,

  ["M-m unmarks a marked entry and marks an unmarked one, moving down"] = function(t)
    setup(t)
    todo_list(t)
    t.cursor(4)
    press("m")
    t.cursor(4)
    press("<M-m>")
    t.eq(marked(), {}, "M-m on a marked entry")
    t.eq(line(), 5)
    press("<M-m>")
    t.eq(marked(), { "Plan trip" }, "M-m on an unmarked entry")
    t.eq(line(), 6)
  end,

  ["B + tags every marked entry in both files and redraws without marks"] = function(t)
    local a, b = setup(t)
    todo_list(t)
    t.cursor(4)
    press("m")
    t.cursor(7)
    press("m")
    t.answer("+", "urgent")
    press("B")
    t.eq(t.asked()[3].params.prompt, "Tag to add: ")
    t.eq(lines_of(a), { "* TODO Write report :work:", t.aligned("* TODO Call Bob", ":home:urgent:"),
      "* NEXT Plan trip :work:" })
    t.eq(t.emacs_lines(b), { "* TODO Pay rent :home:", t.aligned("* TODO Read book", ":urgent:") })
    assert(t.find_line("Call Bob%s+:home:urgent:$"), "agenda redrawn:\n" .. table.concat(t.lines(), "\n"))
    t.eq(marked(), {})
    t.eq(emacs_marked(t), "0")
  end,

  ["B - removes a tag, realigning the other marked entry's tags"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(4)
    press("mm")
    t.answer("-", "work")
    press("B")
    t.eq(lines_of(a), { "* TODO Write report :work:", t.aligned("* TODO Call Bob", ":home:"), "* NEXT Plan trip" })
    t.eq(marked(), {})
  end,

  ["B p keeps the marks after the action"] = function(t)
    local a = setup(t)
    todo_list(t)
    t.cursor(4)
    press("m")
    t.answer("p", "+", "urgent")
    press("B")
    t.eq(lines_of(a)[2], t.aligned("* TODO Call Bob", ":home:urgent:"))
    t.eq(marked(), { "Call Bob" })
    t.eq(emacs_marked(t), "1")
  end,

  ["B t on entries marked by * sets every TODO state"] = function(t)
    local a, b = setup(t)
    todo_list(t)
    press("*")
    t.answer("t", "DONE")
    press("B")
    t.eq(t.asked()[3].params.prompt, "Todo state: ")
    for _, l in ipairs(lines_of(a)) do assert(l:find("^%* DONE "), l) end
    for _, l in ipairs(t.emacs_lines(b)) do assert(l:find("^%* DONE "), l) end
    t.eq(marked(), {})
  end,
}
