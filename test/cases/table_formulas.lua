-- Table formulas: C-c = and C-u C-c =, recalculation, #+TBLFM editing, the
-- C-c ' formula editor, C-c ? and C-c }, remote references, Calc and Elisp.
local api = vim.api

local PLAIN = "| a | b |\n|---+---|\n| 1 |   |\n| 3 |   |\n"
local DOUBLED = PLAIN .. "#+TBLFM: $2=$1*2\n"

local function cursor() return api.nvim_win_get_cursor(0) end

-- Every virtual text string drawn in the current buffer, sorted.
local function virt_texts()
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do out[#out + 1] = chunk[1] end
  end
  table.sort(out)
  return out
end

return {
  -- Org 9.6 stores the formula and fills only the field at point.
  ["C-c = asks for a column formula and computes the field"] = function(t)
    t.open("col.org", PLAIN)
    t.cursor(3, 6)
    t.answer("$1*2")
    t.keys("C-c =")
    t.eq(t.asked()[1].params.prompt, "Column formula $2=")
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 | 2 |", "| 3 |   |", "#+TBLFM: $2=$1*2" })
    t.eq(cursor(), { 3, 6 })
  end,

  ["C-u C-c = stores a field formula"] = function(t)
    t.open("field.org", PLAIN)
    t.cursor(4, 6)
    t.answer("$1+10")
    t.keys("C-c =", 4)
    t.eq(t.asked()[1].params.prompt, "Field formula @3$2=")
    t.eq(t.lines(), { "| a |  b |", "|---+----|", "| 1 |    |", "| 3 | 13 |", "#+TBLFM: @3$2=$1+10" })
  end,

  ["C-c = offers the stored formula, and an empty answer removes it"] = function(t)
    t.open("remove.org", PLAIN .. "#+TBLFM: $2=$1*2::$1=3\n")
    t.cursor(4, 6)
    t.answer("")
    t.keys("C-c =")
    t.eq(t.asked()[1].params.initial, "$1*2")
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 |   |", "| 3 |   |", "#+TBLFM: $1=3" })
  end,

  ["C-c C-c in the table only aligns, C-u C-c C-c recalculates"] = function(t)
    t.open("recalc.org", DOUBLED)
    t.cursor(3, 2)
    t.keys("C-c C-c")
    t.eq(t.lines(), vim.split(DOUBLED, "\n", { plain = true, trimempty = true }), "plain C-c C-c")
    t.keys("C-c C-c", 4)
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 | 2 |", "| 3 | 6 |", "#+TBLFM: $2=$1*2" })
    t.eq(cursor(), { 3, 2 })
  end,

  ["an edited #+TBLFM line applies on C-c C-c"] = function(t)
    t.open("edit.org", DOUBLED)
    api.nvim_buf_set_lines(0, 4, 5, false, { "#+TBLFM: $2=$1*10" })
    t.cursor(5)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "| a |  b |", "|---+----|", "| 1 | 10 |", "| 3 | 30 |", "#+TBLFM: $2=$1*10" })
    t.eq(t.emacs_lines(api.nvim_buf_get_name(0)), t.lines(), "Emacs agrees")
  end,

  ["Elisp and Calc formulas with format flags"] = function(t)
    t.open("lisp.org", "| a | b | c |\n|---+---+---|\n| 1 | 2 |   |\n| 3 | 4 |   |\n"
      .. "#+TBLFM: $3='(* $1 $2 100);N\n")
    t.cursor(5)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "| a | b |    c |", "|---+---+------|", "| 1 | 2 |  200 |", "| 3 | 4 | 1200 |",
      "#+TBLFM: $3='(* $1 $2 100);N" }, "Elisp")
    t.open("calc.org", "| a | b | c |\n|---+---+---|\n| 1 | 3 |   |\n| 2 | 3 |   |\n"
      .. "#+TBLFM: $3=$1/$2;%.3f\n")
    t.cursor(5)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "| a | b |     c |", "|---+---+-------|", "| 1 | 3 | 0.333 |", "| 2 | 3 | 0.667 |",
      "#+TBLFM: $3=$1/$2;%.3f" }, "Calc")
  end,

  ["remote() reads a field of a named table"] = function(t)
    t.open("remote.org", "#+NAME: src\n| x |\n| 7 |\n\n| y |\n|   |\n#+TBLFM: @1$1=remote(src,@2$1)*3\n")
    t.cursor(7)
    t.keys("C-c C-c")
    t.eq(t.lines(), { "#+NAME: src", "| x |", "| 7 |", "", "| 21 |", "|    |",
      "#+TBLFM: @1$1=remote(src,@2$1)*3" })
  end,

  -- Emacs opens *Edit Formulas* in another window, on the field's formula;
  -- finishing returns to the start of the line C-c ' ran on.
  ["C-c ' edits formulas, C-c C-c installs and C-u C-c C-c also applies"] = function(t)
    t.open("fedit.org", DOUBLED)
    local org = api.nvim_get_current_buf()
    t.cursor(3, 6)
    t.keys("C-c '")
    t.eq(api.nvim_get_current_buf() ~= org, true, "editor focused")
    t.eq(t.lines(), { "# Column Formulas", "$2 = $1*2" })
    t.eq(cursor(), { 2, 0 })
    api.nvim_buf_set_lines(0, 1, 2, false, { "$2 = $1*5" })
    t.keys("C-c C-c")
    t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "editor window closed")
    t.eq(t.lines(), { "| a | b |", "|---+---|", "| 1 |   |", "| 3 |   |", "#+TBLFM: $2=$1*5" }, "installed only")
    t.eq(cursor(), { 3, 0 })
    t.cursor(3, 6)
    t.keys("C-c '")
    api.nvim_buf_set_lines(0, 1, 2, false, { "$2 = $1*7" })
    t.keys("C-c C-c", 4)
    t.eq(api.nvim_get_current_buf(), org, "back after C-u C-c C-c")
    t.eq(t.lines(), { "| a |  b |", "|---+----|", "| 1 |  7 |", "| 3 | 21 |", "#+TBLFM: $2=$1*7" })
  end,

  ["C-c ' starts on the field formula, C-c C-q aborts"] = function(t)
    local text = PLAIN .. "#+TBLFM: $2=$1*2::@3$2=$1+10\n"
    t.open("fabort.org", text)
    local org = api.nvim_get_current_buf()
    t.cursor(4, 6)
    t.keys("C-c '")
    t.eq(t.lines(), { "# Column Formulas", "$2 = $1*2", "", "# Field and Range Formulas", "@3$2 = $1+10" })
    t.eq(cursor(), { 5, 0 })
    api.nvim_buf_set_lines(0, 4, 5, false, { "@3$2 = $1+99" })
    t.keys("C-c C-q")
    t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "editor window closed")
    t.eq(t.lines(), vim.split(text, "\n", { plain = true, trimempty = true }), "nothing installed")
    t.eq(cursor(), { 4, 6 })
  end,

  ["C-c ? describes the field and its formula"] = function(t)
    t.open("info.org", PLAIN .. "#+TBLFM: @3$2=$1+10\n")
    t.cursor(4, 6)
    vim.cmd("messages clear")
    t.keys("C-c ?")
    local msgs = vim.fn.execute("messages")
    assert(msgs:find("line @3, col $2, ref @3$2 or B3, formula: @3$2=$1+10", 1, true),
      "info shown: " .. vim.inspect(msgs))
  end,

  -- Emacs puts row numbers before each data line ("   1", "I*1 " on the
  -- hline) and column numbers over the hline as display strings.
  ["C-c } shows row and column coordinates, and again hides them"] = function(t)
    t.set("org-table-overlay-coordinates", "nil")
    t.open("coords.org", DOUBLED)
    t.cursor(3, 6)
    t.keys("C-c }")
    t.eq(t.eval([[(if org-table-overlay-coordinates "on" "off")]]), [["on"]])
    t.eq(virt_texts(), { "   1", "   2", "   3", "$1", "$2", "I*1 " })
    t.eq(t.lines(), vim.split(DOUBLED, "\n", { plain = true, trimempty = true }), "text unchanged")
    t.keys("C-c }")
    t.eq(virt_texts(), {})
  end,
  -- :w is C-x C-s, which in *Edit Formulas* installs and closes the editor.
  [":w in the formula editor installs the formulas without an error"] = function(t)
    t.open("fsave.org", DOUBLED)
    local org = api.nvim_get_current_buf()
    t.cursor(3, 6)
    t.keys("C-c '")
    api.nvim_buf_set_lines(0, 1, 2, false, { "$2 = $1*5" })
    vim.cmd("messages clear")
    vim.cmd("write")
    t.eq(api.nvim_get_current_buf(), org, "back in the org buffer")
    t.eq(t.lines()[5], "#+TBLFM: $2=$1*5")
    local msgs = vim.fn.execute("messages")
    t.eq(msgs:find("Invalid buffer", 1, true), nil, "no error: " .. msgs)
  end,
}
