;;; Org settings for the demo.  -*- lexical-binding: t -*-
(require 'org)
(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (setq org-directory dir
        org-agenda-files (list (expand-file-name "notes.org" dir))
        org-capture-templates
        `(("t" "Task" entry (file ,(expand-file-name "inbox.org" dir)) "* TODO %?"))
        org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d)"))))
