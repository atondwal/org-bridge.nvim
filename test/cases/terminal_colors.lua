-- Terminal color modes: cterm colors on EmacsFace_* groups, 'background'
-- light vs dark, :colorscheme changes, user :hi overrides, inherited and
-- decorated faces, org-block. Emacs facts: emacs -Q --batch -l test/init.el.
local api = vim.api
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")

local function agree(t, path)
  mirror.sync()
  t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees")
end

local function hl(group) return api.nvim_get_hl(0, { name = group, link = false }) end

-- The highlight attributes Neovim draws at row:col (0-based), from the
-- highest-priority Emacs extmark there.
local function hl_at(row, col)
  local best
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })) do
    local d = m[4]
    if d.hl_group and m[3] <= col and col < (d.end_col or m[3] + 1)
      and (not best or (d.priority or 0) > (best.priority or 0)) then
      best = d
    end
  end
  assert(best, ("no highlight at %d:%d"):format(row, col))
  return hl(best.hl_group), best.hl_group
end

-- Groups Neovim draws anywhere on row.
local function groups_on(row)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, NS, { row, 0 }, { row, -1 }, { details = true })) do
    if m[4].hl_group then out[m[4].hl_group] = true end
  end
  return out
end

-- Run the rest of the test under `colorscheme`, then go back to default.
local function colorscheme(t, name)
  local bg = vim.o.background
  t.after(function()
    vim.cmd("colorscheme default")
    vim.o.background = bg
  end)
  vim.cmd("colorscheme " .. name)
end

-- Nearest xterm-256 index, computed independently of faces.lua.
local function xterm(color)
  local rgb = api.nvim_get_color_by_name(color)
  local function level(v) return v < 48 and 0 or v < 115 and 1 or math.floor((v - 35) / 40) end
  return 16 + 36 * level(math.floor(rgb / 65536) % 256) + 6 * level(math.floor(rgb / 256) % 256) + level(rgb % 256)
end

-- Restore an Emacs face attribute after the test.
local function keep_face(t, face, attr)
  local old = t.eval(("(prin1-to-string (face-attribute '%s %s))"):format(face, attr))
  t.after(function() t.eval(("(set-face-attribute '%s nil %s (read %s))"):format(face, attr, old)) end)
end

