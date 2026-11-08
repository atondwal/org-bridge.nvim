-- Tables: formulas, sums, creation, row/column editing, RET and the C-c `
-- field editor. The C-c + message comes from `emacs -Q -nw`.
local api = vim.api

local FORMULA_TABLE = table.concat({
  "| a | b |",
  "|---+---|",
  "| 1 | 2 |",
  "| 3 | 4 |",
  "|   |   |",
  "#+TBLFM: @>$1=vsum(@I..@II)::@>$2=vsum(@I..@II)",
  "",
}, "\n")

local SUMMED = { "| a | b |", "|---+---|", "| 1 | 2 |", "| 3 | 4 |", "| 4 | 6 |",
  "#+TBLFM: @>$1=vsum(@I..@II)::@>$2=vsum(@I..@II)" }

local SMALL = "| a | b |\n| 1 | 2 |\n"

local function cursor() return api.nvim_win_get_cursor(0) end

return {
  ["C-c C-c on #+TBLFM and C-c * in the table recalculate"] = function(t)
    t.open("tblfm.org", FORMULA_TABLE)
    t.cursor(6)
    t.keys("C-c C-c")
    t.eq(t.lines(), SUMMED, "C-c C-c on the formula line")
    t.eq(cursor(), { 6, 0 })
    t.open("cstar.org", FORMULA_TABLE)
    t.cursor(3, 2)
    t.keys("C-c *")
    t.eq(t.lines(), SUMMED, "C-c * on a data row")
    t.eq(cursor(), { 3, 2 })
  end,

  ["C-c + copies the column sum and says so"] = function(t)
    t.open("sum.org", "| x |\n| 1 |\n| 2 |\n| 3 |\n")
    t.cursor(2, 2)
    vim.cmd("messages clear")
    t.keys("C-c +")
    t.eq(t.lines(), { "| x |", "| 1 |", "| 2 |", "| 3 |" }, "buffer unchanged")
    t.eq(t.eval("(current-kill 0)"), [["6"]], "sum in the kill ring")
    local msgs = vim.fn.execute("messages")
    assert(msgs:find("Sum of 3 items: 6", 1, true), "sum shown: " .. vim.inspect(msgs))
  end,

  ["C-c | asks for a size and creates the table"] = function(t)
    t.open("create.org", "* H\n\n")
    t.cursor(2)
    t.answer("3x2")
    t.keys("C-c |")
    t.eq(t.asked()[1].params.prompt, "Table size Columns x Rows [e.g. 5x2]: ")
    t.eq(t.lines(), { "* H", "|   |   |   |", "|---+---+---|", "|   |   |   |", "" })
    t.eq(cursor(), { 2, 0 })
    t.open("create_default.org", "* H\n\n")
    t.cursor(2)
    t.answer("")
    t.keys("C-c |")
    t.eq(t.lines()[2], "|   |   |   |   |   |", "empty answer takes the 5x2 default")
  end,

  ["C-c - adds an hline below the row"] = function(t)
    t.open("hline.org", SMALL)
    t.cursor(1, 2)
    t.keys("C-c -")
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 | 2 |" })
    t.eq(cursor(), { 1, 2 })
  end,

  ["M-S-right inserts a column, M-S-left deletes one"] = function(t)
    t.open("cols.org", SMALL)
    t.cursor(1, 2)
    t.keys("M-S-<right>")
    t.eq(t.lines(), { "|   | a | b |", "|   | 1 | 2 |" }, "column inserted")
    t.eq(cursor(), { 1, 2 })
    t.keys("M-S-<left>")
    t.eq(t.lines(), { "| a | b |", "| 1 | 2 |" }, "column deleted")
    t.keys("M-S-<left>")
    t.eq(t.lines(), { "| b |", "| 2 |" }, "first column deleted")
  end,

  ["M-up and M-down move table rows"] = function(t)
    t.open("rows.org", "| a | b |\n| 1 | 2 |\n| 3 | 4 |\n")
    t.cursor(2, 2)
    t.keys("M-<down>")
    t.eq(t.lines(), { "| a | b |", "| 3 | 4 |", "| 1 | 2 |" })
    t.eq(cursor(), { 3, 2 }, "cursor follows the row")
    t.keys("M-<up>")
    t.keys("M-<up>")
    t.eq(t.lines(), { "| 1 | 2 |", "| a | b |", "| 3 | 4 |" })
    t.eq(cursor(), { 1, 2 })
  end,

  ["RET moves down a row, adding one at the end"] = function(t)
    t.open("ret.org", SMALL)
    t.cursor(1, 2)
    t.keys("RET")
    t.eq(t.lines(), { "| a | b |", "| 1 | 2 |" })
    t.eq(cursor(), { 2, 2 })
    t.keys("RET")
    t.eq(t.lines(), { "| a | b |", "| 1 | 2 |", "|   |   |" }, "new row")
    t.eq(cursor(), { 3, 2 })
  end,

  ["C-c ` edits a field in a mirrored buffer and C-c C-c puts it back"] = function(t)
    t.open("field.org", SMALL)
    local org = api.nvim_get_current_buf()
    t.cursor(2, 6)
    t.keys("C-c `")
    t.eq(api.nvim_buf_get_name(0):match("Org Table Edit Field") ~= nil, true,
      "edit buffer focused: " .. api.nvim_buf_get_name(0))
    t.eq(t.lines(), { "#", "# Edit field @2$2 and finish with C-c C-c", "#", "2" })
    t.eq(vim.bo.modifiable, true, "editable")
    t.eq(cursor(), { 4, 0 })
    t.eq(#vim.fn.win_findbuf(org), 1, "org window kept")
    api.nvim_buf_set_lines(0, 3, 4, false, { "2long value" })
    t.keys("C-c C-c")
    t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "edit window closed")
    t.eq(t.lines(), { "| a | b           |", "| 1 | 2long value |" })
    t.eq(cursor(), { 2, 6 })
  end,
}
