;;; nvim-bridge.el --- Serve a headless Emacs to a Neovim front end  -*- lexical-binding: t -*-

;; Neovim owns files and the screen; Emacs owns buffer semantics (org-mode
;; commands, folding, faces). They talk over a unix socket in JSON lines:
;;
;;   request   {"id": N, "method": M, "params": P}
;;   response  {"id": N, "result": R} or {"id": N, "error": "msg"}
;;
;; Either side may send requests: Neovim runs commands; Emacs asks Neovim
;; for user input (keys, strings, completions) while a command runs.
;; Method M runs `nvb-rpc-M' (see "RPC methods" below); the client is
;; lua/emacs/rpc.lua.

(require 'cl-lib)
(require 'subr-x)
(require 'calendar)

;; The bridge works by advising Emacs's input primitives. Load .elc rather
;; than a user eln-cache's native org, so org's behavior doesn't depend on
;; what happens to be compiled. This must run before the user's init loads
;; org, so it is top level here, not in `nvb-install'.
(setq load-no-native t)
;; Emacs's own preloaded Lisp is native code too (read-regexp, y-or-n-p's
;; helpers), so advised primitives need trampolines, which native callers
;; go through. Keep them in the bridge's own cache, and compile nothing else.
;; Emacs looks for compiled ones only under a version directory of
;; `native-comp-eln-load-path', so write them there too, or every start
;; compiles them again.
(when (boundp 'native-comp-enable-subr-trampolines)
  (let ((dir (expand-file-name "org-bridge.nvim/trampolines/"
                               (or (getenv "XDG_CACHE_HOME") "~/.cache"))))
    (make-directory (expand-file-name comp-native-version-dir dir) t)
    (push dir native-comp-eln-load-path)
    (setq native-comp-enable-subr-trampolines (expand-file-name comp-native-version-dir dir)
          native-comp-jit-compilation nil)))

(defvar nvb--conn nil "Process for the connected Neovim client.")
(defvar nvb--chunks nil "Input from the client after its last newline, newest first.")
(defvar nvb--inbox nil "Requests from Neovim not yet handled, oldest first.")
(defvar nvb--replies (make-hash-table) "Replies to our requests, by id.")
(defvar nvb--next-id 0)
(defconst nvb--max-candidates 10000
  "Most completion candidates sent to Neovim in one message.")
(defvar nvb--completion nil
  "(COLLECTION . PREDICATE) of the `completing-read' waiting on Neovim.")

