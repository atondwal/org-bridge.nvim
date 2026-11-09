# org-bridge.nvim

Org-mode in Neovim, run by a real Emacs. A headless Emacs keeps a copy of each
org buffer. You edit text in Neovim as usual. Org keys (TAB, `C-c C-t`, `M-RET`,
the agenda, capture...) run in Emacs, and the results come back as Neovim text,
folds and highlights.

## Setup

Requires Neovim 0.9+ (0.13 recommended) and Emacs 29+ on `PATH`.

```lua
-- lazy.nvim
{ "atondwal/org-bridge.nvim", config = function()
  require("emacs").setup({
    init = "~/.config/nvim/emacs-init.el",  -- your org settings (optional)
  })
end }
```

```vim
" vim-plug, in init.vim
Plug 'atondwal/org-bridge.nvim'
" ...after call plug#end():
lua require("emacs").setup()
```

To try it without touching your config: clone the repo and run `make demo`.

`setup()` is what maps the org keys; without it only the `:Emacs*` commands
exist. Remove other org plugins (vim-orgmode, nvim-orgmode) and global
mappings that start with an org key (`nmap <C-c><C-c> ...`): typed fast,
those win over the org buffer's keys. `:checkhealth emacs` lists them.

`init` is loaded into the headless Emacs before it starts serving. Put
`org-agenda-files`, `org-capture-templates`, `org-todo-keywords`,
`org-babel-load-languages` and so on there, and the global keys you use in
Emacs, e.g. `(global-set-key (kbd "C-c a") #'org-agenda)`. Emacs starts with
`-Q`, so packages from ELPA need `(package-initialize)` first. If `init`
fails, Neovim reports the error and the bridge runs without it.

