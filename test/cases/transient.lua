-- Transient menus (Magit's popups), with Emacs's own transient.el: the
-- menu shows as a float and the keys typed go to it until it closes.
-- Expected: the same keys in `emacs -Q -nw -l test/init.el`.
local api = vim.api

local MENU = [[
(progn
  (require 'transient)
  (defvar nvbt-args :unset)
  (transient-define-suffix nvbt-run (args)
    (interactive (list (transient-args 'nvbt-menu)))
    (setq nvbt-args args))
  (transient-define-suffix nvbt-open ()
    (interactive)
    (pop-to-buffer-same-window (get-buffer-create "nvbt-log")))
  (transient-define-suffix nvbt-fail ()
    (interactive)
    (error "Boom"))
  (transient-define-prefix nvbt-menu ()
    ["Arguments" ("-a" "All" "--all") ("-e" "Empty" "--allow-empty") ("-m" "Message" "--msg=")]
    ["Actions" ("c" "Run" nvbt-run) ("l" "Log" nvbt-open) ("x" "Fail" nvbt-fail)])
  (setq nvbt-args :unset))]]

local function open_menu(t)
  t.open("tr.org", "* A\n")
  t.eval(MENU)
end

local function prompts(t)
  return vim.tbl_map(function(a) return a.params.prompt end, t.asked())
end

-- Neovim's and Emacs's window counts, and the open transient (nil).
local function after_menu(t)
  return { #api.nvim_list_wins(), t.eval("(length (window-list))"), t.eval("transient--prefix") }
end

-- Faces on the menu line holding `needle`, as "text=face".
local function faces_on(p, needle)
  local lines = vim.split(p.context, "\n", { plain = true })
  local out = {}
  for _, s in ipairs(p.context_spans) do
    if lines[s[1] + 1]:find(needle, 1, true) then out[#out + 1] = lines[s[1] + 1]:sub(s[2] + 1, s[3]) .. "=" .. s[4] end
  end
  return out
end

return {
  -- "-" is put back for transient to read "-a" under its own keymap; "e"
  -- alone would be another suffix (Magit's c -e amends HEAD).
  ["-a toggles a switch, shown highlighted in the menu"] = function(t)
    open_menu(t)
    t.answer("-", "a", "c")
    t.command("nvbt-menu")
    t.eq(prompts(t), { "", "--", "" }, "prompts")
    assert(t.asked()[1].params.context:find("-a All (--all)", 1, true), t.asked()[1].params.context)
    t.eq(faces_on(t.asked()[3].params, "(--all)"), { "-a=transient-key", "--all=transient-argument" }, "--all on")
    t.eq(t.eval("nvbt-args"), [[("--all")]], "suffix's args")
    t.eq(after_menu(t), { 1, "1", "nil" }, "windows, menu")
  end,

  -- Transient replaces org's self-insert in pre-command-hook.
  ["q in the menu is an unbound suffix, not org's q"] = function(t)
    open_menu(t)
    t.answer("q", "C-g")
    t.command("nvbt-menu")
    assert(prompts(t)[2]:find("Unbound suffix: ‘q’", 1, true), prompts(t)[2])
    t.eq(t.lines(), { "* A" }, "text")
    t.eq(after_menu(t), { 1, "1", "nil" }, "windows, menu")
  end,

  -- Transient takes its keymap back in minibuffer-exit-hook.
  ["an option's value is read, then the menu reads the next key"] = function(t)
    open_menu(t)
    t.answer("-", "m", "hello", "c")
    t.command("nvbt-menu")
    t.eq(t.eval("nvbt-args"), [[("--msg=hello")]], "suffix's args")
    t.eq(after_menu(t), { 1, "1", "nil" }, "windows, menu")
  end,

  -- The command loop runs post-command-hook after an error; transient exits there.
  ["a suffix's error closes its menu, and the next menu still opens"] = function(t)
    open_menu(t)
    t.answer("x")
    t.command("nvbt-menu")
    t.eq(after_menu(t), { 1, "1", "nil" }, "windows, menu after the error")
    t.answer("c")
    t.command("nvbt-menu")
    t.eq(t.eval("nvbt-args"), "nil", "the second menu's suffix ran")
  end,

  ["Escape closes the menu"] = function(t)
    open_menu(t)
    t.answer(t.QUIT)
    t.command("nvbt-menu")
    t.eq(#t.asked(), 1, "keys read")
    t.eq(after_menu(t), { 1, "1", "nil" }, "windows, menu")
    t.eq(t.eval("nvbt-args"), ":unset", "no suffix ran")
  end,

  ["a suffix's buffer replaces the menu's window, no split"] = function(t)
    open_menu(t)
    t.answer("l")
    t.command("nvbt-menu")
    t.eq(after_menu(t), { 1, "1", "nil" }, "windows, menu")
    t.eq(api.nvim_buf_get_name(0):match("nvbt%-log$"), "nvbt-log", "current buffer")
  end,
}