-- A face with light and dark variants and no color class.
local BG_FACE = [[(defface tc-bg-face
  '((((background light)) :background "#8270f9") (((background dark)) :background "blue")) "")]]

return {
  -- With notermguicolors only cterm attributes show: org-todo must carry
  -- DiagnosticError's ctermfg and be bold in cterm too.
  ["notermguicolors: EmacsFace_org_todo has DiagnosticError's ctermfg and cterm bold"] = function(t)
    local tgc = vim.o.termguicolors
    t.after(function() vim.o.termguicolors = tgc end)
    vim.o.termguicolors = false
    local path = t.open("tc_todo.org", "* TODO Task\n")
    local attrs, group = hl_at(0, 2)
    t.eq(group, "EmacsFace_org_todo", "TODO's group")
    t.eq(attrs.ctermfg, hl("DiagnosticError").ctermfg, "ctermfg")
    t.eq(attrs.bold, true, "bold")
    t.eq((attrs.cterm or { bold = true }).bold, true, "cterm bold")
    agree(t, path)
  end,

  -- org-todo-keyword-faces ("CANCELLED" . "gray") is (:inherit org-todo
  -- :foreground "gray") in Emacs; a 256-color Emacs shows it gray, so the
  -- cterm color must follow the face's own gray, not org-todo's red.
  ["notermguicolors: a keyword face inheriting org-todo uses its own color in cterm"] = function(t)
    t.set("org-todo-keywords", [['((sequence "TODO" "|" "DONE" "CANCELLED"))]])
    t.set("org-todo-keyword-faces", [['(("CANCELLED" . "gray"))]])
    local path = t.open("tc_cancel.org", "* CANCELLED Old\n")
    local attrs = hl_at(0, 3)
    t.eq(attrs.fg, api.nvim_get_color_by_name("gray"), "gui fg")
    t.eq(attrs.ctermfg, xterm("gray"), "ctermfg")
    agree(t, path)
  end,

  -- Emacs: BG_FACE is "#8270f9" with frame-background-mode light and
  -- "blue" with dark (the batch frame is dark), as org-habit-clear-face is.
  -- With Neovim's 'background' light, a light Emacs shows the light one.
  ["background=light gives faces Emacs's light variant"] = function(t)
    colorscheme(t, "default")
    vim.o.background = "light"
    t.eval(BG_FACE)
    t.set("org-todo-keyword-faces", [['(("NEXT" . tc-bg-face))]])
    local path = t.open("tc_light.org", "* NEXT Task\n")
    local attrs, group = hl_at(0, 2)
    t.eq(group, "EmacsFace_tc_bg_face", "NEXT's group")
    t.eq(attrs.bg, api.nvim_get_color_by_name("#8270f9"), "light-background color")
    agree(t, path)
  end,

  -- Switching 'background' mid-session reloads the colorscheme (ColorScheme
  -- fires); faces with light/dark variants should switch with it.
  ["switching background to light mid-session switches the face variant"] = function(t)
    colorscheme(t, "default")
    vim.o.background = "dark"
    t.eval(BG_FACE)
    t.set("org-todo-keyword-faces", [['(("NEXT" . tc-bg-face))]])
    local path = t.open("tc_switch.org", "* NEXT Task\n")
    t.eq(hl_at(0, 2).bg, api.nvim_get_color_by_name("blue"), "dark variant first")
    vim.o.background = "light"
    t.command("ignore")
    t.eq(hl_at(0, 2).bg, api.nvim_get_color_by_name("#8270f9"), "light variant after the switch")
    agree(t, path)
  end,

  ["colorscheme change relinks EmacsFace_org_todo to the new DiagnosticError"] = function(t)
    local path = t.open("tc_scheme.org", "* TODO Task\n")
    t.eq(hl_at(0, 2).fg, hl("DiagnosticError").fg, "before")
    colorscheme(t, "blue")
    t.eq(hl("EmacsFace_org_todo").fg, hl("DiagnosticError").fg, "after :colorscheme blue")
    t.eq(hl("EmacsFace_org_todo").ctermfg, hl("DiagnosticError").ctermfg, "ctermfg after")
    t.eq(hl("EmacsFace_org_todo").bold, true, "still bold")
    agree(t, path)
  end,

  -- The usual Vim way to override a plugin's group: :hi in a ColorScheme
  -- autocmd. It must survive both :colorscheme and a face change in Emacs.
  ["a user :hi EmacsFace_org_todo survives :colorscheme and set-face-attribute"] = function(t)
    local path = t.open("tc_user.org", "* TODO Task\n* B\n")
    local aug = api.nvim_create_augroup("tc_user_hi", { clear = true })
    -- :hi clear gives the group back to the plugin for later tests.
    t.after(function()
      api.nvim_del_augroup_by_id(aug)
      vim.cmd("hi clear EmacsFace_org_todo")
    end)
    local function user_hi() vim.cmd("hi EmacsFace_org_todo guifg=#123456 ctermfg=33") end
    api.nvim_create_autocmd("ColorScheme", { group = aug, callback = user_hi })
    user_hi()
    t.command("ignore")
    t.eq(hl_at(0, 2).fg, 0x123456, "after :hi")
    colorscheme(t, "default")
    t.eq(hl("EmacsFace_org_todo").fg, 0x123456, "after :colorscheme")
    keep_face(t, "org-level-1", ":foreground")
    t.eval([[(set-face-attribute 'org-level-1 nil :foreground "red")]])
    -- S-right, not C-c C-t: the test's scripted read_key drops the faces
    -- a fast-selection menu carries, which would hide the redefinition.
    t.cursor(2)
    t.keys("S-<right>")
    t.eq(t.lines()[2], "* TODO B", "S-right")
    t.eq(hl("EmacsFace_org_todo").fg, 0x123456, "after set-face-attribute in Emacs")
    t.eq(hl("EmacsFace_org_todo").ctermfg, 33, "ctermfg after set-face-attribute")
    agree(t, path)
  end,

  -- Emacs: after (set-face-attribute 'org-todo nil :foreground "purple"),
  -- (face-attribute 'org-todo :foreground) is "purple" and TODO is drawn
  -- purple. The face itself now names a color, which faces.lua says wins.
  ["set-face-attribute on org-todo recolors TODO in Neovim"] = function(t)
    local path = t.open("tc_purple.org", "* TODO Task\n")
    keep_face(t, "org-todo", ":foreground")
    t.eval([[(set-face-attribute 'org-todo nil :foreground "purple")]])
    t.eq(t.eval("(face-attribute 'org-todo :foreground)"), '"purple"', "Emacs's face")
    t.command("ignore")
    t.eq(hl_at(0, 2).fg, api.nvim_get_color_by_name("purple"), "TODO fg in Neovim")
    agree(t, path)
  end,

  -- A face defined the usual way, with a (class color) spec, as themes and
  -- packages do. The batch frame has no color class, so Emacs here resolves
  -- its :foreground to unspecified; a color Emacs (GUI or tty) shows green.
  ["a (class color) defface still shows its color"] = function(t)
    t.eval([[(defface tc-next-face '((((class color) (min-colors 88)) :foreground "green") (t :weight bold)) "")]])
    t.set("org-todo-keyword-faces", [['(("NEXT" . tc-next-face))]])
    local path = t.open("tc_class.org", "* NEXT Task\n")
    t.eq(hl_at(0, 2).fg, api.nvim_get_color_by_name("green"), "NEXT fg")
    agree(t, path)
  end,

  -- (:inherit org-todo :weight normal :strike-through t
  --  :underline (:style wave)): Emacs draws it not bold, struck through,
  -- with a wavy underline.
  ["inherit chain with weight override, strike-through and wave underline"] = function(t)
    t.set("org-todo-keywords", [['((sequence "TODO" "|" "DONE" "DROP"))]])
    t.set("org-todo-keyword-faces",
      [['(("DROP" . (:inherit org-todo :weight normal :strike-through t :underline (:style wave))))]])
    local path = t.open("tc_drop.org", "* DROP Old\n")
    local attrs = hl_at(0, 2)
    t.eq(attrs.strikethrough, true, "strike-through")
    t.eq({ bold = attrs.bold, undercurl = attrs.undercurl }, { undercurl = true }, "weight normal, wavy underline")
    agree(t, path)
  end,

  -- Emacs: with org-src-fontify-natively (default t), src block lines carry
  -- org-block; a user's (set-face-attribute 'org-block nil :background
  -- "#eeeeee") paints them, as in many org configs.
  ["org-block background set in Emacs paints src block lines"] = function(t)
    keep_face(t, "org-block", ":background")
    t.eval([[(set-face-attribute 'org-block nil :background "#eeeeee")]])
    local path = t.open("tc_block.org", "#+begin_src emacs-lisp\n(setq x 1)\n#+end_src\n")
    t.eq(t.eval([[(with-current-buffer "tc_block.org" (goto-char (point-min)) (forward-line 1)
      (and (memq 'org-block (ensure-list (get-text-property (point) 'face))) t))]]), "t", "Emacs: org-block on line 2")
    assert(groups_on(1).EmacsFace_org_block, "org-block on line 2 in Neovim: " .. vim.inspect(groups_on(1)))
    t.eq(hl("EmacsFace_org_block").bg, 0xeeeeee, "org-block background")
    agree(t, path)
  end,
}