(defvar nvb--pending-keys nil
  "Keys (kbd strings) given ahead of a command, consumed by its key reads:
`:Emacs C-c a w' or `:EmacsAgenda w' answer the dispatcher with w.")

(defvar nvb--in-request nil "Non-nil while serving a request from Neovim.")

(defvar nvb--messages nil
  "Echo-area messages from the current request, newest first.
Bound per request in `nvb--handle'.")

;; Org's variables, declared so the code below binds and reads them
;; dynamically (and compiles cleanly) before org loads.
(defvar org-read-date-popup-calendar)
(defvar org-ellipsis)
(defvar org-agenda-tags-column)
(defvar org-goto-interface)
(defvar org-drawer-regexp)
(defvar org-def)
(defvar org-defdecode)
(defvar org-ans1)
(defvar org-ans2)
(defvar org-with-time)
(defvar org-read-date-inactive)
(defvar org-time-was-given)
(defvar org-end-time-was-given)
(defvar org-read-date-analyze-futurep)
(declare-function org-read-date-analyze "org")
(declare-function org-time-stamp-format "org")
(declare-function org-encode-time "org-macs")
(declare-function org-fold-region "org-fold")
(declare-function org-element-at-point "org-element")
(declare-function org-element-property "org-element")
(declare-function org-element-type "org-element")
(declare-function org-end-of-subtree "org")
(declare-function org-back-to-heading "org")
(declare-function org-align-tags "org")
(declare-function org-element-cache-reset "org-element")
(declare-function org-fold-show-entry "org-fold")
(declare-function org-fold-show-children "org-fold")
(declare-function org-fold-hide-subtree "org-fold")
(declare-function org-fold-folded-p "org-fold")
(declare-function org-id-locations-save "org-id")
(declare-function org-fold-hide-drawer-toggle "org-fold")

;;; Transport

(defun nvb--send (obj)
  (process-send-string nvb--conn (concat (json-serialize obj :null-object nil :false-object :false) "\n")))

(defun nvb--bool (x)
  "X as a JSON boolean: nil would go out as null, which Lua reads as true."
  (if x t :false))

(defun nvb--filter (_proc chunk)
  ;; Join chunks only at a newline: concatenating every chunk onto the
  ;; pending text is quadratic for the megabyte buffers Neovim sends.
  (if (not (string-search "\n" chunk))
      (push chunk nvb--chunks)
    (let ((lines (split-string (apply #'concat (nreverse (cons chunk nvb--chunks))) "\n")))
      (setq nvb--chunks (list (car (last lines))))
      (dolist (line (butlast lines))
        (unless (string-empty-p line)
          (condition-case err
              (let* ((msg (json-parse-string line :object-type 'plist :null-object nil
                                             :false-object nil :array-type 'list))
                     (method (plist-get msg :method)))
                (if method
                    (setq nvb--inbox (nconc nvb--inbox (list msg)))
                  (puthash (plist-get msg :id) msg nvb--replies)))
            ;; Neovim checks text is UTF-8 before sending (check_utf8 in
            ;; mirror.lua); a bad line that gets past it must not kill the server.
            (json-error
             (princ (format "nvim-bridge: dropped bad message: %S\n" err)
                    #'external-debugging-output))))))))

(defun nvb--request (method params)
  "Ask Neovim METHOD with PARAMS and wait for the answer.
A `quit' answer (the user pressed Escape) signals `quit'."
  (let ((id (cl-incf nvb--next-id)))
    (nvb--send (list :id id :method method :params params))
    (while (not (gethash id nvb--replies))
      (unless (process-live-p nvb--conn) (kill-emacs 0))
      (accept-process-output nvb--conn 0.05)
      ;; Neovim may call us while answering (e.g. completions for a prompt,
      ;; or loading a buffer to save it); serve those calls now.
      (while nvb--inbox
        (nvb--handle (pop nvb--inbox))))
    (let ((reply (gethash id nvb--replies)))
      (remhash id nvb--replies)
      (when (plist-get reply :error)
        (if (equal (plist-get reply :error) "quit")
            (signal 'quit nil)
          (error "Neovim: %s" (plist-get reply :error))))
      (plist-get reply :result))))

(defun nvb--handle (msg)
  (let ((id (plist-get msg :id))
        (handler (intern-soft (concat "nvb-rpc-" (plist-get msg :method)))))
    (condition-case err
        (let ((result (if (fboundp handler)
                          ;; Each request reports only its own echo-area messages,
                          ;; including requests served while another waits in `nvb--request'.
                          (let ((nvb--messages nil)
                                (nvb--in-request t))
                            (funcall handler (plist-get msg :params)))
                        (error "Unknown method %s" (plist-get msg :method)))))
          (when id (nvb--send (list :id id :result result))))
      ;; Handlers run arbitrary Emacs commands; any error or quit goes back
      ;; to Neovim as the reply instead of escaping the server loop.
      ((debug error quit)
       (when id (nvb--send (list :id id :error (error-message-string err))))))))

(defconst nvb--gc-cons-threshold (* 64 1024 1024)
  "Bytes allocated between collections while serving Neovim.")

(defconst nvb--idle-check-seconds 0.2
  "How often idle Emacs looks for changes made outside a request.")

(defvar nvb--unpulled nil
  "Non-nil from telling Neovim its windows changed until it asks for the state.")

(defun nvb--signature ()
  "What Neovim sees of Emacs, cheaply: the windows, their buffers and
points, and each shown or mirrored buffer's text, properties and overlay
count (magit-blame's headings)."
  (cons (mapcar (lambda (w) (list w (window-buffer w) (window-point w) (window-start w)))
                (window-list nil 'never (frame-first-window)))
        (mapcar (lambda (b)
                  (with-current-buffer b
                    (list b (buffer-modified-tick) (length (overlays-in (point-min) (point-max))))))
                (seq-filter #'buffer-live-p
                            (append (nvb--displayed-buffers) (hash-table-values nvb--mirrors))))))

(defun nvb-serve (socket)
  "Listen on SOCKET and serve one Neovim client until it disconnects."
  (when (file-exists-p socket) (delete-file socket))
  ;; Adaptive buffering delays small reads by up to tens of milliseconds.
  (setq process-adaptive-read-buffering nil)
  ;; Each command's report scans the buffer (folds), allocating ~1-3 MB on
  ;; a 20k-line file; at the default threshold a collection (~100 ms with
  ;; several big files loaded) would follow nearly every key.
  (setq gc-cons-threshold nvb--gc-cons-threshold)
  (make-network-process
   :name "nvim-bridge" :server t :family 'local :service socket
   :coding 'utf-8-unix
   :filter #'nvb--filter
   :log (lambda (_server client _msg) (setq nvb--conn client))
   :sentinel (lambda (proc _event)
               (when (and (eq proc nvb--conn) (not (process-live-p proc)))
                 (kill-emacs 0))))
  (princ "READY\n" #'external-debugging-output)
  (while t
    (let ((before (nvb--signature)))
      ;; Waiting on any process adds ~10ms per message; wait on the client.
      (accept-process-output nvb--conn nvb--idle-check-seconds)
      ;; Timers, other processes' output and their sentinels (git exiting
      ;; for Magit, emacsclient opening a commit message) ran meanwhile.
      ;; If they changed anything, Neovim asks for the state
      ;; (`nvb-rpc-refresh') when it can take it, not while the user types.
      (let ((after (nvb--signature)))
        (when (and (process-live-p nvb--conn) (not (equal before after)))
          ;; Only a window change makes Neovim's layout wrong for a command.
          (unless (equal (car before) (car after)) (setq nvb--unpulled t))
          (nvb--send (list :method "changed")))))
    (while nvb--inbox
      (nvb--handle (pop nvb--inbox)))))

;;; Positions: Neovim speaks [LINE BYTE-COLUMN], both 0-based. A file
;;; buffer's mirror is always the whole file (a save in Neovim must never
;;; truncate it); other buffers mirror their accessible portion.

(defmacro nvb--in-view (&rest body)
  `(save-restriction
     (when (buffer-file-name) (widen))
     ,@body))

(defun nvb--pos (lc)
  (nvb--in-view
   (save-excursion
    (goto-char (point-min))
    (forward-line (car lc))
    (let ((bol (point)))
      (min (line-end-position)
           (or (byte-to-position (+ (position-bytes bol) (cadr lc))) (line-end-position)))))))

(defun nvb--lc (pos)
  (nvb--in-view
   (save-excursion
     (goto-char pos)
     (vector (1- (line-number-at-pos))
             (- (position-bytes pos) (position-bytes (line-beginning-position)))))))

;;; Mirrors: Emacs buffers that Neovim displays, identified by small ints.

(defvar nvb--mirrors (make-hash-table) "Id -> buffer.")
(defvar-local nvb--id nil)
(defvar-local nvb--tick nil "`buffer-chars-modified-tick' when Neovim last had our text.")
(defvar-local nvb--fold-sig nil
  "Fold ranges Neovim last received, or :unsent to force sending them.")
(defvar-local nvb--fold-tick nil "`buffer-modified-tick' when they were computed.")
(defvar-local nvb--shadow nil
  "A hidden buffer holding Neovim's copy of the text, to diff against.
Change hooks can't stand in: org makes some edits without running them.")
(put 'nvb--shadow 'permanent-local t)
(put 'nvb--id 'permanent-local t)
(put 'nvb--tick 'permanent-local t)
(put 'nvb--fold-sig 'permanent-local t)

(defun nvb--mirror-id (buf)
  "Return BUF's mirror id, creating one if needed."
  (with-current-buffer buf
    ;; An id is only BUF's if it was issued to BUF: indirect buffers made by
    ;; cloning (org-capture) inherit the base buffer's permanent-local id.
    (or (and nvb--id (eq (gethash nvb--id nvb--mirrors) buf) nvb--id)
        (let ((id (1+ (hash-table-count nvb--mirrors))))
          (while (gethash id nvb--mirrors) (cl-incf id))
          (puthash id buf nvb--mirrors)
          ;; A new mirror starts with nothing in Neovim, whatever a clone
          ;; inherited.
          (setq nvb--tick nil nvb--shadow nil nvb--fold-sig :unsent)
          (setq nvb--id id)))))

(defun nvb--shadow-text (text)
  "Record TEXT as Neovim's copy of the current buffer's text."
  (unless (buffer-live-p nvb--shadow)
    (setq nvb--shadow (generate-new-buffer " *nvb-shadow*" t))
    (with-current-buffer nvb--shadow (buffer-disable-undo))
    (add-hook 'kill-buffer-hook #'nvb--kill-shadow nil t))
  (with-current-buffer nvb--shadow
    (erase-buffer)
    (insert text)))

(defun nvb--shadow-hunk-apply (first count text)
  "Replace COUNT lines from line FIRST (0-based) of Neovim's copy with TEXT."
  (with-current-buffer nvb--shadow
    (goto-char (point-min))
    (forward-line first)
    (delete-region (point) (progn (forward-line count) (point)))
    (insert text)))

(defun nvb--kill-shadow ()
  (when (buffer-live-p nvb--shadow) (kill-buffer nvb--shadow)))

(defun nvb--buffer (id)
  (let ((buf (gethash id nvb--mirrors)))
    (unless (buffer-live-p buf) (error "Emacs buffer %s is gone" id))
    buf))

(defun nvb--common-prefix (a b)
  (let ((c (compare-strings a nil nil b nil nil)))
    (if (eq c t) (length a) (1- (abs c)))))

(defun nvb--replace-span (beg end text)
  "Make the text between BEG and END equal TEXT. Only the part between the
common prefix and suffix is replaced, so change hooks see the edit rather
than the whole span (org reveals folds a whole-buffer change touches) and
unchanged text keeps its properties. Neovim sends one hunk per changed
region, so the middle is replaced whole."
  (let ((old (buffer-substring-no-properties beg end)))
    (unless (string= text old)
      (let* ((pre (nvb--common-prefix old text))
             (suf (min (nvb--common-prefix (reverse old) (reverse text))
                       (- (min (length old) (length text)) pre)))
             (end (- end suf))
             (beg (+ beg pre))
             (new (substring text pre (- (length text) suf)))
             (inhibit-read-only t))
        ;; Not `replace-buffer-contents': with org's change hooks it can
        ;; signal beginning-of-buffer (found by test/fuzz.lua).
        (save-excursion
          (goto-char beg)
          (delete-region beg end)
          (insert new))))))

(defun nvb--whole-text ()
  (nvb--in-view (buffer-substring-no-properties (point-min) (point-max))))

(defun nvb--set-text (buf text)
  "Make the text Neovim mirrors in BUF (see `nvb--in-view') equal TEXT."
  (with-current-buffer buf
    (nvb--in-view (nvb--replace-span (point-min) (point-max) text))
    (nvb--shadow-text text)
    (setq nvb--tick (buffer-chars-modified-tick))))

;; Text crosses the socket as line hunks [FIRST COUNT LINES]: replace COUNT
;; lines from line FIRST (0-based) with LINES. Both sides keep the lines the
;; other has, so only changed lines travel. Neovim sends a list of hunks,
;; in its old line numbers; Emacs sends one. Whole text is sent on open and
;; reload, and when the buffer lacks a final newline.

(defun nvb--hunk-text (lines)
  "A hunk's LINES as text, each ending in a newline."
  (mapconcat (lambda (l) (concat l "\n")) lines ""))

(defun nvb--apply-hunk (buf hunk)
  "Apply Neovim's line HUNK (see above) to BUF, whose text ends in a newline."
  (with-current-buffer buf
    (pcase-let ((`(,first ,count ,lines) hunk))
      (let ((text (nvb--hunk-text lines)))
        (nvb--in-view
         (save-excursion
           (goto-char (point-min))
           (forward-line first)
           (let ((beg (point)))
             (forward-line count)
             (nvb--replace-span beg (point) text))))
        (nvb--shadow-hunk-apply first count text))
      (setq nvb--tick (buffer-chars-modified-tick)))))

(defun nvb--common-suffix (a ea b eb limit)
  "Length of the longest common tail of the text before EA in buffer A and
before EB in buffer B, at most LIMIT. Tails are compared in C; equality
only shrinks as the tail grows, so bisect on its length."
  (let ((lo 0) (hi limit))
    (while (< lo hi)
      (let ((k (/ (+ lo hi 1) 2)))
        (if (eq 0 (compare-buffer-substrings a (- ea k) ea b (- eb k) eb))
            (setq lo k)
          (setq hi (1- k)))))
    lo))

(defun nvb--shadow-hunk ()
  "The line hunk turning Neovim's copy (`nvb--shadow') into the current
text, which both end in a newline, and update the copy; nil if equal.
The text is what Neovim shows (`nvb--in-view'): capture's is narrowed."
  (let (;; compare-buffer-substrings ignores case when case-fold-search is set.
        (case-fold-search nil)
        (buf (current-buffer))
        (shadow nvb--shadow))
    (nvb--in-view
     (let* ((text-beg (point-min))
            (text-end (point-max))
            (shadow-end (with-current-buffer shadow (point-max)))
            (cmp (compare-buffer-substrings buf text-beg text-end shadow 1 shadow-end)))
       (unless (eq cmp 0)
         ;; Positions stay at or before the final newline: past it is no
         ;; line. A region starting past Neovim's copy is an append.
         (let* ((pre (1- (abs cmp)))
                (suf (nvb--common-suffix buf text-end shadow shadow-end
                                         (min (- text-end text-beg pre) (- shadow-end 1 pre))))
                (beg (save-excursion (goto-char (min (+ text-beg pre) (1- text-end)))
                                     (line-beginning-position)))
                (end (save-excursion (goto-char (max beg (min (- text-end suf) (1- text-end))))
                                     (line-end-position)))
                (shadow-beg (1+ (- beg text-beg)))
                (count (if (>= shadow-beg shadow-end)
                           0
                         (with-current-buffer shadow
                           (save-excursion
                             (goto-char (max shadow-beg (min (- shadow-end suf) (1- shadow-end))))
                             (1+ (- (line-number-at-pos (line-end-position))
                                    (line-number-at-pos shadow-beg)))))))
                (first (1- (line-number-at-pos beg)))
                (lines (split-string (buffer-substring-no-properties beg end) "\n")))
           (nvb--shadow-hunk-apply first count (nvb--hunk-text lines))
           (vector first count (vconcat lines))))))))

(defun nvb--revert (buf text)
  "Neovim reloaded BUF's file: take TEXT with no properties carried over
\(folds), as `revert-buffer' does. Markers (agenda entries) keep their
places because unchanged text is not reinserted."
  ;; The disk's modtime first: an unmodified buffer whose file changed is a
  ;; supersession threat, which batch Emacs can't ask about.
  (with-current-buffer buf (set-visited-file-modtime))
  (nvb--set-text buf text)
  (with-current-buffer buf
    (nvb--in-view
     (with-silent-modifications
       (set-text-properties (point-min) (point-max) nil)))
    (normal-mode)
    (font-lock-mode 1)
    (setq nvb--fold-sig :unsent)))

(defun nvb--apply-syncs (syncs)
  "Take Neovim's text; for file buffers also its modified flag, since
Neovim owns the file (`:e!' leaves the text unmodified, for instance)."
  (dolist (s syncs)
    (let ((buf (nvb--buffer (plist-get s :id))))
      (cond ((plist-get s :reload) (nvb--revert buf (plist-get s :text)))
            ;; Hunks arrive ascending (line_hunks); apply bottom-up so
            ;; earlier hunks' line numbers stay valid.
            ((plist-get s :hunks)
             (dolist (h (reverse (plist-get s :hunks)))
               (nvb--apply-hunk buf h)))
            ((plist-get s :text) (nvb--set-text buf (plist-get s :text))))
      (when (plist-member s :modified)
        (with-current-buffer buf (set-buffer-modified-p (plist-get s :modified)))))))

(defun nvb--folds-unchanged-p ()
  "Whether the folds Neovim has are still right, without rescanning the
buffer: org folds with text properties, and even silent property changes
advance `buffer-modified-tick'. Overlays (agenda filters) don't."
  (and (derived-mode-p 'org-mode)
       (eq (bound-and-true-p org-fold-core-style) 'text-properties)
       (not (eq nvb--fold-sig :unsent))
       (eql nvb--fold-tick (buffer-modified-tick))))

(defun nvb--hidden-ranges ()
  "Fold ranges: (FIRST LAST ELLIPSIS), where FIRST is the visible line
before a run of wholly invisible lines, LAST the run's final line, and
ELLIPSIS whether Emacs draws one (agenda filters hide lines without)."
  (nvb--in-view
   (save-excursion
     (let ((pos (point-min)) (end (point-max)) ranges
           ;; Line number of `lpos' (a line start), advanced monotonically.
           (lpos (point-min)) (lnum 0))
       (cl-flet ((line-at (bol)
                   (setq lnum (+ lnum (count-lines lpos bol)) lpos bol)
                   lnum))
         (while (< pos end)
           (let ((next (next-single-char-property-change pos 'invisible nil end)))
             (when (invisible-p pos)
               ;; Merge adjacent invisible runs with different property values.
               (while (and (< next end) (invisible-p next))
                 (setq next (next-single-char-property-change next 'invisible nil end)))
               (goto-char pos)
               ;; `invisible-p' is t only for invisibility without ellipsis.
               ;; A run hangs on the line it starts in, which shows its text or
               ;; the ellipsis. Without an ellipsis, a run from a line's start
               ;; (Magit's) draws no row: its lines start at `pos', and a line
               ;; at `next' shows.
               (let* ((no-ellipsis (eq (invisible-p pos) t))
                      (rowless (and no-ellipsis (bolp)))
                      first last)
                 (unless rowless (forward-line 1))
                 (while (and (if rowless (< (point) next) (<= (point) next))
                             (not (eobp)) (<= (line-end-position) next))
                   (unless first (setq first (point)))
                   (setq last (point))
                   (forward-line 1))
                 (when first
                   (let ((l1 (line-at first)))
                     (push (list (1- l1) (line-at last) (if no-ellipsis :false t)) ranges)))))
             (setq pos next))))
       (nreverse ranges)))))

(defun nvb--line-prefixes (l1 l2)
  "[LINE PREFIX FACE] for lines L1..L2 that Emacs draws with a
`line-prefix' (`org-indent-mode'). A heading's prefix is stars in
`org-indent', the background's color: sent as spaces, which look the same,
since Neovim draws its cursor on the prefix and a terminal that inverts the
cell's colors would hide it there."
  (nvb--in-view
   (save-excursion
     (goto-char (point-min))
     (forward-line l1)
     (let (out (line l1))
       (while (and (<= line l2) (not (eobp)))
         (let ((p (or (get-char-property (point) 'line-prefix) line-prefix)))
           (when (and (stringp p) (not (string-empty-p p)))
             (let ((face (nvb--main-face (get-text-property 0 'face p))))
               (push (vector line
                             (if (member face '("org-indent" "org-hide"))
                                 (make-string (string-width p) ?\s)
                               (substring-no-properties p))
                             face)
                     out))))
         (forward-line 1)
         (setq line (1+ line)))
       (vconcat (nreverse out))))))

(defun nvb--face-names (face)
  "List of face names for a `face' property value."
  (cond ((null face) nil)
        ((symbolp face) (list (symbol-name face)))
        ((and (consp face) (keywordp (car face)))
         (list (nvb--anon-face face)))
        ((consp face) (cl-mapcan #'nvb--face-names face))))

(defvar nvb--anon-faces (make-hash-table :test #'equal))
(defvar nvb--faces-sent (make-hash-table :test #'equal)
  "Face names whose definitions Neovim already has.")
(defun nvb--anon-face (plist)
  "A short name for the attribute list PLIST. Hashed: values can be long
propertized strings (CSS color swatches carry keymaps)."
  (let ((name (concat "anon:" (substring (secure-hash 'md5 (format "%S" plist)) 0 12))))
    (puthash name plist nvb--anon-faces)
    name))

(defun nvb--fontify (beg end)
  ;; Buffers Emacs creates itself (capture, src edit) never got font-lock.
  (when (and (not font-lock-mode) font-lock-defaults)
    (font-lock-mode 1))
  (when font-lock-mode
    (let ((noninteractive nil))
      (font-lock-fontify-region beg end))))

(defun nvb--spans (l1 l2)
  "Highlight and conceal spans for lines L1..L2 (0-based, inclusive).
Each span is (LINE START-BYTE END-BYTE FACE [DISPLAY [RUNS]]). Without
DISPLAY, FACE is a face name, or nil for concealed (invisible) text. With
DISPLAY, the text is drawn as that string (a `display' property or a
composition), in FACE if non-nil. RUNS, when the string has faces of its
own (the clock overlay's dots and time), is [[TEXT FACE]...] covering it.
A FACE span covering the newline fills the rest of the window line."
  (nvb--in-view
   (save-excursion
    (goto-char (point-min))
    (forward-line l1)
    (let* ((beg (point))
           (end (progn (forward-line (1+ (- l2 l1))) (point)))
           (spans nil)
           (line l1)
           (pos beg))
      (nvb--fontify beg end)
      (while (< pos end)
        (let* ((eol (save-excursion (goto-char pos) (line-end-position)))
               (bol-bytes (position-bytes (save-excursion (goto-char pos) (line-beginning-position))))
               (col (lambda (p) (- (position-bytes p) bol-bytes)))
               (disp (get-char-property pos 'display))
               (comp (find-composition pos nil nil t))
               (replacement
                (cond ((stringp disp) (substring-no-properties disp))
                      ;; Composed text (pretty entities: \alpha drawn as α).
                      ((and comp (= (car comp) pos))
                       (concat (seq-filter #'characterp (append (nth 2 comp) nil))))))
               (next (min eol (cond ((stringp disp)
                                     (next-single-char-property-change pos 'display nil eol))
                                    (replacement (cadr comp))
                                    (t (next-char-property-change pos eol))))))
          (when (> next pos)
            (cond
             ;; One span for the whole replaced run: overlays like the
             ;; agenda's "=> date" stamp span several face changes.
             (replacement
              (let* ((face (nvb--main-face (get-char-property pos 'face)))
                     (runs (and (stringp disp) (nvb--display-runs disp face))))
                (push (append (list line (funcall col pos) (funcall col next) face replacement)
                              (and runs (list runs)))
                      spans)))
             ((invisible-p pos)
              (let ((prev (car spans)))
                ;; a conceal span: (LINE START END nil)
                (if (and prev (= (length prev) 4) (null (nth 3 prev)) (eql (car prev) line)
                         (eql (nth 2 prev) (funcall col pos)))
                    (setcar (nthcdr 2 prev) (funcall col next))
                  (push (list line (funcall col pos) (funcall col next) nil) spans))))
             (t
              (dolist (f (nvb--faces-at pos))
                (push (list line (funcall col pos) (funcall col next) f) spans)))))
          (if (< next eol)
              (setq pos next)
            ;; :extend faces on the newline: a span one byte past the text.
            (when (< eol (point-max))
              (dolist (f (seq-filter #'nvb--extend-p (nvb--faces-at eol)))
                (push (list line (funcall col eol) (1+ (funcall col eol)) f) spans)))
            (setq pos (1+ eol) line (1+ line)))))
      (append (nreverse spans) (nvb--overlay-string-spans beg end))))))

(defun nvb--faces-at (pos)
  "Names of the faces at POS, `face' before `font-lock-face'."
  (append (nvb--face-names (get-char-property pos 'face))
          (nvb--face-names (get-char-property pos 'font-lock-face))))

(defun nvb--extend-p (name)
  "Whether face NAME is :extend, drawn past the end of the line."
  (let ((anon (gethash name nvb--anon-faces)))
    (if anon
        (or (eq t (plist-get anon :extend))
            (seq-some (lambda (f) (and (symbolp f) (nvb--extend-p (symbol-name f))))
                      (ensure-list (plist-get anon :inherit))))
      (and (facep (intern-soft name))
           (eq t (face-attribute (intern name) :extend nil t))))))

(defun nvb--overlay-string-spans (beg end)
  "Zero-width replacement spans for the strings overlays draw before or
after their text between BEG and END (C-c }'s row numbers)."
  (let (spans)
    (dolist (ov (overlays-in beg end))
      (dolist (side '((before-string . overlay-start) (after-string . overlay-end)))
        (let ((str (overlay-get ov (car side)))
              (pos (funcall (cdr side) ov)))
          ;; A string displayed in the fringe or margins (bookmarks' mark,
          ;; which capture and refile set) shows nothing in the text; see
          ;; `nvb--margin-strings' for the margins. One drawn outside the
          ;; lines (a blame chunk's heading, scrolled past) is theirs.
          (when (and (stringp str) (<= beg pos) (or (< pos end) (= pos (point-max)))
                     (not (nvb--outside-text-p (get-text-property 0 'display str))))
            (let ((lc (nvb--lc pos)))
              (push (let ((face (nvb--string-face str 0)))
                      (append (list (aref lc 0) (aref lc 1) (aref lc 1) face
                                    (substring-no-properties str))
                              (let ((runs (nvb--display-runs str face))) (and runs (list runs)))))
                    spans))))))
    (nreverse spans)))

(defun nvb--margin-strings (l1 l2)
  "[LINE RUNS] for the strings overlays on lines L1..L2 draw in the right
margin (Magit's log dates)."
  (nvb--in-view
   (save-excursion
     (goto-char (point-min))
     (forward-line l1)
     (let ((beg (point)) out)
       (forward-line (1+ (- l2 l1)))
       (dolist (ov (overlays-in beg (point)))
         (let* ((str (overlay-get ov 'before-string))
                (display (and (stringp str) (get-text-property 0 'display str))))
           (when (and (consp display) (equal (car display) '(margin right-margin))
                      (stringp (cadr display)))
             (push (vector (aref (nvb--lc (overlay-start ov)) 0)
                           (or (nvb--display-runs (cadr display) nil)
                               (vector (vector (substring-no-properties (cadr display)) nil))))
                   out))))
       (vconcat out)))))

(defun nvb--outside-text-p (display)
  "Whether DISPLAY (a `display' property) draws in a fringe or margin."
  (and (consp display)
       (or (memq (car display) '(left-fringe right-fringe))
           (and (consp (car display)) (eq (caar display) 'margin)))))

(defun nvb--main-face (face)
  "One face name for a `face' property value: a named face (org-column)
over computed attribute lists."
  (let ((names (nvb--face-names face)))
    (or (seq-find (lambda (n) (not (string-prefix-p "anon:" n))) names)
        (car names))))

(defun nvb--display-runs (str base)
  "STR's runs as [[TEXT FACE]...] if STR has faces of its own; runs without
one take BASE, the face of the text STR replaces."
  (when (seq-some (lambda (p) (text-property-not-all 0 (length str) p nil str))
                  '(face font-lock-face))
    (let ((runs nil) (i 0))
      (while (< i (length str))
        (let ((next (min (next-single-property-change i 'face str (length str))
                         (next-single-property-change i 'font-lock-face str (length str)))))
          (push (vector (substring-no-properties str i next)
                        (or (nvb--string-face str i) base))
                runs)
          (setq i next)))
      (vconcat (nreverse runs)))))

(defun nvb--string-face (str i)
  "One face name for the face at I in STR. Magit's strings give theirs as
`font-lock-face' lists, merged as Emacs merges them."
  (let ((face (or (get-text-property i 'face str) (get-text-property i 'font-lock-face str))))
    (if (and (consp face) (cdr face) (not (keywordp (car face))) (seq-every-p #'symbolp face))
        (nvb--anon-face (list :inherit face))
      (nvb--main-face face))))

(defun nvb--face-info (name)
  "Attributes Neovim needs to build a highlight group for face NAME."
  (let* ((anon (gethash name nvb--anon-faces))
         (face (unless anon (intern name)))
         (get (lambda (attr)
                (let ((v (if anon (plist-get anon attr) (face-attribute face attr nil nil))))
                  (unless (eq v 'unspecified) v))))
         (inherit (funcall get :inherit))
         (inherit (cond ((null inherit) nil) ((listp inherit) inherit) (t (list inherit)))))
    (list :name name
          :inherit (vconcat (mapcar #'symbol-name (seq-filter #'symbolp inherit)))
          :fg (let ((c (funcall get :foreground))) (and (stringp c) c))
          :bg (let ((c (funcall get :background))) (and (stringp c) c))
          ;; "" when unset, so a face can also turn an inherited bold off.
          :weight (let ((w (funcall get :weight))) (if w (symbol-name w) ""))
          :italic (nvb--bool (memq (funcall get :slant) '(italic oblique)))
          :underline (let ((u (funcall get :underline)))
                       (cond ((and (consp u) (eq (plist-get u :style) 'wave)) "wave")
                             (t (nvb--bool u))))
          :strike (nvb--bool (funcall get :strike-through))
          :custom (nvb--bool (and face (nvb--face-customized-p face))))))

(defun nvb--span-faces (spans)
  "Face names SPANS use, display-string runs included."
  (cl-mapcan (lambda (s) (cons (nth 3 s) (seq-map (lambda (run) (aref run 1)) (nth 5 s))))
             spans))

(defun nvb--display-color-cells (&rest _)
  "Batch Emacs's frame has no colors, so face specs for color displays
(themes, org's own, (min-colors 88)) never match: claim 24-bit color, as
Neovim's terminal has (see `nvb-set-background')."
  16777216)

(defun nvb-set-background (mode)
  "Choose face variants for Neovim's `background' MODE (light or dark), on
a color display, as Emacs does for its frame; faces are sent again."
  (modify-frame-parameters nil `((display-type . color) (background-mode . ,mode)))
  (dolist (face (face-list)) (face-spec-recalc face (selected-frame)))
  (clrhash nvb--faces-sent))

(defun nvb-rpc-background (params)
  (nvb-set-background (intern (plist-get params :background)))
  t)

(defun nvb--face-customized-p (face)
  "Whether FACE's colors differ from its defface for this display: the user
(set-face-attribute, custom-set-faces) or a theme set them, so they win
over the Neovim group a known face maps to."
  (let ((spec (face-spec-choose (face-default-spec face))))
    (cl-some (lambda (attr)
               (not (equal (face-attribute face attr nil nil)
                           (or (plist-get spec attr) 'unspecified))))
             '(:foreground :background))))

(defun nvb--faces-changed (&rest _)
  "A face changed (`set-face-attribute', a theme): send definitions again."
  (clrhash nvb--faces-sent))

(defun nvb--new-faces (names)
  "Definitions for faces NAMES (and their ancestors) not yet sent."
  (let (out)
    (cl-labels ((add (name)
                  (unless (or (null name) (gethash name nvb--faces-sent))
                    (puthash name t nvb--faces-sent)
                    (when (or (gethash name nvb--anon-faces) (facep (intern-soft name)))
                      (let ((info (nvb--face-info name)))
                        (push info out)
                        (mapc #'add (plist-get info :inherit)))))))
      (mapc #'add names))
    (vconcat out)))

(defun nvb--shown-point (buf)
  "BUF's point as its window shows it."
  (let ((win (get-buffer-window buf)))
    (if win (window-point win) (with-current-buffer buf (point)))))

(defvar evil-global-keymaps-alist)

(defun nvb--vim-key-p (key cmd)
  "Whether evil is on and its global maps bind KEY to CMD (gg, v, $): a
key Neovim has itself."
  (and (bound-and-true-p evil-local-mode)
       (cl-some (lambda (m) (eq cmd (lookup-key (symbol-value (cdr m)) key)))
                evil-global-keymaps-alist)))

(defun nvb--forwarded-p (key)
  "Whether KEY runs a command Neovim doesn't have."
  (let ((b (key-binding key t)))
    (and b (commandp b) (not (keymapp b))
         (not (memq b '(self-insert-command undefined org-self-insert-command digit-argument)))
         (not (nvb--vim-key-p key b)))))

(defun nvb--bound-keys (buf)
  "Printable keys bound to commands at BUF's point, other than self-insert,
`digit-argument' and evil's own keys: Neovim forwards these in read-only
buffers (agenda, Magit) and column view and keeps the rest (G, 12G, counts)
as its own. Under a printable prefix (evil-collection's g and z), the keys
bound after it, as \"gr\": gg and zz stay Neovim's. Also Meta keys bound
there to other than their global command, as \"M-m\" (the agenda's bulk
toggle, evil-collection's M-k in the rebase todo); global ones (M-f) stay
Neovim's."
  (with-current-buffer buf
    (save-excursion
      (goto-char (nvb--shown-point buf))
      (let (keys)
        (dolist (c (number-sequence ?! ?~))
          (let ((key (string c)))
            (if (keymapp (key-binding key t))
                (dolist (d (number-sequence ?! ?~))
                  (when (nvb--forwarded-p (string c d)) (push (string c d) keys)))
              (when (nvb--forwarded-p key) (push key keys))))
          ;; Not `local-key-binding': evil's state maps are minor-mode maps.
          ;; Unremapped: evil remaps the global M-y.
          (let* ((key (vector (event-apply-modifier c 'meta 27 "M-")))
                 (b (key-binding key t t)))
            (when (and b (commandp b) (not (eq b (global-key-binding key t)))
                       (not (nvb--vim-key-p key b)))
              (push (concat "M-" (string c)) keys))))
        (vconcat (nreverse keys))))))

(defun nvb--buffer-state (buf)
  "Update record for BUF: text if Neovim's copy is stale, folds if changed."
  (with-current-buffer buf
    (let* (;; First: a newly issued id resets what Neovim is known to have.
           (id (nvb--mirror-id buf))
           (tick (buffer-chars-modified-tick))
           (changed (not (eql tick nvb--tick)))
           ;; Only the changed lines, unless Neovim has none yet or a final
           ;; newline is missing (hunks assume every line ends in one).
           (by-hunk (and changed (buffer-live-p nvb--shadow)
                         (eq (nvb--in-view (char-before (point-max))) ?\n)
                         (eq (with-current-buffer nvb--shadow (char-before (point-max))) ?\n)))
           (hunk (and by-hunk (nvb--shadow-hunk)))
           (text (and changed (not by-hunk) (nvb--whole-text)))
           (folds (if (nvb--folds-unchanged-p) nvb--fold-sig (nvb--hidden-ranges)))
           ;; Neovim's manual folds move with hunks; whole text resets them.
           (fold-changed (or text (not (equal folds nvb--fold-sig)))))
      (when text (nvb--shadow-text text))
      (when changed (setq nvb--tick tick))
      (setq nvb--fold-sig folds
            nvb--fold-tick (buffer-modified-tick))
      (append
       (list :id id
             :name (buffer-name)
             :file (nvb--visited-file)
             :mode (symbol-name major-mode)
             ;; `nvb--visit' makes its buffers read-only for itself.
             :readonly (nvb--bool (and buffer-read-only (not nvb--unmirrored)))
             ;; Neovim sends keys typed at a heading's start to Emacs then.
             :speed (nvb--bool (and (derived-mode-p 'org-mode)
                                    (bound-and-true-p org-use-speed-commands)))
             :modified (nvb--bool (buffer-modified-p))
             :header (let ((h (nvb--format-simple header-line-format)))
                       (if (string-empty-p h) :false h))
             ;; Column view binds its keys on overlays; Neovim forwards keys
             ;; as in read-only Emacs buffers while it is on.
             :columns (nvb--bool (bound-and-true-p org-columns-overlays))
             ;; A file Emacs edits for emacsclient (Magit's commit message)
             ;; takes Emacs's keys (C-c C-c) whatever its type.
             :server (nvb--bool (bound-and-true-p server-buffer-clients))
             ;; And a file of another type takes C-c while a minor mode on
             ;; there binds keys under it (smerge-mode's C-c ^).
             :minor_c_c (nvb--bool (cl-some (lambda (m)
                                              (and (local-variable-p (car m)) (symbol-value (car m))
                                                   (keymapp (lookup-key (cdr m) (kbd "C-c")))))
                                            minor-mode-map-alist))
             :keys (nvb--bound-keys buf)
             ;; Evil has a Visual state here: those keys act on Neovim's selection.
             :visual (nvb--bool (bound-and-true-p evil-local-mode))
             ;; The agenda keeps its state here: "Org-Agenda Week Log Follow".
             :mode_line (string-trim (concat (nvb--format-simple mode-name)
                                             (nvb--format-simple mode-line-process)))
             :ellipsis (if (and (derived-mode-p 'org-mode) (stringp org-ellipsis))
                           org-ellipsis
                         "...")
             :point (nvb--lc (nvb--shown-point buf)))
       (cond (text (list :text text))
             (hunk (list :hunk hunk)))
       (when fold-changed (list :folds (vconcat (mapcar #'vconcat folds))))))))

;;; Window and selection state

(defconst nvb--placeholder " *nvim-window*"
  "Buffer for Emacs windows whose Neovim window shows a buffer Emacs doesn't
mirror (a .txt file, say). Internal, so never reported to Neovim.")

(defvar nvb--unplaced nil "Neovim windows the last layout had no room for.")

(defun nvb--apply-layout (layout selected)
  "Make Emacs's windows match Neovim's before a command, so commands that
reuse, split or delete windows act on Neovim's layout. LAYOUT is a list of
\(:win W :id ID :point P :top T :height H) in screen order, every field
but :id always present; SELECTED is the 1-based index of
Neovim's current window. A window with :file instead of :id shows a file
Neovim doesn't mirror (see `nvb--visit'). Each window remembers W in its
`nvb-win' parameter, which is how Neovim pairs the windows back up
afterwards. An unchanged layout keeps its windows: commands hold on to
them between commands (`org-agenda-show-window' for SPC SPC)."
  (nvb--fit-frame layout)
  (let ((windows (if (nvb--windows-are-p layout)
                     (window-list nil 'never (frame-first-window))
                   (nvb--split-for layout))))
    (cl-loop for win in windows
             for w in layout
             for i from 1
             do (let ((buf (cond ((plist-get w :id) (nvb--buffer (plist-get w :id)))
                                 ((plist-get w :file) (nvb--visit (plist-get w :file)))
                                 (t (get-buffer-create nvb--placeholder)))))
                  (unless (eq (window-buffer win) buf) (set-window-buffer win buf))
                  (set-window-parameter win 'nvb-win (plist-get w :win))
                  (nvb--resize win (plist-get w :height))
                  (set-window-start win (with-current-buffer buf (nvb--pos (list (plist-get w :top) 0))) t)
                  ;; `nvb-rpc-exec' moves a selected mirror's point, as a command.
                  (unless (and (eql i selected) (plist-get w :id))
                    (set-window-point win (with-current-buffer buf (nvb--pos (plist-get w :point)))))))
    (select-window (or (and selected (nth (1- selected) windows)) (frame-first-window)))))

(defun nvb--fit-frame (layout)
  "Grow the batch frame (24 rows) to hold LAYOUT's windows at Neovim's
heights, each with its mode line."
  (let ((rows (1+ (apply #'+ (mapcar (lambda (w) (1+ (plist-get w :height))) layout)))))
    (when (> rows (frame-height))
      (set-frame-size nil (frame-width) rows))))

(defun nvb--resize (win height)
  "Make WIN's text HEIGHT lines, as Neovim's window, as far as room allows."
  (let* ((window-min-height 1)
         (delta (window-resizable win (- height (window-body-height win)))))
    (unless (zerop delta) (window-resize win delta))))

(defun nvb--windows-are-p (layout)
  "Non-nil when Emacs's windows are LAYOUT's, in order, all placed."
  (let ((wins (window-list nil 'never (frame-first-window))))
    (and (null nvb--unplaced)
         (= (length wins) (length layout))
         (cl-every (lambda (win w) (equal (window-parameter win 'nvb-win) (plist-get w :win)))
                   wins layout))))

(defun nvb--split-for (layout)
  "New windows for LAYOUT's, in screen order, as many as fit."
  (delete-other-windows)
  (setq nvb--unplaced nil)
  (let ((window-min-height 1)
        (window-safe-min-height 1)
        (windows (list (selected-window))))
    (catch 'full
      (cl-loop for rest on (cdr layout)
               do (let ((big (get-largest-window)))
                    ;; The batch frame has 24 rows; Neovim may have more
                    ;; windows than fit. Those are reported as :unplaced, so
                    ;; Neovim keeps them.
                    (when (< (window-total-height big) (* 2 (window-min-size big)))
                      (setq nvb--unplaced (mapcar (lambda (w) (plist-get w :win)) rest))
                      (throw 'full nil))
                    (push (split-window big nil 'below) windows))))
    (nreverse windows)))

(defvar-local nvb--unmirrored nil
  "Non-nil in a buffer `nvb--visit' opened for a file Neovim doesn't mirror.")

(defun nvb--visit (file)
  "FILE, read-only and current with the disk, for a Neovim window showing a
file Emacs doesn't mirror: commands run from there (`org-store-link',
capture's %a) need its buffer. Unsaved Neovim edits aren't in it."
  (let ((buf (find-file-noselect file t)))
    (with-current-buffer buf
      (unless (verify-visited-file-modtime buf)
        (revert-buffer t t t))
      (setq buffer-read-only t
            nvb--unmirrored t))
    buf))

(defvar nvb--new-windows 0 "The last name given a window Emacs made (negative).")

(defun nvb--window-states ()
  "Emacs's windows after a command, for Neovim to mirror: (:win W :id ID
:point P :top T :selected S), where W is the Neovim window it was made from
or, for a window Emacs made, a negative number: reported again before the
next command (`nvb-rpc-refresh'), it names the same new Neovim window. A
window back on a file Neovim doesn't mirror (`nvb--visit') has :file
instead of :id."
  (vconcat
   (mapcar (lambda (w)
             (let ((b (window-buffer w)))
               (append
                (list :win (or (window-parameter w 'nvb-win)
                               (set-window-parameter w 'nvb-win (cl-decf nvb--new-windows)))
                      :selected (nvb--bool (eq w (selected-window))))
                (unless (nvb--internal-p b)
                  (append (if (buffer-local-value 'nvb--unmirrored b)
                              (list :file (buffer-file-name b))
                            (list :id (nvb--mirror-id b)))
                          (list :point (with-current-buffer b (nvb--lc (window-point w)))
                                :top (with-current-buffer b (aref (nvb--lc (window-start w)) 0))))))))
           ;; In screen order: window-list starts at the selected window.
           (window-list nil 'never (frame-first-window)))))

(defun nvb--internal-p (buf)
  "Non-nil for buffers Neovim should never see (names starting with a space)."
  (string-prefix-p " " (buffer-name buf)))

(defun nvb--displayed-buffers ()
  (seq-remove #'nvb--internal-p
              (delete-dups (mapcar #'window-buffer (window-list nil 'never)))))

(defun nvb--reap-dead-mirrors ()
  "Forget mirrors whose buffer died; return their ids."
  (let (dead)
    (maphash (lambda (id b) (unless (buffer-live-p b) (push id dead))) nvb--mirrors)
    (dolist (id dead) (remhash id nvb--mirrors))
    dead))

(defun nvb--state (&optional extra)
  "Response describing every mirror Neovim should update."
  (let ((bufs (nvb--displayed-buffers)))
    ;; File buffers Emacs changed behind Neovim's back must reach Neovim so
    ;; they can be saved there.
    (dolist (b (buffer-list))
      (when (and (buffer-file-name b) (buffer-modified-p b)
                 (with-current-buffer b (not (eql nvb--tick (buffer-chars-modified-tick)))))
        (cl-pushnew b bufs)))
    (maphash (lambda (_id b) (when (buffer-live-p b) (cl-pushnew b bufs))) nvb--mirrors)
    (let* ((states (vconcat (mapcar #'nvb--buffer-state bufs)))
           ;; Reap after states: they may allocate ids, and a reaped id must
           ;; not be reused in this same response.
           (dead (nvb--reap-dead-mirrors)))
      (append
       (list :buffers states
             :windows (nvb--window-states)
             :unplaced (vconcat nvb--unplaced)
             :dead (vconcat dead)
             :messages (vconcat (reverse nvb--messages))
             ;; A region a command left active (C-c @), for Visual mode.
             :region (if (and mark-active (mark t) (not (nvb--internal-p (current-buffer))))
                         (vector (nvb--lc (mark t)) (nvb--lc (point)))
                       :false)
             :kill (nvb--new-kill)
             ;; What modes add to the mode line (the org clock), for Neovim's
             ;; statusline.
             :modeline (nvb--mode-line-extras))
       extra))))

;;; RPC methods (nvb-rpc-METHOD)

(defun nvb-rpc-open (params)
  "Visit FILE (or create a scratch buffer NAME) with Neovim's TEXT."
  (let* ((file (plist-get params :file))
         (buf (if file
                  (find-file-noselect file t)
                (get-buffer-create (plist-get params :name)))))
    (with-current-buffer buf
      ;; `nvb--visit' may have opened it read-only before Neovim mirrored it.
      (setq buffer-read-only nil
            nvb--unmirrored nil)
      ;; Only scratch buffers come with a :mode; a file's comes from its name.
      (when (plist-get params :mode)
        (funcall (intern (plist-get params :mode))))
      (font-lock-mode 1))
    ;; The id first: a new one resets what Neovim is known to have.
    (let ((id (nvb--mirror-id buf)))
      (nvb--set-text buf (plist-get params :text))
      (with-current-buffer buf
        (nvb--refold (plist-get params :folds))
        (set-buffer-modified-p (plist-get params :modified))
        ;; Neovim's windows may hold folds from an earlier Emacs; always send ours.
        (setq nvb--fold-sig :unsent))
      (nvb--run-idle-timers)
      (list :id id :state (nvb--buffer-state buf)))))

(defun nvb--refold (ranges)
  "Fold RANGES ((FIRST LAST ...), lines as Neovim last had them) again: an
earlier Emacs made them and died. A fold on a heading is an outline fold,
on a drawer a drawer one, else a block's."
  (when (and ranges (derived-mode-p 'org-mode))
    (nvb--in-view
     (save-excursion
       (pcase-dolist (`(,first ,last . ,_) ranges)
         ;; FIRST -1: hidden from the first line, no line to hang a fold on.
         (when (>= first 0)
           (goto-char (point-min))
           (forward-line first)
           (nvb--fold-lines first last t (cond ((org-at-heading-p) 'outline)
                                               ((looking-at-p org-drawer-regexp) 'drawer)
                                               (t 'block)))))))))

(defun nvb--fold-lines (first last flag &optional spec)
  "Hide (FLAG non-nil) or show lines FIRST+1 to LAST as SPEC's fold, which
hangs on line FIRST's end; FIRST -1 (see `nvb--hidden-ranges') starts it
at the buffer's start. Moves point."
  (goto-char (point-min))
  (forward-line first)
  (let ((from (if (< first 0) (point-min) (line-end-position))))
    (goto-char (point-min))
    (forward-line last)
    (org-fold-region from (line-end-position) flag spec)))

(defun nvb--font-lock-mode (orig &rest args)
  "`font-lock-mode' refuses to turn on in batch Emacs (org toggles it, e.g.
for pretty entities)."
  (let ((noninteractive nil))
    (apply orig args)))

(defun nvb--prefix-arg (count)
  "Neovim's count as a prefix argument: 4, 16, 64 act like C-u."
  (cond ((or (null count) (eql count 0)) nil)
        ((memq count '(4 16 64)) (list count))
        (t count)))

(defun nvb--split-keys (keys)
  "Split KEYS into the sequence naming a command and the keys after it,
which answer that command's own key reads (`:Emacs C-c a w')."
  (let ((i 1))
    (while (and (< i (length keys)) (keymapp (key-binding (seq-subseq keys 0 i) t)))
      (cl-incf i))
    (cons (seq-subseq keys 0 i)
          (mapcar (lambda (k) (key-description (vector k))) (seq-subseq keys i)))))

(defun nvb--complete-keys (keys)
  "Extend KEYS (a vector) until it names a command, from the pending keys
or by asking Neovim."
  (let ((binding (key-binding keys t)))
    (while (keymapp binding)
      (setq keys (vconcat keys (vector (nvb--read-key-now (concat (key-description keys) "-"))))
            binding (key-binding keys t)))
    keys))

(defvar nvb--last-command nil
  "The last command run. Batch Emacs has no command loop to carry
`last-command' between requests, so the bridge keeps it for
repeat-sensitive commands like `org-cycle'.")

(defun nvb--run-command (cmd keys arg)
  "Run CMD as the command loop would after reading KEYS, with prefix ARG.
\(`execute-kbd-macro' would reset `last-command' and the prefix argument.)"
  (setq this-command cmd
        this-original-command cmd
        real-this-command cmd
        prefix-arg arg
        ;; Reset as the command loop does: the edits synced from Neovim
        ;; just before set it too, and only this command's own edits
        ;; should drop the mark.
        deactivate-mark nil)
  ;; The command loop's undo boundary, in every buffer changed since the
  ;; last one (Neovim's synced edits included): C-_ and the agenda's undo
  ;; take back one command at a time.
  (undo-auto--add-boundary)
  (when keys
    (setq last-command-event (aref keys (1- (length keys)))
          last-nonmenu-event last-command-event)
    ;; Batch Emacs reads no keys, so `this-command-keys' is empty; org's
    ;; speed commands look up the key typed there. Only character keys fit
    ;; the string it takes.
    (when (seq-every-p #'characterp keys)
      (set--this-command-keys (concat keys))))
  (run-hooks 'pre-command-hook)
  ;; The hook may replace the command: transient turns a key its menu
  ;; doesn't bind into `transient-undefined'. `called-interactively-p' is
  ;; always nil in batch, which silences the messages many commands print
  ;; only when run interactively.
  (let ((noninteractive nil))
    (command-execute this-command nil keys))
  (setq nvb--last-command this-command)
  (run-hooks 'post-command-hook)
  (when (and deactivate-mark mark-active) (deactivate-mark)))

(defun nvb--menu-loop ()
  "Run keys typed into a menu a command left up with a keymap of its own
\(Magit's transients, `set-transient-map'), as the command loop would,
until a key closes it. Each key is read with the menu shown."
  (while (and overriding-terminal-local-map (nvb--menu-window))
    ;; C-g and Escape are keys of the menu, not a quit.
    (let ((keys (let ((inhibit-quit t))
                  (nvb--complete-keys (vector (nvb--read-key-now ""))))))
      (setq last-command nvb--last-command)
      (condition-case e
          (nvb--run-command (or (key-binding keys t) #'undefined) keys nil)
        ;; Reported as the command loop does, which runs
        ;; post-command-hook after an error too (transient exits there).
        ((debug error quit)
         (message "%s" (error-message-string e))
         (run-hooks 'post-command-hook))))))

(defvar nvb--width nil "Width of Neovim's window during a command.")

(defun nvb--with-width (width fn)
  "Call FN laying out the agenda for a Neovim window WIDTH columns wide
(batch Emacs's frame is 80). Only bind the variable once org-agenda has
defined it: binding it void would discard the defcustom loading sets."
  ;; Load the agenda's options with org so the first agenda build is laid
  ;; out for WIDTH too.
  (when (featurep 'org) (require 'org-agenda))
  (let ((nvb--width width))
    (if (and (boundp 'org-agenda-tags-column) (eq org-agenda-tags-column 'auto))
        (let ((org-agenda-tags-column (- 1 width)))
          (funcall fn))
      (funcall fn))))

(defun nvb--window-max-chars-per-line (orig &rest args)
  "Neovim's width (org-agenda places its \"=> date\" stamps by this)."
  (if nvb--width (1- nvb--width) (apply orig args)))

(defvar nvb--kill-sent nil "The kill-ring entry Neovim last received.")

(cl-defun nvb-rpc-exec (params)
  "Run a command in buffer ID at POINT, then report the new state.
PARAMS has either :keys (kbd notation) or :command (a command name), and
:kill when Neovim yanked text since the last command."
  ;; Neovim sent its windows before taking a change Emacs made on its own
  ;; (a window emacsclient opened): applying them would close that window.
  (when nvb--unpulled (cl-return-from nvb-rpc-exec (list :stale t)))
  (nvb--apply-syncs (plist-get params :syncs))
  ;; Neovim's latest yank, so C-y and C-c C-x C-y paste what p would.
  (when (plist-get params :kill)
    (kill-new (plist-get params :kill))
    (setq nvb--kill-sent (car kill-ring)))
  (let* ((buf (if (plist-get params :id)
                  (nvb--buffer (plist-get params :id))
                ;; Neovim's current buffer has no mirror (e.g. :EmacsAgenda from a
                ;; .txt file): run from the placeholder Neovim never sees.
                (get-buffer-create nvb--placeholder)))
         (err nil)
         (want nil)
         (marks nil))
    (nvb--apply-layout (plist-get params :layout) (plist-get params :selected))
    (unless (eq (window-buffer) buf)
      (set-window-buffer (selected-window) buf))
    (nvb--reveal buf (plist-get params :revealed))
    (when (plist-get params :point)
      (setq want (nvb--pos (plist-get params :point)))
      ;; Neovim's motion is a command of its own, as it would be in Emacs:
      ;; hooks that compare point across a command (Magit's section
      ;; highlight) see it move.
      (unless (= want (point))
        ;; A hook's error must not leave point behind or lose the reply.
        (condition-case e
            (nvb--run-command (lambda () (interactive) (goto-char want)) nil nil)
          ((debug error quit) (goto-char want) (setq err (error-message-string e))))))
    (if (plist-get params :mark)
        (progn (push-mark (nvb--pos (plist-get params :mark)) t t)
               (setq mark-active t))
      (deactivate-mark))
    ;; Neovim reports :fresh when the user did something (moved, typed)
    ;; since the previous command, which Emacs would see as a command.
    (setq last-command (unless (plist-get params :fresh) nvb--last-command))
    (setq marks (nvb--marks))
    (condition-case e
        (let* ((split (when (plist-get params :keys)
                        (nvb--split-keys (vconcat (kbd (plist-get params :keys))))))
               (nvb--pending-keys (append (cdr split) (plist-get params :pending)))
               (keys (when split (nvb--complete-keys (car split))))
               (cmd (if keys
                        (or (key-binding keys t)
                            (user-error "%s is undefined" (key-description keys)))
                      (intern (plist-get params :command)))))
          (let ((outside (nvb--check-in-restriction want cmd)))
            (nvb--trim-line-region cmd)
            (nvb--with-width (plist-get params :width)
              (lambda ()
                (nvb--run-command cmd keys (nvb--prefix-arg (plist-get params :count)))
                (nvb--menu-loop)
                ;; It ran from the restriction's edge; widened, the cursor's
                ;; own position exists again.
                (when (and outside (<= (point-min) want (point-max))) (goto-char want))
                ;; Keys typed while Neovim waited (table typing): each its
                ;; own command, in one round trip. An unbound key is
                ;; skipped, so the keys after it still run.
                (dolist (k (plist-get params :after))
                  (let* ((v (vconcat (kbd k)))
                         (c (key-binding v t)))
                    (when c
                      (setq last-command nvb--last-command)
                      (nvb--run-command c v nil))))))))
      ;; Any error or quit from the command still returns the state below, so
      ;; Neovim sees what the command changed before it failed.
      ((debug error quit) (setq err (error-message-string e))))
    (nvb--run-idle-timers)
    (nvb--state (append (when err (list :error err))
                        (unless (cl-every #'eq marks (nvb--marks)) (list :jumped t))))))

(defun nvb--marks ()
  "The newest entries of the mark rings, compared by identity (edits move
markers, a push makes a new one): a command that pushes one (org-goto,
following a link, M-<) jumps, which Neovim records in its jumplist."
  (list (and (mark t) t) ; the first push-mark sets the mark without adding a ring entry
        (car mark-ring) (car global-mark-ring)
        (car (bound-and-true-p org-mark-ring))))

(defun nvb--reveal (buf ranges)
  "Show the lines of RANGES ((FIRST LAST) per fold, as sent) in BUF: Neovim
opened those folds itself (a search, :normal! zo)."
  (with-current-buffer buf
    (when (and ranges (derived-mode-p 'org-mode))
      (nvb--in-view
       (save-excursion
         (pcase-dolist (`(,first ,last) ranges)
           (nvb--fold-lines first last nil)))))))

(defconst nvb--widening-commands '(widen org-toggle-narrow-to-subtree)
  "Commands that may run with the cursor outside the restriction.")

(defun nvb--check-in-restriction (pos cmd)
  "Refuse CMD when Neovim's cursor POS is outside the buffer's restriction.
Neovim shows the whole file, so the cursor can be on text Emacs has
narrowed away; Emacs would run CMD at the restriction's edge instead.
A widening CMD may run: then t, POS being outside."
  (when (and pos (buffer-narrowed-p) (not (<= (point-min) pos (point-max))))
    (unless (memq cmd nvb--widening-commands)
      (user-error "Cursor is outside the narrowed region (C-x n w widens)"))
    t))

(defconst nvb--item-region-commands
  '(org-toggle-checkbox org-ctrl-c-ctrl-c org-ctrl-c-star org-ctrl-c-minus)
  "Commands that act on every item or line starting before the region's end,
including one starting exactly there.")

(defun nvb--trim-line-region (cmd)
  "End a region of whole lines (Neovim's linewise Visual mode sends one that
stops where the next line starts) at the end of its last line, for CMD in
`nvb--item-region-commands', which would take in the next line too, and
in read-only buffers (Magit would stage it). Others (sorting) need the
final newline."
  (when (and mark-active (or buffer-read-only (memq cmd nvb--item-region-commands)))
    (let ((beg (region-beginning))
          (end (region-end)))
      (when (and (> end beg)
                 (save-excursion (goto-char beg) (bolp))
                 (save-excursion (goto-char end) (bolp)))
        (if (= (point) end)
            (backward-char)
          (set-marker (mark-marker) (1- end)))))))

(defconst nvb--idle-timer-max-delay 1.0
  "Idle timers with at most this delay run after each command, as they
would while the user pauses (e.g. `org-indent-mode' sets up prefixes in
one). Batch Emacs never goes idle on its own.")

(defun nvb--run-idle-timers ()
  (dolist (timer (copy-sequence timer-idle-list))
    (when (<= (float-time (timer--time timer)) nvb--idle-timer-max-delay)
      (timer-event-handler timer))))

(defun nvb-rpc-sync (params)
  "Take Neovim's text for edited mirrors; report them, and the base buffer
of an indirect one (capture's edits are its target's)."
  (nvb--apply-syncs (plist-get params :syncs))
  (let ((bufs (mapcar (lambda (s) (nvb--buffer (plist-get s :id))) (plist-get params :syncs))))
    (dolist (b bufs)
      (when (buffer-base-buffer b) (cl-pushnew (buffer-base-buffer b) bufs)))
    (list :buffers (vconcat (mapcar #'nvb--buffer-state bufs)))))

(defun nvb-rpc-refresh (params)
  "Take Neovim's edits and report the state, for changes Emacs made
outside a request. Unlike `nvb-rpc-exec', Emacs's windows stay as they are."
  (setq nvb--unpulled nil)
  (nvb--apply-syncs (plist-get params :syncs))
  (nvb--state))

(defun nvb-rpc-bounds (params)
  "[FIRST LAST] (0-based lines) of the org :subtree or :element at POINT in
buffer ID, for Neovim's text objects, or nil if empty. With INNER, a
subtree loses its heading; an element keeps only its contents (a block's
lines between its delimiters) without the blank lines after it."
  (with-current-buffer (nvb--buffer (plist-get params :id))
    (nvb--in-view
     (save-excursion
       (goto-char (nvb--pos (plist-get params :point)))
       (let ((inner (plist-get params :inner)))
         (pcase-let ((`(,beg . ,end)
                      (if (equal (plist-get params :what) "subtree")
                          (progn (org-back-to-heading t)
                                 (cons (if inner (line-beginning-position 2) (point))
                                       (progn (org-end-of-subtree t t) (point))))
                        (nvb--element-bounds (org-element-at-point) inner))))
           (when (< beg end)
             (vector (1- (line-number-at-pos beg)) (1- (line-number-at-pos (1- end)))))))))))

(defun nvb--element-bounds (element inner)
  "(BEG . END) of ELEMENT, or of its INNER part (see `nvb-rpc-bounds')."
  (let ((beg (org-element-property :begin element))
        (end (org-element-property :end element)))
    (if (not inner)
        (cons beg end)
      (let ((end (save-excursion
                   (goto-char end)
                   (forward-line (- (or (org-element-property :post-blank element) 0)))
                   (point))))
        (cond ((org-element-property :contents-begin element)
               (cons (org-element-property :contents-begin element)
                     (min end (org-element-property :contents-end element))))
              ((string-suffix-p "-block" (symbol-name (org-element-type element)))
               (cons (save-excursion (goto-char beg) (line-beginning-position 2))
                     (save-excursion (goto-char end) (line-beginning-position 0))))
              (t (cons beg end)))))))

(defun nvb-rpc-spans (params)
  "Faces and concealed text for buffer ID's lines in RANGES, [[L1 L2] ...]."
  (with-current-buffer (nvb--buffer (plist-get params :id))
    (let* ((ranges (plist-get params :ranges))
           (spans (cl-mapcan (lambda (r) (nvb--spans (car r) (cadr r))) ranges))
           (prefixes (apply #'vconcat (mapcar (lambda (r) (nvb--line-prefixes (car r) (cadr r))) ranges)))
           (margins (apply #'vconcat (mapcar (lambda (r) (nvb--margin-strings (car r) (cadr r))) ranges))))
      (list :spans (vconcat (mapcar #'vconcat spans))
            :prefixes prefixes
            :margins margins
            :faces (nvb--new-faces (append (nvb--span-faces spans)
                                           (seq-map (lambda (p) (aref p 2)) prefixes)
                                           (seq-mapcat (lambda (m) (seq-map (lambda (r) (aref r 1)) (aref m 1)))
                                                       margins)))
            :tick (buffer-chars-modified-tick)))))

(defun nvb-rpc-rename (params)
  "Neovim renamed buffer ID's file (`:saveas', `:file')."
  (with-current-buffer (nvb--buffer (plist-get params :id))
    (set-visited-file-name (plist-get params :file) t)
    (set-buffer-modified-p (plist-get params :modified)))
  t)

(defun nvb-rpc-saved (params)
  (with-current-buffer (nvb--buffer (plist-get params :id))
    (set-buffer-modified-p nil)
    (set-visited-file-modtime))
  t)

(defun nvb-rpc-close (params)
  "Kill buffer ID's mirror. A file emacsclient waits on (a commit message)
is done instead, as quitting git's editor is: cancelled if Neovim dropped
unsaved changes (:MODIFIED), else finished with what Neovim saved. Kill
hooks may clock out, so the reply has the new :modeline."
  (let ((buf (gethash (plist-get params :id) nvb--mirrors)))
    (remhash (plist-get params :id) nvb--mirrors)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq nvb--id nil)
        ;; No kill or save prompt; but an indirect buffer (capture) shares
        ;; its base's flag, which must stay for the base to be saved.
        (unless (buffer-base-buffer) (set-buffer-modified-p nil))
        (cond ((not (bound-and-true-p server-buffer-clients)) (kill-buffer buf))
              ;; with-editor's buffers refuse to be killed but by its own commands.
              ((bound-and-true-p with-editor-mode)
               ;; It puts back the windows from before the edit (even if
               ;; it then fails): Neovim takes them as after C-c C-c.
               (setq nvb--unpulled t)
               (nvb--send (list :method "changed"))
               (if (plist-get params :modified) (with-editor-cancel nil) (with-editor-finish nil)))
              (t (server-done))))))
  (list :modeline (nvb--mode-line-extras)))

(defun nvb--format-simple (spec)
  "SPEC (a mode-line construct) as text. `format-mode-line' yields \"\" in
batch, so handle the usual constructs: strings, variables holding them,
lists, (:eval FORM), (:propertize ELT ...) and (VAR THEN ELSE)."
  (substring-no-properties
   (cond ((stringp spec) (string-replace "%%" "%" spec))
         ;; Keywords and t evaluate to themselves.
         ((and (symbolp spec) spec (not (keywordp spec)) (not (eq spec t)) (boundp spec))
          (nvb--format-simple (symbol-value spec)))
         ((and (consp spec) (eq (car spec) :eval)) (nvb--format-simple (eval (cadr spec) t)))
         ((and (consp spec) (eq (car spec) :propertize)) (nvb--format-simple (cadr spec)))
         ((and (consp spec) (symbolp (car spec)) (car spec) (not (keywordp (car spec))))
          (nvb--format-simple (if (and (boundp (car spec)) (symbol-value (car spec)))
                                  (cadr spec)
                                (caddr spec))))
         ((consp spec) (mapconcat #'nvb--format-simple spec ""))
         (t ""))))


(defun nvb--new-kill ()
  "The newest kill (C-c C-x M-w, C-w...) if Neovim hasn't had it, for its
unnamed register."
  (let ((k (car kill-ring)))
    (if (or (null k) (eq k nvb--kill-sent))
        :false
      (setq nvb--kill-sent k)
      (substring-no-properties k))))

(defun nvb--mode-line-extras ()
  "What modes add to the mode line (`global-mode-string'), e.g. the org clock."
  (string-trim (nvb--format-simple global-mode-string)))

(defun nvb-rpc-modeline (_params)
  (nvb--mode-line-extras))

(defun nvb--date-parse (text)
  "What the pending org date prompt makes of TEXT (a decoded time), or nil
while it doesn't parse (half typed): org's own preview shows nothing then."
  ;; org-read-date binds only some of these in each flow.
  (let ((ans (concat text " " (or (bound-and-true-p org-ans1) (bound-and-true-p org-ans2))))
        (org-end-time-was-given nil))
    (condition-case nil (org-read-date-analyze ans org-def org-defdecode)
      (error nil))))

(defun nvb--calendar-date (decoded)
  "DECODED time as a calendar date (MONTH DAY YEAR)."
  (list (decoded-time-month decoded) (decoded-time-day decoded) (decoded-time-year decoded)))

(defun nvb-rpc-date_move (params)
  "Run calendar COMMAND (what a key in org's date prompt runs, e.g.
calendar-forward-month) from the date TEXT parses to, in a calendar
showing VIEW. Return {text: the new date, keeping TEXT's time; view}."
  (let ((f (or (nvb--date-parse (plist-get params :text)) (decode-time org-def))))
    (nvb--in-calendar
     (nvb--calendar-date f) (plist-get params :view)
     (lambda ()
       (call-interactively (intern (plist-get params :command)))
       (pcase-let ((`(,month ,day ,year) (calendar-cursor-to-date t)))
         (setf (decoded-time-day f) day
               (decoded-time-month f) month
               (decoded-time-year f) year))
       (list :text (format-time-string (if (bound-and-true-p org-time-was-given)
                                           "%Y-%m-%d %H:%M" "%Y-%m-%d")
                                       (org-encode-time f))
             :view (vector displayed-month displayed-year))))))

(defun nvb-rpc-date_preview (params)
  "What the pending org date prompt makes of TEXT, as org shows live in its
minibuffer (`org-read-date-display'): {text: \"=> <2026-11-09 Mon>\",
calendar: LINES, cursor: [LINE COL], view}, the calendar org pops up
(showing VIEW when the date is in it) with the date's day number at
CURSOR (0-based; two columns wide). Text that doesn't parse yet gives
{text: \"\"}."
  (let ((f (nvb--date-parse (plist-get params :text))))
    (if (null f)
        (list :text "")
      (cons :text
            (cons (nvb--date-preview-text f)
                  (nvb--in-calendar (nvb--calendar-date f) (plist-get params :view)
                                    #'nvb--calendar-lines))))))

(defun nvb--in-calendar (date view fn)
  "FN's value, called in Emacs's three-month calendar around VIEW, (MONTH
YEAR), with the cursor on DATE, (MONTH DAY YEAR). Without VIEW, or when
DATE isn't in it, the calendar is around DATE, as `calendar-goto-date'
moves it."
  ;; A calendar of our own, shown for its commands (they read the window),
  ;; so a calendar org has up is left alone.
  (let ((calendar-buffer " *nvb-calendar*"))
    (save-window-excursion
      (switch-to-buffer (get-buffer-create calendar-buffer) t)
      (unwind-protect
          (let ((inhibit-read-only t))
            (calendar-mode)
            (apply #'calendar-generate-window (or view (list (car date) (nth 2 date))))
            (unless (calendar-date-is-visible-p date)
              (calendar-generate-window (car date) (nth 2 date)))
            (calendar-cursor-to-visible-date date)
            (funcall fn))
        (kill-buffer)))))

(defun nvb--calendar-lines ()
  "The calendar's :calendar lines, the cursor's :cursor and its months' :view."
  (list :calendar (vconcat (mapcar #'string-trim-right (split-string (buffer-string) "\n" t)))
        :cursor (vector (1- (line-number-at-pos)) (1- (current-column)))
        :view (vector displayed-month displayed-year)))

(defun nvb--date-preview-text (f)
  (let* ((fmt (org-time-stamp-format (or (bound-and-true-p org-with-time)
                                         (bound-and-true-p org-time-was-given))
                                     (bound-and-true-p org-read-date-inactive)))
         (txt (concat "=> " (format-time-string fmt (org-encode-time f)))))
    (if (bound-and-true-p org-read-date-analyze-futurep) (concat txt " (=>F)") txt)))

(defun nvb-rpc-eval (params)
  "Evaluate EXPR in buffer ID (Neovim's current buffer), as M-: does in
the selected buffer, and return the value printed."
  (with-current-buffer (if (plist-get params :id) (nvb--buffer (plist-get params :id)) (current-buffer))
    (format "%S" (eval (car (read-from-string (plist-get params :expr))) t))))

(defun nvb-rpc-quit (_params)
  "Exit, running `kill-emacs-hook' (bookmarks, org-persist). Neovim is not
answering during shutdown, so input goes back to Emacs's own readers;
with stdin closed, any prompt fails instead of hanging."
  (nvb-uninstall)
  (kill-emacs 0))

(defun nvb-point-moved ()
  "What Emacs's line motions do besides moving, for a Neovim motion: in the
agenda, follow mode shows the entry at point (`org-agenda-next-line' calls
`org-agenda-do-context-action' itself; no hook does)."
  (interactive)
  (when (derived-mode-p 'org-agenda-mode) (org-agenda-do-context-action)))

(defun nvb-auto-fill (column)
  "Fill as typing a space before point does in Emacs, with `fill-column'
COLUMN (Neovim's 'textwidth'), so org's rules decide: no break inside a
timestamp, none in a fixed-width line."
  (interactive "p")
  (let ((fill-column column))
    (funcall normal-auto-fill-function)))

(defun nvb-align-tags ()
  "Realign the heading's tags, as typing in it would have in Emacs."
  (interactive)
  (org-align-tags))

;;; Commands behind Neovim's fold keys (zo, zc, ...) in org buffers, so
;;; folding stays Emacs's state rather than diverging in Neovim.

(defun nvb--at-drawer-p ()
  (save-excursion (beginning-of-line) (looking-at-p org-drawer-regexp)))

(defun nvb-fold-open ()
  "Like zo: open the drawer at point, or show the entry and its children."
  (interactive)
  (if (nvb--at-drawer-p)
      (org-fold-hide-drawer-toggle 'off)
    (org-fold-show-entry)
    (org-fold-show-children)))

(defun nvb-fold-toggle ()
  "Like za: toggle the drawer at point, or open the current subtree if it
is folded and fold it otherwise."
  (interactive)
  (cond ((nvb--at-drawer-p) (org-fold-hide-drawer-toggle nil))
        ((save-excursion (org-back-to-heading t) (org-fold-folded-p (line-end-position)))
         (nvb-fold-open))
        (t (org-fold-hide-subtree))))

;;; Input from Neovim. Emacs's own readers would read stdin in batch mode.

(defun nvb--menu-window ()
  "The window of the menu Emacs popped up, if any. Usually the selected
window; help shown with `with-output-to-temp-buffer' (clock resolution)
and transient's popup are in another."
  (seq-find (lambda (w)
              (let ((b (window-buffer w)))
                ;; Org's menus are internal (" *Org todo*"); only the
                ;; bridge's placeholder is never a menu.
                (not (or (buffer-file-name b) (buffer-local-value 'nvb--id b)
                         (equal (buffer-name b) nvb--placeholder)))))
            (cons (selected-window) (window-list nil 'never))))

(defun nvb--context ()
  "The menu Emacs popped up, if any, as a plist: :context TEXT,
:context_spans faces as in `nvb--spans', :context_top the first line its
window shows (SPC scrolls long menus) and new :faces."
  (let ((win (nvb--menu-window)))
    (when win
      (with-current-buffer (window-buffer win)
        (let ((spans (nvb--spans 0 (count-lines (point-min) (point-max)))))
          (list :context (buffer-substring-no-properties (point-min) (point-max))
                :context_spans (vconcat (mapcar #'vconcat spans))
                :context_top (1- (line-number-at-pos (window-start win)))
                :faces (nvb--new-faces (nvb--span-faces spans))))))))

(defun nvb--prompt-string (prompt)
  (if (stringp prompt) (substring-no-properties prompt) ""))

(defun nvb--timed-wait-p (prompt seconds)
  "Whether a read is a pause (`sit-for'), not a question for the user.
A timed read with a prompt is a question with a timeout (org-clock-resolve
asks every 45s in a loop): Neovim must ask it, or Emacs waits forever."
  (and seconds (string-empty-p (nvb--prompt-string prompt))))

(defun nvb--read-event (orig &optional prompt inherit seconds)
  "Read a key from Neovim; pauses just wait, as Neovim never has input
pending for Emacs."
  (if (nvb--timed-wait-p prompt seconds)
      (funcall orig prompt inherit seconds)
    (nvb--read-key-now prompt)))

(defun nvb--read-key-now (prompt)
  (if unread-command-events
      ;; A key a command put back to be read again (transient's "-"); (t
      ;; . KEY) is one not to record.
      (let ((ev (pop unread-command-events)))
        (if (memq (car-safe ev) '(t no-record)) (cdr ev) ev))
    ;; Commands like `org-emphasize' put their prompt in the echo area and
    ;; call `read-char-exclusive' with none.
    (let* ((prompt (nvb--prompt-string prompt))
           (prompt (if (and (string-empty-p prompt) nvb--messages)
                       ;; Reading a key clears the echo area in Emacs.
                       (pop nvb--messages)
                     prompt))
           (k (or (pop nvb--pending-keys)
                  (condition-case nil
                      (nvb--request "read_key" (append (list :prompt prompt) (nvb--context)))
                    ;; Readers that bind `inhibit-quit' (org's fast tag and
                    ;; TODO menus) handle C-g themselves, cleaning up as they go.
                    (quit (if inhibit-quit "C-g" (signal 'quit nil)))))))
      (aref (kbd k) 0))))

(defun nvb--read-char (orig &optional prompt inherit seconds)
  (if (nvb--timed-wait-p prompt seconds)
      (funcall orig prompt inherit seconds)
    (let ((ev (nvb--read-key-now prompt)))
      (cond ((characterp ev) ev)
            ((eq ev 'return) ?\r)
            ((eq ev 'tab) ?\t)
            ((eq ev 'escape) ?\e)
            ((eq ev 'backspace) ?\d)
            (t ev)))))

(defun nvb--first (x)
  "X, or its car when X is a list (Emacs's INITIAL/DEFAULT forms)."
  (if (consp x) (car x) x))

(defvar crm-completion-table)

(defvar nvb--minibuffer-depth 0 "Minibuffers the bridge stands in for.")

(defun nvb--minibuffer-depth (orig) (+ (funcall orig) nvb--minibuffer-depth))

(defun nvb--minibuffer-completion ()
  "(TABLE . PREDICATE) a reader set up for this minibuffer, if any.
completing-read-multiple (org tags) sets its table buffer-locally from
`minibuffer-setup-hook', so run that in a scratch buffer to see it."
  (with-temp-buffer
    (run-hooks 'minibuffer-setup-hook)
    (when minibuffer-completion-table
      (let ((table minibuffer-completion-table)
            (crm-table (bound-and-true-p crm-completion-table)))
        (cons (if crm-table
                  ;; crm's table reads its buffer-local `crm-completion-table'.
                  (lambda (string pred action)
                    (let ((crm-completion-table crm-table))
                      (funcall table string pred action)))
                table)
              minibuffer-completion-predicate)))))

(defconst nvb--max-history 100 "Most history items sent with a prompt.")

(defun nvb--history-symbol (hist)
  "The history variable of a reader's HIST argument (SYM or (SYM . POS))."
  (let ((sym (if (consp hist) (car hist) (or hist 'minibuffer-history))))
    (unless (eq sym t) sym)))

(defun nvb--history (hist)
  "HIST's items, newest first, for Neovim's prompt history."
  (let ((sym (nvb--history-symbol hist)))
    (vconcat (seq-take (seq-filter #'stringp (and sym (boundp sym) (symbol-value sym)))
                       nvb--max-history))))

(defun nvb--remember (hist answer)
  "Add ANSWER to HIST, as Emacs's own readers do."
  (let ((sym (nvb--history-symbol hist)))
    (when (and sym (not (string-empty-p answer)))
      (add-to-history sym answer))))

(defun nvb--read-from-minibuffer (prompt &optional initial _keymap read hist default &rest _)
  (let* ((init (nvb--first initial))
         (def (nvb--first default))
         (nvb--minibuffer-depth 1)
         (nvb--completion (nvb--minibuffer-completion))
         (s (unwind-protect
                (nvb--request "read_string"
                              (append (list :prompt (nvb--prompt-string prompt)
                                            :initial init
                                            :default def
                                            :history (nvb--history hist))
                                      (when nvb--completion
                                        (list :completion "customlist,EmacsComplete"))
                                      ;; Inside org-read-date: Neovim previews the date as you type.
                                      (when (bound-and-true-p org-defdecode) (list :date t))))
              ;; Pairs the setup hook run above (transient takes its keymap back).
              (with-temp-buffer (run-hooks 'minibuffer-exit-hook)))))
    (nvb--remember hist s)
    (when (and (string-empty-p s) def (not read))
      (setq s def))
    (if read (car (read-from-string s)) s)))

(defun nvb-rpc-complete (params)
  "Completions of PREFIX in the pending `completing-read', as whole strings.
Tables with boundaries (outline paths \"A/B\") complete one segment at a
time; the text before the boundary is put back on each candidate."
  (let* ((prefix (plist-get params :prefix))
         (coll (car nvb--completion))
         (pred (cdr nvb--completion))
         ;; What TAB inserts first; tables that keep text the candidates
         ;; drop (the agenda filter's "-tag") only show it here.
         (try (try-completion prefix coll pred))
         ;; Emacs's completion styles (partial-completion: "pro/P/Ta").
         (all (completion-all-completions prefix coll pred (length prefix)))
         (last (last all))
         (base (or (cdr last) 0))
         (head (substring prefix 0 base)))
    (when last (setcdr last nil))
    (if (and (stringp try) (> (length try) (length prefix)))
        (vector try)
     (vconcat (seq-take (delete-dups (mapcar (lambda (c) (concat head (substring-no-properties c)))
                                            all))
                       nvb--max-candidates)))))

(defun nvb--completing-read (prompt collection &optional predicate require-match
                                    initial hist default &rest _)
  (let* ((nvb--completion (cons collection predicate))
         (init (nvb--first initial))
         (cands (all-completions (or init "") collection predicate))
         (def (nvb--first default))
         (ask (lambda ()
                (nvb--request "completing_read"
                              (list :prompt (nvb--prompt-string prompt)
                                    :candidates (vconcat (seq-take cands nvb--max-candidates))
                                    :require_match (nvb--bool (and require-match (not (eq require-match 'confirm-after-completion))))
                                    :initial init
                                    :default def
                                    :history (nvb--history hist)))))
         (s (funcall ask)))
    ;; As RET in Emacs's minibuffer (`minibuffer-complete-and-exit'): with
    ;; REQUIRE-MATCH t an answer is first completed ("B" to "B/"), and
    ;; refused if that gives no exact match; an empty one is the default.
    (while (and (eq require-match t) (not (string-empty-p s))
                (not (setq s (nvb--complete-exactly s collection predicate))))
      (message "[No match]")
      (setq s (funcall ask)))
    (nvb--remember hist s)
    (if (and (string-empty-p s) def) def s)))

(defun nvb--complete-exactly (s collection predicate)
  "S, or what completing it with the completion styles gives, if that is
an exact match in COLLECTION; else nil."
  (if (test-completion s collection predicate)
      s
    (let ((c (completion-try-completion s collection predicate (length s))))
      (cond ((eq c t) s)
            ((and (consp c) (test-completion (car c) collection predicate)) (car c))))))

(defun nvb--read-string (prompt &optional initial hist default _inherit)
  "`read-string' is C and calls the C `read-from-minibuffer', missing advice."
  (nvb--read-from-minibuffer prompt initial nil nil hist default))

(defun nvb--read-file-name (prompt &optional dir default _mustmatch initial _pred)
  (let ((s (nvb--request "read_string"
                         (list :prompt (nvb--prompt-string prompt)
                               :initial (or initial (abbreviate-file-name (or dir default-directory)))
                               :default (nvb--first default)
                               :completion "file"))))
    (expand-file-name s dir)))

(defun nvb--y-or-n-p (prompt)
  (nvb--request "confirm" (list :prompt (nvb--prompt-string prompt))))

(defun nvb--yes-or-no-p (prompt)
  "Answered by typing yes or no, as in Emacs: these guard risky actions.
With `use-short-answers', y or n, as Emacs then asks."
  (nvb--request "confirm" (list :prompt (nvb--prompt-string prompt)
                                :typed (nvb--bool (not use-short-answers)))))

(defun nvb--read-passwd (prompt &rest _)
  (nvb--request "read_string" (list :prompt (nvb--prompt-string prompt) :secret t)))

(defun nvb--visited-file ()
  "The file the current buffer visits. Org's edit buffers (footnotes via
C-c ') borrow their org file's name without visiting it."
  (unless (bound-and-true-p org-src-mode) (buffer-file-name)))

(defun nvb--save-buffer (&rest _)
  "Have Neovim write the current file buffer; Neovim owns all file writes.
Like `basic-save-buffer', an indirect buffer saves its base buffer."
  (with-current-buffer (or (buffer-base-buffer) (current-buffer))
    (let ((file (nvb--visited-file)))
      (when (and file (buffer-modified-p))
        ;; As `basic-save-buffer' does (an archive file in a new directory).
        (let ((dir (file-name-directory file)))
          (unless (file-exists-p dir)
            (if (y-or-n-p (format-message "Directory `%s' does not exist; create? " dir))
                (make-directory dir t)
              (error "Canceled"))))
        (let ((text (nvb--whole-text)))
          (nvb--request "save" (list :id (nvb--mirror-id (current-buffer))
                                     :file file
                                     :text text))
          (nvb--shadow-text text)
          (setq nvb--tick (buffer-chars-modified-tick)))
        (set-buffer-modified-p nil)
        (set-visited-file-modtime))))
  t)

(defvar nvb--widths (make-hash-table :test #'equal)
  "Neovim's display width of strings, cached.")

(defun nvb--visible-text (string)
  "STRING without the parts invisible in the current buffer (ignoring folds),
as `org-string-width' counts them."
  (let ((spec (if (listp buffer-invisibility-spec)
                  (seq-remove (lambda (el)
                                (memq (if (consp el) (car el) el)
                                      '(org-fold-drawer org-fold-block org-fold-outline)))
                              buffer-invisibility-spec)
                buffer-invisibility-spec)))
    (with-temp-buffer
      (setq buffer-invisibility-spec spec)
      (insert string)
      (let (chars)
        (dotimes (i (length string))
          (unless (invisible-p (1+ i)) (push (aref string i) chars)))
        (concat (nreverse chars))))))

(defun nvb--org-string-width (orig string &optional pixels)
  "Measure non-ASCII text as Neovim will draw it, so org aligns tables and
tags for Neovim's screen (emoji sequences differ between the two)."
  (if (or pixels (null nvb--conn) (not (string-match-p "[^\t\n -~]" string)))
      (funcall orig string pixels)
    (let ((visible (nvb--visible-text string)))
      (or (gethash visible nvb--widths)
          (puthash visible (nvb--request "strwidth" (list :s visible)) nvb--widths)))))

(defun nvb--message (orig fmt &rest args)
  "Collect a command's messages for its reply; send others (timers, like a
finished countdown) to Neovim at once."
  (let ((s (apply orig fmt args)))
    (when (and s (not (string-empty-p s)))
      (if nvb--in-request
          (push (substring-no-properties s) nvb--messages)
        (when (process-live-p nvb--conn)
          (nvb--send (list :method "message" :params (list :text (substring-no-properties s)))))))
    s))

(defun nvb--spec-arg-forms (spec)
  "Lisp forms computing the arguments for the string interactive SPEC,
its prefix characters (* @ ^) stripped. `call-interactively' reads string
specs in C, which skips our advice and reads stdin in batch, so the bridge
evaluates them in Lisp instead."
  (let (forms)
    (dolist (item (split-string spec "\n" t))
      (let ((prompt (substring item 1)))
        (pcase (aref item 0)
          (?a (push `(intern (completing-read ,prompt obarray #'fboundp t)) forms))
          (?b (push `(read-buffer ,prompt (current-buffer) t) forms))
          (?B (push `(read-buffer ,prompt (other-buffer (current-buffer))) forms))
          (?c (push `(read-char ,prompt) forms))
          (?C (push `(intern (completing-read ,prompt obarray #'commandp t)) forms))
          (?d (push '(point) forms))
          (?D (push `(read-directory-name ,prompt) forms))
          (?e (push 'last-input-event forms))
          (?f (push `(read-file-name ,prompt nil nil t) forms))
          ((or ?F ?G) (push `(read-file-name ,prompt) forms))
          ((or ?k ?K) (push `(vector (read-key ,prompt)) forms))
          (?m (push '(mark) forms))
          ((or ?M ?s) (push `(read-string ,prompt) forms))
          (?n (push `(read-number ,prompt) forms))
          (?N (push `(if current-prefix-arg (prefix-numeric-value current-prefix-arg)
                       (read-number ,prompt))
                    forms))
          (?p (push '(prefix-numeric-value current-prefix-arg) forms))
          (?P (push 'current-prefix-arg forms))
          (?r (push '(region-beginning) forms) (push '(region-end) forms))
          (?S (push `(intern (read-string ,prompt)) forms))
          (?v (push `(intern (completing-read ,prompt obarray #'boundp t)) forms))
          (?x (push `(car (read-from-string (read-string ,prompt))) forms))
          (?X (push `(eval (car (read-from-string (read-string ,prompt))) t) forms))
          ((or ?i ?z ?Z ?U) (push nil forms))
          (code (error "nvim-bridge: unsupported interactive code %c" code)))))
    (nreverse forms)))

(defun nvb--call-interactively (orig function &optional record-flag keys)
  (let ((spec (and (commandp function) (cadr (interactive-form function)))))
    (if (not (stringp spec))
        (funcall orig function record-flag keys)
      (let ((prefix (substring spec 0 (string-match-p "[^*@^]\\|\\'" spec))))
        ;; * refuses a read-only buffer before any argument is read.
        (when (seq-contains-p prefix ?*) (barf-if-buffer-read-only))
        (apply #'funcall-interactively function
               (mapcar (lambda (f) (eval f t))
                       (nvb--spec-arg-forms (substring spec (length prefix)))))))))

(defun nvb--recursive-edit ()
  "Run a command loop that reads keys from Neovim (org-goto uses this)."
  (let ((val (catch 'exit
               (while t
                 (let* ((keys (nvb--complete-keys (vector (nvb--read-key-now ""))))
                        (cmd (key-binding keys t)))
                   (if cmd
                       (nvb--run-command cmd keys nil)
                     (message "%s is undefined" (key-description keys))))))))
    (cond ((eq val t) (signal 'quit nil))
          ((functionp val) (funcall val)))))

(defconst nvb--advice
  '((read-event :around nvb--read-event)
    (read-char :around nvb--read-char)
    (read-char-exclusive :around nvb--read-char)
    (read-key :override nvb--read-key-now)
    (read-from-minibuffer :override nvb--read-from-minibuffer)
    (read-string :override nvb--read-string)
    (minibuffer-depth :around nvb--minibuffer-depth)
    (read-passwd :override nvb--read-passwd)
    (y-or-n-p :override nvb--y-or-n-p)
    (yes-or-no-p :override nvb--yes-or-no-p)
    (window-max-chars-per-line :around nvb--window-max-chars-per-line)
    (message :around nvb--message)
    (font-lock-mode :around nvb--font-lock-mode)
    (call-interactively :around nvb--call-interactively)
    (recursive-edit :override nvb--recursive-edit)
    ;; Batch Emacs reads no keys: the raw keys are the ones the bridge ran
    ;; (transient 0.4 puts them back to read "-a").
    (this-single-command-raw-keys :override this-single-command-keys)
    (basic-save-buffer :override nvb--save-buffer)
    (org-string-width :around nvb--org-string-width)
    ;; Themes and custom-set-faces end up here too.
    (set-face-attribute :after nvb--faces-changed)
    (display-color-cells :override nvb--display-color-cells))
  "Advice routing Emacs's interaction through Neovim: (SYMBOL HOW FUNCTION).")

(defun nvb-uninstall ()
  (pcase-dolist (`(,sym ,_how ,fn) nvb--advice) (advice-remove sym fn))
  (setq completing-read-function #'completing-read-default
        read-file-name-function #'read-file-name-default))

(defun nvb--reveal-outline-maybe (orig region spec)
  "Org 9.6's check whether an outline fold is still valid signals for some
folds (one following no heading, at bob or after text before the first
heading; others the fuzzer keeps finding), and Emacs then drops the
buffer's after-change hooks, so org stops tracking folds. A fold the check
can't make sense of is broken: reveal it (t)."
  (condition-case nil
      (funcall orig region spec)
    (error t)))

(defun nvb--element-cache-after-change (orig &rest args)
  "Org 9.6's element cache can signal from its after-change hook
\(`number-or-marker-p' nil in `org-element--cache-process-request'), and
Emacs then drops all the buffer's after-change hooks. Reset the cache
instead, as org does when it finds it inconsistent."
  (condition-case err
      (apply orig args)
    (error
     (message "org-element cache reset after: %s" (error-message-string err))
     (org-element-cache-reset))))

(defun nvb-install ()
  "Route Emacs's user interaction through Neovim."
  (pcase-dolist (`(,sym ,how ,fn) nvb--advice)
    ;; Emacsen starting together may compile the same trampoline; the one
    ;; that finishes second fails to rename its file over the first's, and
    ;; then finds that one.
    (condition-case nil
        (advice-add sym how fn)
      (native-compiler-error (advice-add sym how fn))))
  ;; Org 9.6 workarounds: outside `nvb--advice' so they stay on through shutdown.
  (with-eval-after-load 'org-fold
    (advice-add 'org-fold--reveal-outline-maybe :around #'nvb--reveal-outline-maybe))
  (with-eval-after-load 'org-element
    (advice-add 'org-element--cache-after-change :around #'nvb--element-cache-after-change))
  ;; Batch Emacs starts without it, so commands ignored Neovim's selection.
  (transient-mark-mode 1)
  ;; org-id saves its locations on exit only when not in batch mode.
  (with-eval-after-load 'org-id
    (add-hook 'kill-emacs-hook #'org-id-locations-save))
  ;; Window configurations (capture restores one) must keep the pairing.
  (add-to-list 'window-persistent-parameters '(nvb-win . t))
  (setq completing-read-function #'nvb--completing-read
        read-file-name-function #'nvb--read-file-name
        org-read-date-popup-calendar nil
        ;; org-goto's outline interface navigates a buffer Neovim would only
        ;; see as a menu float; completing a path works naturally.
        org-goto-interface 'outline-path-completion
        make-backup-files nil
        auto-save-default nil
        create-lockfiles nil
        ;; Neovim reverts nothing: Emacs must never ask about stale files.
        revert-without-query '(".")
        ring-bell-function #'ignore))

(provide 'nvim-bridge)
;;; nvim-bridge.el ends here
