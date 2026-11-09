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

5. A key typed just as Emacs changes on its own (a commit message
   opening) is dropped: Emacs refuses a command sent with windows from
   before the change (`nvb--unpulled`), and Neovim shows the change
   instead. Emacs notices such changes up to 0.2 s late
   (`nvb--idle-check-seconds`), and they act on the windows of the tab
   page the last command ran in, even from another tab.

`make fuzz SEED=n STEPS=n` checks text consistency under random edits;
`make soak SEED=n STEPS=n` runs a longer session over files, agenda and
capture, logging time and resource use per 100 steps.