Link brackets are hidden, as in Emacs, on Neovim 0.13+. Older versions wrap
a line at its unconcealed width (fixed by neovim#40897), so there `conceal`
defaults to false. Set `conceal = true` to hide them anyway, which is fine
with `nowrap`.

## Use

Open an `.org` file. In normal mode these keys go to Emacs: `<Tab>`, `<S-Tab>`,
`<M-CR>`, `<C-CR>`, `<S-CR>`, `<M-S-CR>`, `<C-S-CR>`, `<M-arrows>`,
`<M-S-arrows>`, `<S-arrows>`, `<C-S-arrows>` and `<M-x>`, plus anything starting with `<C-c>`
(Emacs asks for the rest of the sequence). A file of another type that Emacs
opens (a link to a `.txt`) stays in sync with Emacs but keeps Neovim's keys,
unless Emacs edits it for `emacsclient` (Magit's commit message). A file
Emacs makes read-only (`view-mode`, Magit's blame) is read-only in Neovim
too, and takes keys as the agenda does (below) until Emacs makes it
writable again.

Emacs's point is *between* characters; Neovim's Normal-mode cursor is *on*
one. Point goes just before the character under the cursor, so a command
that inserts (`C-c .`, `C-c C-l`) inserts there. The exception: with the
cursor on the last character, `<M-CR>` and friends act at the end of the
line, and since you then want to type the new heading, they leave you in
Insert mode.

Insert mode forwards `<Tab>`, `<S-Tab>`, the `<CR>` variants, `<M-arrows>`,
`<C-c>` and `<M-Tab>` (completion: `#+` keywords, `\` entities). Plain `<CR>` is org's RET everywhere (the next table row, tags
stay on the heading, `org-return-follows-link`, item bodies indented), and
Normal-mode `o` is `C-e RET`. Characters typed on table rows go through
Emacs too, so columns stay aligned. On headings Vim inserts the text (so
`.` and counts repeat it) and Emacs realigns the tags when you leave Insert
mode; with `org-use-speed-commands`, keys at a heading's start are speed
commands. Visual mode forwards `<C-c>`,
`<M-x>` and the M-arrows with the selection as the region; a region a command
leaves active (`C-c @`) becomes a Visual selection.

A count becomes a prefix argument, and 4/16/64 act like `C-u`/`C-u C-u`/`C-u
C-u C-u`. `<C-u>` itself works too when an Emacs key follows within
`timeoutlen` (`<C-u><C-c><C-c>`); it scrolls at once, and the scroll is undone
if an Emacs key follows. The fold keys
(`zo zc za zR zM ...`) drive org's folding, `gq` fills with org's
paragraph fill and `=` indents with org (a src block by its language).
With `textwidth` set, typing wraps by org's auto-fill: at the space after a
word, never inside a timestamp or a fixed-width line.

Dates: `C-c .` inserts a timestamp, `C-c C-s` schedules, `C-c C-d` sets a
deadline. As in org, you type the answer (`+3`, `fri`, `2pm`,
`2026-12-01 10:00`) and a calendar previews it. org's prompt keys work:
`S-left`/`S-right` a day, `S-up`/`S-down` a week, `M-S-left`/`M-S-right` a
month, `M-S-up`/`M-S-down` a year, `.` (at the start) today, `<`/`>` and
`M-v`/`C-v` scroll the calendar. `C-o` browses the calendar instead: `h`/`l`
a day, `j`/`k` a week, `H`/`L` a month, `t` today, Enter picks, Esc goes
back to typing. On a timestamp in the text, `S-up`/`S-down` change the part
under the cursor and `S-left`/`S-right` move it a day.

`.` repeats the last org key that changed the text, with the same menu
answer (`C-c C-t` then `t`, then `.` on another heading), and `.` after
`o` opens another line and types the same keys (Neovim 0.10+); with
vim-repeat installed, its `.` does.

Org text objects: `ar` is a subtree (heading, body and children), `ir` the
same without its heading; `ae` is the org element at the cursor (a
paragraph, list, table, block or drawer), `ie` its contents (a src block's
code). So `dar` deletes a subtree, `yar` copies one, `cie` replaces a
block's code. Vim's `ip`/`ap` still stop only at blank lines, which org
files rarely have between headings.

| Command | Does |
|---|---|
| `:Emacs C-c C-x C-i` | run any key sequence |
| `:EmacsCommand org-refile` | run any command |
| `:EmacsAgenda`, `:EmacsCapture` | the agenda / capture dispatchers |
| `:EmacsEval (expr)` | evaluate Elisp |
| `:EmacsRestart` | restart Emacs and re-attach open org buffers |
| `:EmacsLog` | Emacs's stderr and the bridge log |

Read-only Emacs buffers such as the agenda open in a split. There, and in
column view, every printable key Emacs binds goes to Emacs (`g`, `$`, `/`,
`l` are agenda commands), except `j`, `k`, `g`, `G` (so `gg`, `G` and `19G`
move; `r` rebuilds) and `:`. Under a prefix key, the two-key sequences
Emacs binds go to Emacs too (`gr`). Keys Emacs doesn't bind stay Neovim's, and digits stay counts
unless Emacs gives them a command (column view's "pick the Nth value"). Emacs's menus (fast TODO selection, the
agenda and export dispatchers) appear in a float while it waits for a key.

Colors: org's faces follow your colorscheme (`faces` maps them to Neovim
groups), and other faces get Emacs's colors for your `background`. A face
you customize in Emacs (`set-face-attribute`, a theme) keeps Emacs's
colors; `:hi EmacsFace_org_todo ...` (dashes become underscores) overrides
either.

For a running org clock in your statusline, add the component (it is empty
when no clock runs, and in the agenda it also shows the agenda's modes, like
`Week Log Follow`), e.g. to the default statusline:

```lua
vim.o.statusline = "%<%f %h%m%r %{v:lua.require'emacs'.statusline()}%=%-14.(%l,%c%V%) %P"
```

With lualine, add `require("emacs").statusline` to a section. Quitting
Neovim while a clock runs offers to clock out first.

Neovim does all file writes. When Emacs saves (capture, `org-save-all-org-buffers`),
the save goes through `:write`. Either way Emacs then runs `after-save-hook`,
so saving a file with its conflicts resolved stages it, as in Emacs.

What Emacs does on its own between commands (a timer, a process finishing,
a file `emacsclient` opens) shows up in Neovim by itself, once you are in
Normal mode.

## Magit

Magit isn't a dependency, but works when your `init` loads it.
`:EmacsCommand magit-status` opens the status of the current file's
repository (from a buffer with no file, `:pwd`'s) in a split, where
Magit's keys go to Emacs. Its menus (`c`, `l`, `b`: transients) show in a
float, and the keys you type go to the menu until a key closes it, as in
Emacs: `-a` toggles a switch, `c` runs a command, `q` says "Unbound
suffix", `<C-g>` or `<Esc>` closes it. The status refreshes by itself when
git finishes. When git asks for a username or password, `<Esc>` or `<C-g>`
at the prompt stops git, as `C-g` does in Emacs. `c c` opens the commit message below the diff: type it in
Neovim, then `<C-c><C-c>` commits and `<C-c><C-k>` cancels. The log's
author and date, which Magit draws in the right margin, show at the
window's right edge; blame's headings are lines above each chunk.

For Vim keys, turn on evil in Magit buffers only, with evil-collection's
bindings. Neovim keeps the keys evil binds as Vim does (`gg`, `v`, `$`)
and sends the rest to Magit: `s`, `u` and `x` stage, unstage and discard,
`gr` refreshes, `Z` stashes and `zo`/`zc`/`za` fold sections. In Visual
mode they act on the selected lines. Add to your `init`:

```elisp
;; Set before evil and evil-collection load: they read these then.
(setq evil-want-keybinding nil                   ; evil-collection binds the keys
      evil-collection-want-unimpaired-p nil      ; no global [ and ] maps
      evil-collection-magit-use-z-for-folds t)   ; zo/zc/za/z1..z4 on sections, stash on Z
(require 'evil)
(require 'magit)
(require 'evil-collection)
(evil-collection-init '(magit))
(add-hook 'magit-mode-hook #'evil-local-mode)
;; Digits stay counts (2j); z1..z4 show levels instead.
(dolist (key '("1" "2" "3" "4"))
  (keymap-unset magit-section-mode-map key t))
```

Without evil, Magit's own keys apply (`v` and `V` revert, so Visual mode
can't start there).

## Options

`setup()` takes: `init` (Elisp file), `emacs` (executable), `log` (file),
`conceal` (see above), `emacs_typing` (Insert-mode RET, and keys typed on
table rows and as speed commands, go through Emacs; default true), `keys` (per-mode lists of keys forwarded to Emacs),
`passthrough` (keys Neovim keeps in read-only Emacs buffers),
`textobjects` (the letters for subtree and element, default `r` and `e`;
`false` turns one off),
`fold_commands`, `filetypes` (default `{ "org" }`) and `faces` (Emacs face to
Neovim highlight links). See `lua/emacs/mirror.lua` for the defaults.

## Troubleshooting

Other org plugins (vim-orgmode, nvim-orgmode) map the same keys and fold
org buffers their own way; disable them for org files. org-bridge.nvim's
keys win, and it still attaches if one of them fails on opening a file.

In tmux, `set -sg escape-time 10`: the default 500 ms delays every Escape,
so org keys right after `<Esc>` lag.

`:checkhealth emacs` checks Neovim, Emacs, Org and your `init` file (it shows
Emacs's error if `init` fails). `:EmacsLog` shows Emacs's output; start Neovim
with `EMACS_NVIM_DEBUG=1` to log every message between the two.

## Limitations

- Neovim 0.9 has no inline virtual text, so `org-indent-mode` prefixes are
  not drawn.
- Narrowing (`C-x n s`) doesn't hide the rest of the file in Neovim; org
  keys on a line outside the restriction are refused until `C-x n w`.
- A linewise Visual selection is a region of whole lines, newline included,
  as `C-SPC C-n` makes in Emacs (what sorting wants). Item commands
  (`C-c C-x C-b`, `C-c *`, `C-c -`) and keys in read-only buffers (Magit's
  `s`) stop at the end of its last line.
- Raised/scaled text (sub/superscripts with pretty entities) is drawn flat.
- org-goto's outline interface works, but its buffer appears only as a menu;
  the default here is path completion.

## How it works

Neovim starts Emacs in the background and talks to it over a pipe, one JSON
message per line. Neovim owns the files; Emacs keeps a copy of each buffer,
kept in step line by line. A forwarded key runs as an Emacs command, and Emacs
sends back the text it changed, the cursor, folds, faces and any windows it
opened. When something changes between commands, Emacs says so and Neovim
asks for the same report. See `emacs/nvim-bridge.el` (the server) and `lua/emacs/` (the client).

The bridge itself doesn't depend on org. Set `filetypes` to try it on other
major modes; only org is tested.

Run the tests with `make test` (`make test FILTER=tags` for a subset).

## License

GPL-3.0-or-later; see `LICENSE`.
