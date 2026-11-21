;;; jd-org.el --- Johnny.Decimal in Org, through jd -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Ash
;; SPDX-License-Identifier: MIT

;; Author: Ash
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org "9.6"))
;; Keywords: outlines, convenience
;; URL: https://github.com/costacombat/jd-org-task

;;; Commentary:

;; Run a Johnny.Decimal system whose JDex is one Org file, from Emacs.
;;
;; jd (as packaged by jd-nnn, with its Org JDex store) owns every rule:
;; it picks the next number, creates the folder, writes the heading with
;; its CUSTOM_ID, and journals moves.  This package never allocates a
;; number or decides where something goes.  It calls jd with --json,
;; refreshes the Org buffer, and puts you on the heading jd wrote.
;;
;; Everything else is plain Org: the JDex is an ordinary Org file, so
;; agenda, capture, refile, clocking, properties, org-ql and any other
;; package work on it unchanged.  What this file adds on the Org side is
;; reading: listing the entries, going to one, capturing under one, and
;; agenda views for PARA tags and GTD keywords.
;;
;; Commands (all under `jd-org-command-map', bound to C-c j by
;; `jd-org-mode'):
;;
;;   n  `jd-org-new-id'        jd new id CATEGORY TITLE
;;   w  `jd-org-new-wp'        jd new wp ID TITLE
;;   m  `jd-org-move'          jd move PATH ID
;;   u  `jd-org-undo-move'     jd undo move
;;   g  `jd-org-goto'          go to an ID or work package in the JDex
;;   f  `jd-org-open-folder'   open an entry's folder in Dired
;;   a  `jd-org-agenda'        the PARA and GTD agenda views

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-agenda)
(require 'subr-x)

(defgroup jd-org nil
  "Johnny.Decimal in Org, through the jd command."
  :group 'org
  :prefix "jd-org-")

(defcustom jd-org-program "jd"
  "The jd program.  jd-nnn's jd, which has the Org JDex store."
  :type 'string)

(defcustom jd-org-environment nil
  "Extra environment for jd, as \"NAME=VALUE\" strings.
For example (\"JD_CONFIG=/home/me/business/.jd/config.json\").  These
are added in front of `process-environment' for each call."
  :type '(repeat string))

(defcustom jd-org-file nil
  "The JDex Org file.
When nil, it is read from jd's config: the default system's
jdex.path, when its jdex.app is \"org\"."
  :type '(choice (const :tag "From jd's config" nil) file))

(defcustom jd-org-system nil
  "The system to pass to jd as its first word, such as \"P76\".
When nil, jd uses its default system."
  :type '(choice (const :tag "jd's default" nil) string))

(defcustom jd-org-para-tags
  '(("Projects" . "para_project")
    ("Areas" . "para_area")
    ("Resources" . "para_resource"))
  "PARA buckets, as (LABEL . TAG).
An entry's bucket is a tag, not part of its number, so moving between
buckets never renumbers it."
  :type '(alist :key-type string :value-type string))

(defcustom jd-org-gtd-keywords '("NEXT" "WAITING" "TODO")
  "TODO keywords shown, in this order, by the GTD part of `jd-org-agenda'."
  :type '(repeat string))

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))

(define-error 'jd-org-error "jd failed")

;;;; Calling jd

(defun jd-org--environment ()
  "The `process-environment' for a jd call."
  (append jd-org-environment process-environment))

(defun jd-org--run (args)
  "Run jd with ARGS.  Return (EXIT STDOUT STDERR)."
  (let ((process-environment (jd-org--environment))
        (err-file (make-temp-file "jd-org-err")))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process jd-org-program nil
                             (list (current-buffer) err-file) nil
                             (append (and jd-org-system (list jd-org-system))
                                     args))))
            (list exit
                  (buffer-string)
                  (with-temp-buffer
                    (insert-file-contents err-file)
                    (string-trim (buffer-string))))))
      (delete-file err-file))))

(defun jd-org--parse (stdout)
  "Parse jd's --json STDOUT into an alist, or nil if it isn't JSON."
  (condition-case nil
      (json-parse-string (string-trim stdout)
                         :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil)
    (error nil)))

