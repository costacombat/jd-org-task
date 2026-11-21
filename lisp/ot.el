;;; ot.el --- Org tasks from the shell  -*- lexical-binding: t; -*-

;; The core of `ot'. The `ot' script calls `ot-cli' in a small Emacs: a
;; daemon started with -Q, or a one-off `emacs -Q --batch'. Everything here
;; works on one Org file, given on each call, so one daemon serves any file.
;;
;; A task is a heading with a TODO state. Its id is the start of its `ID'
;; property (a UUID that `org-id' gives it), so it survives edits and moves.
;; A parent is named by its CUSTOM_ID or by the number its title starts
;; with: an ID like 11.11, or a work package like W0011 or W0011~11.11.
;;
;; Inboxes follow Johnny.Decimal's standard zeros, and extend-the-end below
;; them, narrowest first:
;;   work package  W0011+ Inbox   a sibling of W0011 (which then takes the
;;                                space form, W0011 11.11 Title)
;;   ID            11.11+ Inbox   a sibling of 11.11
;;   category      11.01
;;   area          10.01          (10-19's management category)
;;   system        00.01
;; The ID and work package ones are made on first use, as headings and,
;; when `ot-root' is set, as folders next to theirs on disk.

(require 'org)
(require 'org-id)
(require 'json)
(require 'subr-x)

;; Leave no trace outside the task file: no backups, no global id table.
(setq make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      org-id-track-globally nil)

(defvar ot-id-length 8
  "How many characters of a task's ID `ot' prints.")

(defvar ot-cwd nil
  "The caller's working folder: it picks the default inbox. nil to not.")

(defvar ot-root nil
  "The Johnny.Decimal root on disk, or nil. With it, `ot' also makes the
`+ Inbox' folders and renames work package folders, as it does headings.")

;; States for a file with no #+TODO line of its own. Put the same line in
;; the file (or this setting in your Emacs) so your Emacs agrees:
;;   #+TODO: TODO NEXT WAIT | DONE CANCELLED
(setq org-todo-keywords
      '((sequence "TODO" "NEXT" "WAIT" "|" "DONE" "CANCELLED")))

;;; The file

(defun ot--buffer (file)
  "A buffer visiting FILE in Org mode, in step with the disk.
Another editor may have changed the file since the last call."
  (let ((buf (or (find-buffer-visiting file)
                 (progn
                   (unless (file-exists-p file)
                     (make-directory (file-name-directory file) t)
                     (write-region "" nil file))
                   (find-file-noselect file)))))
    (with-current-buffer buf
      (unless (verify-visited-file-modtime buf)
        (revert-buffer t t t))
      (unless (derived-mode-p 'org-mode) (org-mode)))
    buf))

(defun ot--save ()
  (let ((inhibit-message t)) (save-buffer)))

;;; Finding headings

(defun ot--title ()
  (org-get-heading t t t t))

(defun ot--parse-under (spec)
  "Split SPEC into (NUMBER . ADDRESS): \"W0011~11.11\" is (\"W0011\" . \"11.11\")."
  (if (string-match "\\`\\([^~ ]+\\)[~ ]\\(.+\\)\\'" spec)
      (cons (match-string 1 spec) (match-string 2 spec))
    (cons spec nil)))

(defun ot--goto-under (spec)
  "Move to the heading SPEC names, or signal an error."
  (pcase-let* ((`(,num . ,addr) (ot--parse-under spec))
               (pos (or (org-find-property "CUSTOM_ID" num)
                        (ot--find-title num))))
    (unless pos (user-error "No heading %s in %s" num (buffer-file-name)))
    (goto-char pos)
    (when addr
      (let ((title (ot--title)))
        (unless (string-match-p
                 (concat "\\`" (regexp-quote num) "[~ ]" (regexp-quote addr) "\\b")
                 title)
          (user-error "%s is \"%s\", not under %s" num title addr))))
    (point)))

(defun ot--find-title (num)
  "The position of the first heading whose title starts with NUM."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (while (re-search-forward org-heading-regexp nil t)
        (beginning-of-line)
        (when (string-match-p (concat "\\`" (regexp-quote num) "\\([ ~]\\|\\'\\)")
                              (ot--title))
          (throw 'found (point)))
        (end-of-line))
      nil)))

(defun ot--goto-inbox (name)
  "Move to the heading NAME (its CUSTOM_ID, number or title), making a
top-level one at the end if there is none."
  (goto-char (point-min))
  (let ((pos (or (org-find-property "CUSTOM_ID" name)
                 (ot--find-title name)
                 (org-find-exact-headline-in-buffer name nil t))))
    (if pos
        (goto-char pos)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "* " name "\n")
      (forward-line -1))
    (point)))

(defun ot--goto-task (id)
  "Move to the task whose ID starts with ID."
  (let (hits)
    (org-map-entries
     (lambda ()
       (let ((full (org-entry-get nil "ID")))
         (when (and full (org-get-todo-state) (string-prefix-p id full))
           (push (point) hits)))))
    (pcase (length hits)
      (0 (user-error "No task %s" id))
      (1 (goto-char (car hits)))
      (_ (user-error "%s matches %d tasks: give more of its id" id (length hits))))))

;;; Inboxes

(defun ot--kind (spec)
  "What SPEC names: (area \"10\"), (category \"11\"), (id \"11.11\"),
or (wp \"W0011\" SPEC)."
  (cond
   ((member spec '("system" "00" "00.01")) (list 'category "00"))
   ((string-match "\\`\\([0-9]\\)[0-9]-[0-9][0-9]\\'" spec)
    (list 'area (concat (match-string 1 spec) "0")))
   ((string-match "\\`[0-9][0-9]\\'" spec) (list 'category spec))
   ((string-match "\\`\\([0-9][0-9]\\)\\.01\\'" spec)
    (list 'category (match-string 1 spec)))
   ((string-match "\\`\\([0-9][0-9]\\.[0-9][0-9]\\)\\+?\\'" spec)
    (list 'id (match-string 1 spec)))
   ((string-match "\\`\\(W[0-9]+\\)\\(?:\\+\\|[~ ].*\\)?\\'" spec)
    (list 'wp (match-string 1 spec) (string-remove-suffix "+" spec)))))

(defun ot--goto-number (num)
  (let ((pos (or (org-find-property "CUSTOM_ID" num) (ot--find-title num))))
    (and pos (goto-char pos))))

(defun ot--goto-in (spec)
  "Move to the inbox for SPEC, making an ID's or work package's if needed."
  (pcase (or (ot--kind spec)
             (user-error "Not a system, area, category, ID or work package: %s" spec))
    ((or `(area ,c) `(category ,c))
     (let ((num (concat c ".01")))
       (unless (ot--goto-number num)
         (user-error "No %s Inbox in %s: declare it and run jd scaffold"
                     num (buffer-file-name)))))
    (`(id ,id)
     (ot--goto-under id)
     (ot--plus-inbox id))
    (`(wp ,wp ,spec)
     (ot--goto-under spec)
     (ot--space-form wp)
     (ot--plus-inbox wp)))
  (point))

(defun ot--disk (glob)
  "The one folder under `ot-root' that GLOB matches, or nil."
  (when ot-root
    (seq-find #'file-directory-p
              (file-expand-wildcards (expand-file-name glob ot-root)))))

(defun ot--plus-inbox (num)
  "Move to NUM's `+ Inbox' sibling, after the heading at point; make it if
it isn't there."
  (let ((cid (concat num "+Inbox"))
        (name (concat num "+ Inbox")))
    (unless (ot--goto-number cid)
      (let ((stars (make-string (org-current-level) ?*)))
        (org-end-of-subtree t t)
        (unless (bolp) (insert "\n"))
        (insert stars " " name "\n")
        (forward-line -1)
        (org-entry-put nil "CUSTOM_ID" cid)
        (let ((own (or (ot--disk (concat "*/*/" num " *"))
                       (ot--disk (concat "*/" num "[~ ]*")))))
          (when own
            (make-directory (expand-file-name name (file-name-directory own)) t)))))
    (point)))

(defun ot--space-form (wp)
  "Rename work package WP from `W0011~11.11 Title' to `W0011 11.11 Title',
in the heading at point and on disk: the form it takes once it has a `+'
sibling."
  (let ((title (ot--title)))
    (when (string-match (concat "\\`" (regexp-quote wp) "~") title)
      (org-edit-headline (concat wp " " (substring title (match-end 0))))
      (let ((old (ot--disk (concat "*/" wp "~*"))))
        (when old
          (rename-file old (expand-file-name
                            (concat wp " " (substring (file-name-nondirectory old)
                                                      (1+ (length wp))))
                            (file-name-directory old))))))))

(defun ot--context ()
  "The inbox `ot-cwd' points at: the deepest folder named like an area,
category, ID or work package, as a spec for `ot--goto-in'."
  (when ot-cwd
    (seq-some
     (lambda (dir)
       (cond
        ((string-match "\\`\\(W[0-9]+\\)[~ +]" dir) (match-string 1 dir))
        ((string-match "\\`\\([0-9][0-9]\\.[0-9][0-9]\\)[ +]" dir) (match-string 1 dir))
        ((string-match "\\`\\([0-9][0-9]\\) " dir) (match-string 1 dir))
        ((string-match "\\`\\([0-9][0-9]-[0-9][0-9]\\) " dir) (match-string 1 dir))))
     (reverse (split-string (directory-file-name (expand-file-name ot-cwd)) "/" t)))))

(defun ot--goto-default (inbox)
  "Where a task goes with no --in or --under: the inbox for `ot-cwd', else
INBOX (a spec or a heading's title), else 00.01, else an `Inbox' heading."
  (let ((spec (ot--context)))
    (cond
     (spec (ot--goto-in spec))
     ((and inbox (ot--kind inbox)) (ot--goto-in inbox))
     (inbox (ot--goto-inbox inbox))
     ((ot--goto-number "00.01") (point))
     (t (ot--goto-inbox "Inbox")))))

(defun ot--goto-target (args inbox)
  "Move to where ARGS' --under or --in says, or the default; return ARGS
without them."
  (pcase-let* ((`(,under ,args) (ot--take "--under" args))
               (`(,in ,args) (ot--take "--in" args)))
    (when (and under in) (user-error "Give --under or --in, not both"))
    (cond (under (ot--goto-under under))
          (in (ot--goto-in in))
          (t (ot--goto-default inbox)))
    args))

(defun ot--inbox-number ()
  "The inbox the heading at point is (\"00.01\", \"11.11+\"), or nil."
  (let ((title (ot--title)))
    (cond
     ((string-match "\\`\\([0-9][0-9]\\.01\\)\\( \\|\\'\\)" title) (match-string 1 title))
     ((string-match "\\`\\(\\(?:W[0-9]+\\|[0-9][0-9]\\.[0-9][0-9]\\)\\+\\) Inbox\\'" title)
      (match-string 1 title)))))

(defun ot--inbox-rank (num)
  "Sort order: system, areas, categories, IDs, work packages."
  (cond ((string= num "00.01") 0)
        ((string-match-p "\\`[0-9]0\\.01\\'" num) 1)
        ((string-match-p "\\.01\\'" num) 2)
        ((string-prefix-p "W" num) 4)
        (t 3)))

(defun ot--wp-address (wp)
  "The ID work package WP belongs to, from its heading's title."
  (save-excursion
    (when (ot--goto-number wp)
      (let ((title (ot--title)))
        (and (string-match "\\`W[0-9]+[~ ]\\([0-9][0-9]\\.[0-9][0-9]\\)" title)
             (match-string 1 title))))))

(defun ot--in-scope (num scope)
  "Is inbox NUM within SCOPE (a spec), or is SCOPE nil?"
  (or (null scope)
      (let ((where (if (string-prefix-p "W" num)
                       (or (ot--wp-address (string-remove-suffix "+" num)) "")
                     num)))
        (pcase (or (ot--kind scope) (user-error "Not a scope: %s" scope))
          (`(area ,c) (string-prefix-p (substring c 0 1) where))
          (`(category ,c) (string-prefix-p c where))
          (`(id ,id) (string-prefix-p id where))
          (`(wp ,wp ,_) (string= num (concat wp "+")))))))

(defun ot--inbox-ls (args)
  "Open tasks in every inbox within the scope in ARGS, broadest first."
  (let ((scope (car args)) (found '()))
    (org-map-entries
     (lambda ()
       (let ((num (ot--inbox-number)))
         (when (and num (ot--in-scope num scope))
           (let ((rank (ot--inbox-rank num)) (start (point)))
             (save-excursion
               (save-restriction
                 (org-narrow-to-subtree)
                 (goto-char start)
                 (while (outline-next-heading)
                   (let ((s (org-get-todo-state)))
                     (when (and s (not (member s org-done-keywords)))
                       (push (cons rank (cons (cons 'inbox num) (ot--task)))
                             found)))))))))))
    (mapcar #'cdr (sort (nreverse found) (lambda (a b) (< (car a) (car b)))))))

(defun ot--move (args inbox)
  "Move the task (ARGS' first item) --under a heading or --in an inbox."
  (unless (and args (or (member "--under" args) (member "--in" args)))
    (user-error "ot move takes a task id, and --under or --in"))
  (ot--goto-task (car args))
  (let ((id (org-entry-get nil "ID")))
    (org-cut-subtree)
    (ot--goto-target (cdr args) inbox)
    (let ((level (org-current-level)))
      (org-end-of-subtree t t)
      (unless (bolp) (insert "\n"))
      (org-paste-subtree (1+ level)))
    (goto-char (org-find-property "ID" id))
    (ot--save)
    (ot--task)))

;;; Tasks as data

(defun ot--parent ()
  "The nearest ancestor's CUSTOM_ID, else the number its title starts
with (11.11, W0012~11.12), else its title."
  (save-excursion
    (when (org-up-heading-safe)
      (or (org-entry-get nil "CUSTOM_ID")
          (let ((title (ot--title)))
            (if (string-match "\\`\\(W?[0-9][^ ]*\\) " title)
                (match-string 1 title)
              title))))))

(defun ot--task ()
  "The task at point, as an alist."
  (let ((id (org-entry-get nil "ID")))
    `((id . ,(if id (substring id 0 (min ot-id-length (length id))) ""))
      (state . ,(org-get-todo-state))
      (title . ,(ot--title))
      (under . ,(ot--parent))
      (deadline . ,(org-entry-get nil "DEADLINE"))
      (scheduled . ,(org-entry-get nil "SCHEDULED"))
      (file . ,(buffer-file-name))
      (line . ,(line-number-at-pos nil t)))))

(defun ot--table (tasks)
  (if (null tasks)
      ""
    (mapconcat
     (lambda (task)
       (let-alist task
         (format "%-8s  %-5s  %-16s  %-10s  %s"
                 .id .state
                 (if (stringp .deadline) .deadline "")
                 (if (stringp .under) .under "")
                 .title)))
     tasks "\n")))

;;; Commands

(defun ot--check-state (state)
  (unless (member state org-todo-keywords-1)
    (user-error "%s isn't a state in this file: %s"
                state (string-join org-todo-keywords-1 " "))))

(defun ot--take (flag args)
  "The value after FLAG in ARGS, and ARGS without them."
  (let ((tail (member flag args)))
    (if (not tail)
        (list nil args)
      (unless (cdr tail) (user-error "%s needs a value" flag))
      (list (cadr tail)
            (append (seq-take args (- (length args) (length tail))) (cddr tail))))))

(defun ot--strip-targets (args)
  (cadr (ot--take "--in" (cadr (ot--take "--under" args)))))

(defun ot--add (args inbox)
  (pcase-let* ((`(,due ,args) (ot--take "--due" args))
               (`(,state ,args) (ot--take "--state" args))
               (title (string-join (ot--strip-targets args) " ")))
    (when (string-empty-p title) (user-error "ot add needs a title"))
    (ot--check-state (or state "TODO"))
    (ot--goto-target args inbox)
    (let ((level (org-current-level)))
      (org-end-of-subtree t t)
      (unless (bolp) (insert "\n"))
      (insert (make-string (1+ level) ?*) " " (or state "TODO") " " title "\n")
      (forward-line -1)
      (org-id-get-create)
      (when due (org-deadline nil (org-read-date nil t due)))
      (ot--save)
      (ot--task))))

(defun ot--ls (args)
  (pcase-let* ((`(,under ,args) (ot--take "--under" args))
               (`(,state ,args) (ot--take "--state" args))
               (all (member "--all" args))
               (tasks '()))
    (save-excursion
      (when under (ot--goto-under under))
      (org-map-entries
       (lambda ()
         (let ((s (org-get-todo-state)))
           (when (and s
                      (or all state (not (member s org-done-keywords)))
                      (or (null state) (string= s state)))
             (push (ot--task) tasks))))
       nil (and under 'tree)))
    (nreverse tasks)))

(defun ot--set (args)
  (pcase args
    (`(,id ,state)
     (ot--goto-task id)
     (ot--check-state state)
     (let ((org-log-done nil)) (org-todo state))
     (ot--save)
     (ot--task))
    (_ (user-error "ot set takes a task id and a state"))))

(defun ot--run (file cmd args inbox)
  "Run CMD on FILE; return (TEXT . JSON-VALUE)."
  (with-current-buffer (ot--buffer (expand-file-name file))
    (save-excursion
      (pcase cmd
        ("add" (ot--add args inbox))
        ("ls" (ot--ls args))
        ("set" (ot--set args))
        ("inbox" (ot--inbox-ls args))
        ("move" (ot--move args inbox))
        ("done" (ot--set (list (car args) (car org-done-keywords))))
        ("where" (ot--goto-task (car args))
         (list (cons 'file (buffer-file-name))
               (cons 'line (line-number-at-pos nil t))))
        (_ (user-error "Unknown command: %s" cmd))))))

(defun ot-cli (file out cmd args &optional inbox json)
  "Run `ot CMD ARGS' on FILE, and write what to print to OUT.
Return the exit status: 0, or 1 with the error message in OUT."
  (condition-case err
      (let* ((result (ot--run file cmd args (and inbox (not (string-empty-p inbox)) inbox)))
             (text (cond
                    (json (json-encode
                           (if (member cmd '("ls" "inbox")) (vconcat result) result)))
                    ((equal cmd "where")
                     (format "%s:%s" (alist-get 'file result) (alist-get 'line result)))
                    ((member cmd '("ls" "inbox")) (ot--table result))
                    (t (ot--table (list result))))))
        (with-temp-file out (insert text (if (string-empty-p text) "" "\n")))
        0)
    (error
     (with-temp-file out (insert "ot: " (error-message-string err) "\n"))
     1)))

(provide 'ot)
;;; ot.el ends here
