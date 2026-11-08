;;; Test configuration loaded by the headless Emacs.  -*- lexical-binding: t -*-
(require 'org)
;; Tests must not write into the user's ~/.emacs.d or ~/.cache.
(setq bookmark-default-file (make-temp-file "nvb-bookmarks")
      org-persist-directory (make-temp-file "nvb-org-persist" t)
      org-id-locations-file (make-temp-file "nvb-org-id")
      auto-save-list-file-prefix nil
      org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d)"))
      org-startup-folded nil
      org-agenda-window-setup 'reorganize-frame
      org-capture-templates '(("t" "Task" entry (file "inbox.org") "* TODO %?")))