(defun jd-org-call (&rest args)
  "Run jd with ARGS and --json, and return its result as an alist.
Signal `jd-org-error' with jd's code and message when it fails.  The
alist keys are jd's own (`ok', `id', `num', `name', `note', `folder',
`warnings' ...), so code that builds on this gets exactly what jd says."
  (pcase-let* ((`(,exit ,out ,err) (jd-org--run (append args '("--json"))))
               (result (jd-org--parse out)))
    (cond
     ((and result (alist-get 'ok result)) result)
     (result
      (signal 'jd-org-error
              (list (alist-get 'code result)
                    (let ((msg (alist-get 'message result)))
                      (if (or (null msg) (string-prefix-p "see the message" msg))
                          err
                        msg)))))
     (t (signal 'jd-org-error
                (list 'no-json (if (string-empty-p err)
                                   (format "jd exited %s" exit)
                                 err)))))))

(defun jd-org-call-text (&rest args)
  "Run jd with ARGS and return its stdout, trimmed.
For the commands that have no --json, such as `jd 11.11', which prints
the ID's folder."
  (pcase-let ((`(,exit ,out ,err) (jd-org--run args)))
    (unless (eq exit 0)
      (signal 'jd-org-error (list 'exit (if (string-empty-p err)
                                            (format "jd exited %s" exit)
                                          err))))
    (string-trim out)))

;;;; The JDex file

(defun jd-org--config-path ()
  "The config file jd reads, as jd itself reports it."
  (jd-org-call-text "paths" "config"))

(defun jd-org--default-system (systems)
  "The default entry of SYSTEMS from jd's config, as jd picks it."
  (or (and jd-org-system
           (cl-find jd-org-system systems
                    :key (lambda (s) (alist-get 'sys s)) :test #'equal))
      (cl-find-if (lambda (s) (alist-get 'default s)) systems)
      (car systems)))

(defun jd-org-jdex-file ()
  "The JDex Org file: `jd-org-file', or the one jd's config names."
  (or jd-org-file
      (let* ((config (with-temp-buffer
                       (insert-file-contents (jd-org--config-path))
                       (json-parse-buffer :object-type 'alist :array-type 'list
                                          :null-object nil :false-object nil)))
             (jdex (alist-get 'jdex (jd-org--default-system
                                     (alist-get 'systems config)))))
        (unless (equal (alist-get 'app jdex) "org")
          (user-error "jd's system has no Org JDex; set `jd-org-file'"))
        (expand-file-name (substitute-in-file-name (alist-get 'path jdex))))))

(defun jd-org--before-jd (file)
  "Make sure jd can safely write FILE: no unsaved edits in its buffer."
  (let ((buf (find-buffer-visiting file)))
    (when (and buf (buffer-modified-p buf))
      (if (y-or-n-p (format "Save %s before jd writes to it? "
                            (file-name-nondirectory file)))
          (with-current-buffer buf (save-buffer))
        (user-error "Not running jd: %s has unsaved changes" file)))))

(defun jd-org--after-jd (file)
  "Show what jd wrote to FILE: revert its buffer, or visit it."
  (let ((buf (or (find-buffer-visiting file) (find-file-noselect file))))
    (with-current-buffer buf
      (revert-buffer t t t))
    buf))

(defmacro jd-org--writing (&rest body)
  "Run BODY, which calls jd to write the JDex; keep Emacs in step.
Binds `file' to the JDex file."
  (declare (indent 0) (debug t))
  `(let ((file (jd-org-jdex-file)))
     (jd-org--before-jd file)
     (prog1 (progn ,@body)
       (jd-org--after-jd file))))

;;;; Reading the JDex (Org only, no rules)

(defun jd-org--heading-id ()
  "The ID or work package number of the heading at point, or nil.
Its CUSTOM_ID when it has one; otherwise the first word of a heading
whose first word looks like a number, as older or hand-written headings
may lack CUSTOM_ID."
  (or (org-entry-get nil "CUSTOM_ID")
      (let ((title (org-get-heading t t t t)))
        (when (string-match
               "\\`\\([0-9][0-9]-[0-9][0-9]\\|[Ww]0000-9999\\|[0-9][0-9]\\.[0-9][0-9]\\|[0-9][0-9]\\|[Ww][0-9]\\{4\\}\\)\\(?:[ ~]\\|\\'\\)"
               title)
          (upcase (match-string 1 title))))))

(defun jd-org-entries (&optional file)
  "Every numbered heading in the JDex FILE, in order.
Each is a plist (:id ID :title TITLE :level LEVEL :marker MARKER
:path OUTLINE-PATH).  This reads the Org file; it doesn't judge it."
  (with-current-buffer (find-file-noselect (or file (jd-org-jdex-file)))
    (org-with-wide-buffer
     (let (entries)
       (org-map-entries
        (lambda ()
          (when-let ((id (jd-org--heading-id)))
            (push (list :id id
                        :title (org-get-heading t t t t)
                        :level (org-current-level)
                        :marker (point-marker)
                        :path (org-get-outline-path))
                  entries)))
        nil 'file)
       (nreverse entries)))))

(defun jd-org--categories ()
  "The category headings, as (TITLE . NUMBER)."
  (cl-loop for e in (jd-org-entries)
           for id = (plist-get e :id)
           when (string-match-p "\\`[0-9][0-9]\\'" id)
           collect (cons (plist-get e :title) id)))

(defun jd-org--read-entry (prompt &optional pred)
  "Read an entry's number with PROMPT, from the JDex headings.
PRED, if given, filters the entries' plists."
  (let* ((entries (cl-remove-if-not (or pred #'identity) (jd-org-entries)))
         (table (mapcar (lambda (e) (cons (plist-get e :title) e)) entries))
         (choice (completing-read prompt table nil nil)))
    (if-let ((e (cdr (assoc choice table))))
        (plist-get e :id)
      ;; Typed a bare number: let jd judge it.
      (car (split-string choice)))))

(defun jd-org--id-p (e) "Is entry E an ID (AC.ID)?"
  (string-match-p "\\`[0-9][0-9]\\.[0-9][0-9]\\'" (plist-get e :id)))

(defun jd-org--goto-link (link)
  "Visit LINK, an Org link jd printed such as file:/x/jdex.org::#11.12."
  (org-link-open-from-string (concat "[[" link "]]"))
  (org-fold-show-context)
  (org-fold-show-entry))

;;;; Commands that write, through jd

(defun jd-org--flags (plist)
  "jd flags from PLIST, (:scope \"x\") -> (\"--scope=x\")."
  (cl-loop for (k v) on plist by #'cddr
           collect (format "--%s=%s" (substring (symbol-name k) 1) v)))

;;;###autoload
(defun jd-org-new-id (category title &rest flags)
  "Create the next free ID in CATEGORY, titled TITLE, through jd.
CATEGORY is a category number such as \"11\", or an exact ID such as
\"11.15\".  FLAGS is a plist of template tokens, (:scope \"...\").
Return jd's result; interactively, go to the new heading."
  (interactive
   (let* ((cats (jd-org--categories))
          (choice (completing-read "Category: " cats)))
     (list (or (cdr (assoc choice cats)) (car (split-string choice)))
           (read-string "Title: "))))
  (let ((result (jd-org--writing
                  (apply #'jd-org-call "new" "id" category
                         (append (split-string title) (jd-org--flags flags))))))
    (when (called-interactively-p 'any)
      (jd-org--goto-link (alist-get 'note result))
      (message "jd: %s" (alist-get 'name result)))
    result))

;;;###autoload
(defun jd-org-new-wp (id title &rest flags)
  "Create a work package for ID, titled TITLE, through jd.
FLAGS is a plist of template tokens, such as (:scope \"What we do\").
Return jd's result; interactively, go to the new heading."
  (interactive
   (list (jd-org--read-entry "Work package for ID: " #'jd-org--id-p)
         (read-string "Title: ")))
  (let ((result (jd-org--writing
                  (apply #'jd-org-call "new" "wp" id
                         (append (split-string title) (jd-org--flags flags))))))
    (when (called-interactively-p 'any)
      (jd-org--goto-link (alist-get 'note result))
      (when-let ((to-fill (alist-get 'toFill result)))
        (message "jd: %s; not filled: %s" (alist-get 'name result)
                 (mapconcat (lambda (tok) (format "%s" (alist-get 'flag tok)))
                            to-fill ", "))))
    result))

;;;###autoload
(defun jd-org-move (path id &optional as)
  "Move the file or folder at PATH into ID's folder, through jd.
ID may be \"11.12\", \"W0012\" or \"11.12/Subfolder\".  AS renames it.
jd journals the move; `jd-org-undo-move' reverses it."
  (interactive
   (list (read-file-name "Move: " nil nil t
                         (and (derived-mode-p 'dired-mode) (dired-get-filename nil t)))
         (jd-org--read-entry "Into: ")
         nil))
  (let ((result (apply #'jd-org-call "move" (expand-file-name path) id
                       (and as (list "--as" as)))))
    (when (called-interactively-p 'any)
      (message "jd: moved to %s" (alist-get 'to result)))
    result))

;;;###autoload
(defun jd-org-undo-move ()
  "Undo jd's newest move."
  (interactive)
  (let ((out (jd-org-call-text "undo" "move")))
    (when (called-interactively-p 'any) (message "jd: %s" out))
    out))

;;;; Commands that read

;;;###autoload
(defun jd-org-goto (id)
  "Go to the heading for ID (an area, category, ID or work package)."
  (interactive (list (jd-org--read-entry "Go to: ")))
  (let ((e (cl-find id (jd-org-entries) :key (lambda (e) (plist-get e :id))
                    :test #'cl-equalp)))
    (unless e (user-error "No heading for %s in the JDex" id))
    (let ((m (plist-get e :marker)))
      (pop-to-buffer-same-window (marker-buffer m))
      (widen)
      (goto-char m)
      (org-fold-show-context)
      (org-fold-show-entry))))

;;;###autoload
(defun jd-org-open-folder (id)
  "Open ID's folder in Dired.  jd finds it, and creates it if missing."
  (interactive (list (jd-org--read-entry "Folder of: ")))
  (dired (jd-org-call-text id)))

;;;###autoload
(defun jd-org-capture-goto ()
  "For `org-capture': ask for an entry and put point on its heading.
Use it as the target of a capture template:

  (\"j\" \"Into a JD ID\" entry (function jd-org-capture-goto)
   \"* TODO %?\\n%U\")"
  (let ((id (jd-org--read-entry "Capture under: ")))
    (jd-org-goto id)))

;;;; Agenda: PARA and GTD views over the JDex

(defun jd-org-agenda-commands (&optional key)
  "Agenda commands for the JDex, under prefix KEY (default \"j\").
One block per PARA bucket (by tag) and one per GTD keyword.  Add them
with (setq org-agenda-custom-commands
           (append org-agenda-custom-commands (jd-org-agenda-commands)))."
  (let* ((key (or key "j"))
         (para (mapcar (lambda (b)
                         `(tags ,(cdr b)
                                ((org-agenda-overriding-header ,(car b))
                                 (org-agenda-files (list (jd-org-jdex-file))))))
                       jd-org-para-tags))
         (gtd (mapcar (lambda (kw)
                        `(todo ,kw
                               ((org-agenda-overriding-header ,kw)
                                (org-agenda-files (list (jd-org-jdex-file))))))
                      jd-org-gtd-keywords)))
    `((,key . "Johnny.Decimal")
      (,(concat key "p") "PARA" ,para)
      (,(concat key "g") "GTD" ,gtd)
      (,(concat key "a") "Everything" ,(append gtd para)))))

;;;###autoload
(defun jd-org-agenda ()
  "Show the PARA and GTD views of the JDex."
  (interactive)
  (let ((org-agenda-custom-commands (jd-org-agenda-commands)))
    (org-agenda nil "ja")))

;;;; Minor mode

(defvar jd-org-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'jd-org-new-id)
    (define-key map "w" #'jd-org-new-wp)
    (define-key map "m" #'jd-org-move)
    (define-key map "u" #'jd-org-undo-move)
    (define-key map "g" #'jd-org-goto)
    (define-key map "f" #'jd-org-open-folder)
    (define-key map "a" #'jd-org-agenda)
    map)
  "Keymap for jd-org commands.")

;;;###autoload
(define-minor-mode jd-org-mode
  "Johnny.Decimal commands, through jd, under C-c j."
  :global t
  :lighter " JD"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c j") jd-org-command-map)
            map))

(provide 'jd-org)
;;; jd-org.el ends here
