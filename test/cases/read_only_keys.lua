-- Keys in a read-only Emacs buffer with prefix keys and evil, as Magit has
-- under evil-collection (the README's Magit setup): a tiny mode stands in.
-- Expected: what the same keys do in Magit there.

-- nvbk-mode binds g r under a prefix, and s and y (the agenda's year view),
-- which record the region. With evil, it also gets what the bridge reads
-- from evil: evil-local-mode, and evil's global maps binding g g and V.
local MODE = [[
(progn
  (defvar nvbk-ran nil)
  (defun nvbk-stage () (interactive)
    (push (if (region-active-p) (list (region-beginning) (region-end)) 'stage) nvbk-ran))
  (defun nvbk-refresh () (interactive) (push 'refresh nvbk-ran))
  (defun nvbk-first () (interactive) (push 'first nvbk-ran) (goto-char (point-min)))
  (defun nvbk-visual () (interactive) (push 'visual nvbk-ran))
  (defvar nvbk-vim-map (define-keymap "g g" #'nvbk-first "V" #'nvbk-visual))
  (defvar-keymap nvbk-mode-map
    "s" #'nvbk-stage "y" #'nvbk-stage "g r" #'nvbk-refresh "g g" #'nvbk-first "V" #'nvbk-visual)
  (define-derived-mode nvbk-mode special-mode "Nvbk")
  (defvar nvbk-evil nil)
  (defun nvbk-open ()
    (interactive)
    (pop-to-buffer-same-window (get-buffer-create "*nvbk*"))
    (let ((inhibit-read-only t)) (erase-buffer) (insert "one\ntwo\nthree\nfour\n"))
    (nvbk-mode)
    (goto-char (point-min))
    (when nvbk-evil
      (setq-local evil-local-mode t
                  evil-global-keymaps-alist '((nvbk-vim . nvbk-vim-map))))
    (setq nvbk-ran nil)))]]

local function open(t, evil)
  t.open("keys.org", "* A\n")
  t.eval(MODE)
  t.eval(("(setq nvbk-evil %s)"):format(evil and "t" or "nil"))
  t.command("nvbk-open")
  t.eq(vim.fn.bufname(), "emacs://*nvbk*")
end

local function ran(t) return t.eval("(reverse nvbk-ran)") end

return {
  ["a key under a prefix goes to Emacs; the prefix's other keys stay Neovim's"] = function(t)
    open(t, false)
    t.feed("gj")
    t.eq({ vim.fn.line("."), ran(t) }, { 2, "nil" }, "g j is unbound in Emacs")
    t.feed("gr")
    t.eq(ran(t), "(refresh)")
  end,

  ["keys evil binds as Vim does stay Neovim's"] = function(t)
    open(t, true)
    t.feed("Ggg")
    t.eq({ vim.fn.line("."), ran(t) }, { 1, "nil" })
    t.feed("V<Esc>")
    t.eq(ran(t), "nil", "V is Neovim's Visual mode")
    t.feed("gr")
    t.eq(ran(t), "(refresh)")
  end,

  ["under evil, a key in Visual mode acts on the selected lines"] = function(t)
    open(t, true)
    t.feed("jVjs")
    -- Up to the end of "three", as evil's V s would: not "four" too.
    t.eq(ran(t), "((5 14))")
  end,

  ["without evil, Visual mode keeps the keys Emacs binds (the agenda's y)"] = function(t)
    open(t, false)
    t.feed("vy")
    t.eq({ vim.fn.getreg('"'), ran(t) }, { "o", "nil" })
  end,

  -- Needs evil on Emacs's load-path (EMACSLOADPATH).
  ["evil's own keys stay Neovim's, with real evil"] = function(t)
    if t.eval("(require 'evil nil t)") == "nil" then t.skip("evil is not installed") end
    open(t, false)
    t.eval([[(with-current-buffer "*nvbk*"
      (evil-define-key 'normal nvbk-mode-map "s" #'nvbk-stage "gr" #'nvbk-refresh)
      (evil-local-mode 1))]])
    t.eq(t.eval([[(with-current-buffer "*nvbk*"
      (let ((keys (nvb--bound-keys (current-buffer))))
        (seq-filter (lambda (k) (seq-contains-p keys k)) '("s" "gr" "gg" "j" "$" "v" "V"))))]]),
      '("s" "gr")')
  end,
}
