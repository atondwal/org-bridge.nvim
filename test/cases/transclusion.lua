-- org-transclusion: it copies another file's text into the buffer as
-- read-only text, takes it out in before-save-hook and puts it back in
-- after-save-hook. Neovim writes the files, so the bridge runs both hooks
-- around :w. Needs org-transclusion on Emacs's load-path (EMACSLOADPATH).
local api = vim.api

local SOURCE = "* Source\nsource text\n"
local NOTE = "* Note\n#+transclude: [[file:tc_source.org::*Source]]\n"

-- a note transcluding tc_source.org's heading, its copy shown.
local function transclude(t, name)
  if t.eval("(require 'org-transclusion nil t)") == "nil" then t.skip("org-transclusion is not installed") end
  local source = t.file("tc_source.org", SOURCE)
  local note = t.open(name, NOTE)
  t.command("org-transclusion-add-all")
  assert(t.find_line("^source text"), "copy shown:\n" .. table.concat(t.lines(), "\n"))
  return note, source
end

return {
  [":w writes the note without the copy, which stays shown, unmodified"] = function(t)
    local note = transclude(t, "tc_write.org")
    vim.cmd("write")
    t.eq(t.read_file(note), NOTE, "the file has only the #+transclude line")
    -- after-save-hook put it back outside a command: Neovim pulls it.
    assert(vim.wait(3000, function() return t.find_line("^source text") ~= nil end, 10),
      "copy shown again:\n" .. table.concat(t.lines(), "\n"))
    t.eq(vim.bo.modified, false)
    t.eq(t.emacs_lines(note), t.lines(), "Emacs agrees")
  end,

  ["C-x C-s writes the note without the copy too"] = function(t)
    local note = transclude(t, "tc_cxcs.org")
    api.nvim_buf_set_lines(0, 0, 1, false, { "* Note, edited" })
    t.keys("C-x C-s")
    t.eq(t.read_file(note), NOTE:gsub("Note", "Note, edited", 1))
    assert(t.find_line("^source text"), "copy shown again:\n" .. table.concat(t.lines(), "\n"))
    t.eq(vim.bo.modified, false)
  end,

  -- Emacs makes the copy read-only; an edit there would be lost to the
  -- next save, which swaps the copy for the source's text.
  ["typing into the copy without live sync is undone, as Emacs refuses it"] = function(t)
    local note, source = transclude(t, "tc_ro.org")
    local row = t.find_line("^source text")
    api.nvim_buf_set_lines(0, row - 1, row, false, { "source text, typed over" })
    api.nvim_buf_set_lines(0, 0, 1, false, { "* Note, edited" })
    require("emacs.mirror").sync()
    t.eq(t.lines(), { "* Note, edited", "* Source", "source text" }, "the copy's edit undone, the other kept")
    t.eq(t.emacs_lines(note), t.lines(), "Emacs agrees")
    t.eq(t.emacs_lines(source), { "* Source", "source text" })
  end,

  ["with live sync, editing the copy in Neovim edits the source"] = function(t)
    local note, source = transclude(t, "tc_live.org")
    t.cursor(t.find_line("^source text"))
    t.command("org-transclusion-live-sync-start")
    local row = t.find_line("^source text")
    api.nvim_buf_set_lines(0, row - 1, row, false, { "source text, edited from the note" })
    require("emacs.mirror").sync()
    t.eq(t.emacs_lines(source), { "* Source", "source text, edited from the note" })
    -- C-c C-c ends live sync; :wall saves the source, and the note as a
    -- #+transclude line.
    t.cursor(t.find_line("^source text"))
    t.keys("C-c C-c")
    vim.cmd("wall")
    t.eq(t.read_file(source), "* Source\nsource text, edited from the note\n")
    t.eq(t.read_file(note), NOTE)
  end,
}
