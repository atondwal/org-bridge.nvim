-- What Magit draws and does in a file's buffer, reproduced without Magit:
-- blame's headings (overlay strings in `font-lock-face'), the log's dates
-- (margin strings), blame's read-only mode with its own keys, and the
-- environment git runs in.
-- Expected: the same in `emacs -Q -nw -l test/init.el`.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")

local FACES = [[(progn
  (defface nvbt-heading '((t :background "#404040")) "")
  (defface nvbt-hash '((t :foreground "#ff0000")) ""))]]

-- As magit-blame-read-only-mode: q in its keymap leaves it, and with it
-- read-only, unless the buffer was read-only before.
local VIEW_MODE = [[(define-minor-mode nvbt-view-mode "Read-only with q to leave."
  :keymap `((,(kbd "q") . ,(lambda () (interactive) (nvbt-view-mode -1))))
  (if nvbt-view-mode
      (progn (setq-local nvbt-was-read-only buffer-read-only) (read-only-mode 1))
    (unless nvbt-was-read-only (read-only-mode -1))))]]

local function marks(row)
  return vim.tbl_map(function(m) return m[4] end,
    api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true }))
end

local function hl(group) return api.nvim_get_hl(0, { name = group, link = false }) end

return {
  -- Emacs: the heading is a line of its own above "body", the hash red on
  -- the heading's gray.
  ["a before-string ending in a newline at a line's start is a line above, in its faces"] = function(t)
    t.open("heading.org", "* A\nbody\n")
    t.eval(FACES)
    t.eval([[(with-current-buffer "heading.org"
      (overlay-put (make-overlay 5 9) 'before-string
        (concat (propertize "abc" 'font-lock-face '(nvbt-hash nvbt-heading))
                (propertize " sum\n" 'font-lock-face 'nvbt-heading))))]])
    t.command("ignore")
    local m = marks(1)[1]
    t.eq(m.virt_lines_above, true)
    t.eq(m.virt_text, nil, "nothing inline")
    local line = m.virt_lines[1]
    t.eq(vim.tbl_map(function(c) return c[1] end, line), { "abc", " sum" })
    t.eq({ hl(line[1][2]).fg, hl(line[1][2]).bg, hl(line[2][2]).bg }, { 0xff0000, 0x404040, 0x404040 })
  end,

  -- Neovim hides lines above the first until scrolled to; Emacs shows them.
  ["a heading above the first line is in view"] = function(t)
    t.open("top.org", "* A\nbody\n")
    t.eval([[(with-current-buffer "top.org" (overlay-put (make-overlay 1 2) 'before-string "head\n"))]])
    t.command("ignore")
    t.eq(vim.fn.winsaveview().topfill, 1)
  end,

  -- Emacs: one heading above line 101, however the window got there.
  ["a long chunk's heading is drawn once after scrolling past its start"] = function(t)
    local lines = {}
    for i = 1, 400 do lines[i] = "line " .. i end
    t.open("chunk.org", table.concat(lines, "\n") .. "\n")
    t.eval([[(with-current-buffer "chunk.org" (goto-char (point-min))
      (overlay-put (make-overlay (line-beginning-position 101) (line-beginning-position 351)) 'before-string "head\n"))]])
    t.command("ignore")
    for _, top in ipairs({ 91, 251, 91 }) do
      vim.fn.winrestview({ topline = top, lnum = top })
      mirror.refresh_spans(api.nvim_get_current_buf())
    end
    t.eq(#marks(100), 1)
  end,

  -- Emacs: "3 days" in the right margin of "body"'s line.
  ["a margin string is drawn at the window's right edge"] = function(t)
    t.open("margin.org", "* A\nbody\n")
    t.eval(FACES)
    t.eval([[(with-current-buffer "margin.org"
      (overlay-put (make-overlay 6 9) 'before-string
        (propertize "o" 'display `((margin right-margin) ,(propertize "3 days" 'face 'nvbt-hash)))))]])
    t.command("ignore")
    local m = marks(1)[1]
    t.eq(m.virt_text_pos, "right_align")
    t.eq(m.virt_text[1][1], "3 days")
    t.eq(hl(m.virt_text[1][2]).fg, 0xff0000)
  end,

  ["a file a mode makes read-only takes its keys, and is edited again after"] = function(t)
    local path = t.open("view.org", "* A\n| a |\n")
    t.eval(VIEW_MODE)
    t.command("nvbt-view-mode")
    t.eq({ vim.bo.modifiable, mirror.state[api.nvim_get_current_buf()].kind }, { false, "menu" })
    t.feed("q")
    t.eq(t.eval([[(buffer-local-value 'nvbt-view-mode (get-file-buffer "]] .. path .. [["))]]), "nil")
    t.eq({ vim.bo.modifiable, mirror.state[api.nvim_get_current_buf()].kind }, { true, "edit" })
    -- Typed in a table, so through Emacs: once, not once per mode change.
    t.cursor(2, 2)
    t.feed("ix<Esc>")
    mirror.sync()
    t.eq(t.lines(), { "* A", "| xa |" })
    t.eq(t.emacs_lines(path), t.lines())
  end,

  -- Emacs visits a file Neovim doesn't mirror read-only for a command;
  -- one that shows it (magit-blame does) has Neovim mirror it.
  ["a .txt file a command shows stays editable"] = function(t)
    t.open("plain.txt", "text\n")
    t.eval([[(defun nvbt-show () (interactive) (set-window-buffer nil (current-buffer)))]])
    t.command("nvbt-show")
    t.eq({ mirror.state[api.nvim_get_current_buf()] ~= nil, vim.bo.modifiable }, { true, true })
    t.eq(vim.fn.maparg("<C-c>", "n"), "", "C-c is Vim's")
  end,

  -- As blame from a .txt (:Emacs C-c M-g b): Emacs visits the file
  -- Neovim shows, and the mode makes it read-only.
  ["a .txt file a mode makes read-only takes its keys, and is edited again after"] = function(t)
    t.open("view.txt", "text\n")
    t.eval(VIEW_MODE)
    t.eval([[(defun nvbt-view-here () (interactive) (set-window-buffer nil (current-buffer)) (nvbt-view-mode))]])
    t.command("nvbt-view-here")
    local st = mirror.state[api.nvim_get_current_buf()]
    t.eq({ vim.bo.modifiable, st.kind }, { false, "menu" })
    t.feed("q")
    t.eq({ vim.bo.modifiable, st.kind }, { true, "edit" })
  end,

  ["a .txt file a command shows keeps its unsaved changes"] = function(t)
    t.open("shown.org", "* A\n")
    vim.cmd("split")
    t.open("unsaved.txt", "text\n")
    api.nvim_buf_set_lines(0, 0, -1, false, { "typed" })
    local txt = api.nvim_get_current_buf()
    vim.cmd("wincmd j")
    -- Any command: the .txt's window is in Emacs's layout, so shown.
    t.command("ignore")
    t.eq({ mirror.state[txt] ~= nil, t.lines(txt), vim.bo[txt].modified }, { true, { "typed" }, true })
  end,

  -- As smerge-mode in a conflicted file Magit visits: C-c ^ u keeps
  -- "upper" and the mode turns itself off with no conflict left.
  ["C-c goes to Emacs in a .txt file while a minor mode binds keys under it"] = function(t)
    local path = t.file("merge.txt", "<<<<<<< a\nupper\n=======\nlower\n>>>>>>> b\n")
    t.open("merge_from.org", "* A\n")
    t.eval(([[(progn
      (define-minor-mode nvbt-merge-mode "C-c ^ u keeps the upper side."
        :keymap `((,(kbd "C-c ^ u") . ,(lambda () (interactive)
                                          (erase-buffer) (insert "upper\n") (nvbt-merge-mode -1)))))
      (defun nvbt-merge () (interactive) (find-file %q) (nvbt-merge-mode)))]]):format(path))
    t.command("nvbt-merge")
    t.eq(api.nvim_buf_get_name(0), path)
    t.answer("^", "u")
    t.feed("<C-c>")
    t.eq(t.lines(), { "upper" })
    t.eq(vim.fn.maparg("<C-c>", "n"), "", "C-c is Vim's again")
  end,

  -- Emacs after startup: TERM=dumb for subprocesses, so git doesn't color
  -- the errors Magit reads ("! [rejected]").
  ["a subprocess sees TERM=dumb"] = function(t)
    t.eq(t.eval([[(shell-command-to-string "printf %s \"$TERM\"")]]), [["dumb"]])
  end,
}
