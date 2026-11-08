-- Robustness: Emacs dying, reloads, undo, renames, deleted buffers, splits.
local api = vim.api
local rpc = require("emacs.rpc")
local mirror = require("emacs.mirror")

local function kill_emacs(t)
  local pid = tonumber(t.eval("(emacs-pid)"))
  vim.loop.kill(pid, 9)
  assert(vim.wait(5000, function() return not rpc.running() end, 10), "Emacs still running")
  return pid
end

local function win_folds(t, win)
  return api.nvim_win_call(win, t.folds)
end

-- Emacs's own fold ranges for the buffer visiting `name`, as Neovim line ranges.
local function emacs_folds(t, name)
  local printed = t.eval(([[(with-current-buffer %q
    (mapconcat (lambda (r) (format "%%d-%%d" (1+ (car r)) (1+ (cadr r)))) (nvb--hidden-ranges) " "))]]):format(name))
  local out = {}
  for r in vim.json.decode(printed):gmatch("%S+") do out[#out + 1] = r end
  return out
end

return {
  ["a killed Emacs restarts on the next command"] = function(t)
    t.open("killed.org", t.DOC)
    local old_pid = kill_emacs(t)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    assert(tonumber(t.eval("(emacs-pid)")) ~= old_pid, "a new Emacs")
    t.eq(t.emacs_text("killed.org"), table.concat(t.lines(), "\n") .. "\n", "Emacs has Neovim's text")
  end,

  ["after a restart Neovim's folds match Emacs's"] = function(t)
    t.open("refold.org", t.DOC)
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" }, "folded before the crash")
    kill_emacs(t)
    t.command("ignore")
    t.eq(t.folds(), emacs_folds(t, "refold.org"), "Neovim shows Emacs's folds")
  end,

  [":EmacsRestart keeps the current buffer and re-attaches all org buffers"] = function(t)
    vim.cmd("runtime plugin/emacs.lua")
    t.open("first.org", t.DOC)
    local first = api.nvim_get_current_buf()
    t.open("second.org", t.DOC)
    local second = api.nvim_get_current_buf()
    vim.cmd("buffer " .. first)
    local old_pid = t.eval("(emacs-pid)")
    vim.cmd("EmacsRestart")
    assert(t.eval("(emacs-pid)") ~= old_pid, "a new Emacs")
    t.eq(api.nvim_get_current_buf(), first, "current buffer")
    assert(mirror.id(first) and mirror.id(second), "both attached")
  end,

  [":e! after an external change reloads without marking the buffer modified"] = function(t)
    local path = t.open("reload.org", t.DOC)
    vim.api.nvim_buf_set_lines(0, 4, 5, false, { "* Unsaved" })
    t.keys("TAB")
    t.file("reload.org", "* X\nbody x\n* Y\n")
    vim.cmd("edit!")
    t.cursor(1)
    t.keys("TAB")
    t.eq(t.lines(), { "* X", "body x", "* Y" })
    t.eq(t.folds(), { "1-2" })
    t.eq(t.emacs_text("reload.org"), "* X\nbody x\n* Y\n")
    t.eq(vim.bo.modified, false, "Neovim modified")
    t.eq(t.eval([[(buffer-modified-p (get-file-buffer ]] .. ("%q"):format(path) .. "))"), "nil", "Emacs modified")
  end,

  ["undo between Emacs commands keeps both sides in step"] = function(t)
    t.open("undo.org", t.DOC)
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    vim.cmd("normal! u")
    t.eq(t.lines()[5], "* B", "undone")
    t.cursor(5)
    t.answer("n")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* NEXT B")
    t.eq(t.emacs_text("undo.org"), table.concat(t.lines(), "\n") .. "\n")
  end,

  [":saveas then reopening the old file keeps the two buffers apart"] = function(t)
    local old = t.open("before.org", t.DOC)
    local new = t.WORK .. "/after.org"
    vim.cmd("silent saveas " .. vim.fn.fnameescape(new))
    local renamed = api.nvim_get_current_buf()
    t.eq(t.eval(("(buffer-file-name (nvb--buffer %d))"):format(mirror.id(renamed))), ("%q"):format(new),
      "Emacs visits the new name")
    vim.cmd("silent edit " .. vim.fn.fnameescape(old))
    local reopened = api.nvim_get_current_buf()
    assert(mirror.id(reopened) ~= mirror.id(renamed), "separate mirrors")
    t.cursor(5)
    t.answer("t")
    t.keys("C-c C-t")
    t.eq(t.lines()[5], "* TODO B")
    t.eq(t.lines(renamed)[5], "* B", "renamed buffer untouched")
  end,

  [":bdelete then reopening attaches a fresh mirror"] = function(t)
    local path = t.open("deleted.org", t.DOC)
    t.keys("TAB")
    vim.cmd("bdelete")
    t.eq(t.eval("(hash-table-count nvb--mirrors)"), "0", "Emacs closed it")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    assert(mirror.id(api.nvim_get_current_buf()), "attached again")
    t.keys("TAB")
    t.eq(t.folds(), { "1-4" })
    t.eq(t.eval("(hash-table-count nvb--mirrors)"), "1")
  end,

  ["two windows on one buffer both get folds"] = function(t)
    t.open("split.org", t.DOC)
    local top = api.nvim_get_current_win()
    vim.cmd("split")
    local bottom = api.nvim_get_current_win()
    t.cursor(1)
    t.keys("TAB")
    t.eq(win_folds(t, top), { "1-4" }, "other window")
    t.eq(win_folds(t, bottom), { "1-4" }, "current window")
    api.nvim_set_current_win(top)
    t.keys("<backtab>")
    t.eq(win_folds(t, top), { "1-4", "5-6" }, "current window after S-TAB")
    t.eq(win_folds(t, bottom), { "1-4", "5-6" }, "other window after S-TAB")
  end,

  -- Org 9.6 errors repairing a fold that now starts the buffer, and Emacs
  -- then drops the buffer's after-change hooks (found by test/fuzz.lua).
  ["deleting a folded heading at the top keeps org's change hooks"] = function(t)
    t.open("tophead.org", "* A\nbody\nmore\n* B\n")
    t.keys("TAB")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    require("emacs.mirror").sync()
    t.eq(t.eval([[(with-current-buffer "tophead.org" (and after-change-functions t))]]), "t")
    t.eq(t.emacs_text(vim.api.nvim_buf_get_name(0)), "body\nmore\n* B\n")
  end,

  -- Emacs's batch frame has 24 rows; windows it can't fit stay in Neovim.
  ["more splits than Emacs's frame holds all survive a command"] = function(t)
    t.open("splits.org", t.DOC)
    for _ = 1, 25 do vim.cmd("vsplit | wincmd =") end
    local before = #vim.api.nvim_tabpage_list_wins(0)
    t.keys("TAB")
    t.eq(#vim.api.nvim_tabpage_list_wins(0), before)
  end,

  -- Another org plugin whose FileType handler fails stops the rest.
  ["a buffer whose FileType handlers never ran attaches when shown"] = function(t)
    vim.o.eventignore = "FileType"
    local ok = pcall(t.open, "noft.org", "* A\n")
    vim.o.eventignore = ""
    assert(ok, "opened")
    t.eq(require("emacs.mirror").id(vim.api.nvim_get_current_buf()) ~= nil, true, "attached")
    t.eq(vim.fn.maparg("<C-c>", "n", false, true).desc, "org-bridge.nvim")
  end,
}
