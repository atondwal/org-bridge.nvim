-- What Magit draws and does in a file's buffer, reproduced without Magit:
-- blame's headings (overlay strings in `font-lock-face'), the log's dates
-- (margin strings), blame's read-only mode with its own keys.
-- Expected: the same in `emacs -Q -nw -l test/init.el`.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")

local FACES = [[(progn
  (defface nvbt-heading '((t :background "#404040")) "")
  (defface nvbt-hash '((t :foreground "#ff0000")) ""))]]

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

  -- As magit-blame-read-only-mode: q in its keymap leaves it, and with it
  -- read-only.
  ["a file a mode makes read-only takes its keys, and is edited again after"] = function(t)
    local path = t.open("view.org", "* A\n| a |\n")
    t.eval([[(define-minor-mode nvbt-view-mode "Read-only with q to leave."
      :keymap `((,(kbd "q") . ,(lambda () (interactive) (nvbt-view-mode -1))))
      (setq buffer-read-only nvbt-view-mode))]])
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
  end,
}
