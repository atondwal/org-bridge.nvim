# Open

Known gaps, roughly by how often a user meets them:

1. Org 9.6 bugs worked around locally, worth reporting upstream:
   `org-fold--reveal-outline-maybe` on a fold with no heading before it
   (`nvb--reveal-outline-maybe`), and the element cache signalling from
   its after-change hook (`nvb--element-cache-after-change`).

2. Tags after a ZWJ emoji sequence (👨‍👩‍👧) align by Emacs's width of it
   (6) rather than Neovim's (2): org's tag alignment uses `current-column`.

3. `.` and counts don't repeat text typed on table rows (those keys go
   through Emacs, so Vim's redo register stays empty). On Neovim 0.9,
   `.` after `o` appends the text instead of opening a line (on_key has
   no typed keys there).

4. `C-v` in a long dispatcher menu (`C-c C-a`) ends the command with "End
   of buffer". In Emacs the menu window fits the whole menu, so org-scroll
   finds its end visible and reads another key. In batch,
   `pos-visible-in-window-p` is always nil, the menu window is shorter
   than the menu (17 of ~30 lines), and `scroll-up` signals. Judging
   visibility by lines alone is not enough; the window must fit the menu.

5. A transient menu shows only if it pops up a window when the command
   ends (`transient-show-popup` t, the default); with nil or a delay its
   keymap is active but Neovim doesn't send it keys. While a menu is up,
   Neovim's buffers aren't updated, so a suffix that keeps the menu open
   shows its changes only when the menu closes.

`make fuzz SEED=n STEPS=n` checks text consistency under random edits;
`make soak SEED=n STEPS=n` runs a longer session over files, agenda and
capture, logging time and resource use per 100 steps.
