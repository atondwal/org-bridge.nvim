-- #+transclude: lines: Emacs resolves the link, and Neovim draws the
-- source's text as virtual lines under the keyword, never in the buffer.
-- C-c ' on the keyword opens the source at that text.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")
local SOURCE = "* Alpha\n:PROPERTIES:\n:ID:       tc-alpha-id\n:END:\nalpha body\n* TODO Beta\nbeta body\n\n** Beta child\n"

-- The text drawn under 0-based row and the label after it.
local function drawn(row)
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })) do
    local d = m[4]
    if d.virt_lines then
      local lines = vim.tbl_map(function(chunks)
        return table.concat(vim.tbl_map(function(c) return c[1] end, chunks)):gsub("^│ ", "")
      end, d.virt_lines)
      return lines, d.virt_text and d.virt_text[1][1]
    elseif d.virt_text and d.virt_text_pos == "eol" then
      return {}, d.virt_text[1][1]
    end
  end
end

local function note(t, name, keyword_lines)
  local source = t.file("tc_src.org", SOURCE)
  t.eval(([[(progn (require 'org-id) (org-id-add-location "tc-alpha-id" %q))]]):format(source))
  local path = t.open(name, "* Note\n" .. table.concat(keyword_lines, "\n") .. "\n")
  return path, source
end

return {
  ["a heading, a whole file and an id: link draw their text under the keyword"] = function(t)
    local path = note(t, "tc_draw.org", {
      "#+transclude: [[file:tc_src.org::*Beta]]",
      "#+transclude: [[file:tc_src.org]]",
      "#+transclude: [[id:tc-alpha-id]]",
      "#+transclude: [[file:tc_src.org::*Missing]]",
    })
    local beta, label = drawn(1)
    t.eq(beta, { "* TODO Beta", "beta body", "", "** Beta child" })
    t.eq(label, " ⇣ tc_src.org (4 lines)")
    t.eq(#drawn(2), 9, "the whole file, without its final blank line")
    t.eq(drawn(3), { "* Alpha", ":PROPERTIES:", ":ID:       tc-alpha-id", ":END:", "alpha body" })
    local missing, why = drawn(4)
    t.eq({ missing, why }, { {}, " ⇣ no heading Missing in tc_src.org" })
    vim.cmd("write")
    t.eq(t.read_file(path), "* Note\n" .. table.concat({
      "#+transclude: [[file:tc_src.org::*Beta]]", "#+transclude: [[file:tc_src.org]]",
      "#+transclude: [[id:tc-alpha-id]]", "#+transclude: [[file:tc_src.org::*Missing]]" }, "\n") .. "\n",
      "the file holds only the keywords")
  end,

  ["C-c ' opens the source at the heading; editing it redraws the note"] = function(t)
    local _, source = note(t, "tc_edit.org", { "#+transclude: [[file:tc_src.org::*Beta]]" })
    local note_win = api.nvim_get_current_win()
    t.cursor(2)
    t.keys("C-c '")
    t.eq(api.nvim_buf_get_name(0), source, "the source in a split")
    t.eq(#api.nvim_tabpage_list_wins(0), 2)
    t.eq(api.nvim_get_current_line(), "* TODO Beta")
    local row = api.nvim_win_get_cursor(0)[1]
    api.nvim_buf_set_lines(0, row, row + 1, false, { "beta body, edited" })
    mirror.sync()
    api.nvim_set_current_win(note_win)
    t.eq((drawn(1))[2], "beta body, edited")
  end,
}
