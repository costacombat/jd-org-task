;;; jd-org-test.el --- Tests for jd-org -*- lexical-binding: t; -*-

;; Unit tests run against test/fake-jd, which records its arguments and
;; prints canned output.  The `jd-org-real-*' tests run the real jd from
;; jd-nnn (with its Org JDex store) when JD_ORG_REAL_JD names it, and are
;; skipped otherwise.

;;; Code:

(require 'ert)
(require 'jd-org)

(defconst jd-org-test-dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst jd-org-test-jdex
  "#+title: Test JDex
#+TODO: TODO NEXT WAITING | DONE

* 10-19 Life admin
** 11 Me
*** 11.11 Passport
:PROPERTIES:
:CUSTOM_ID: 11.11
:END:
*** 11.12 Car
** 12 House :para_area:
* W0000-9999 Work packages
** NEXT W0011~11.11 Renew it :para_project:
:PROPERTIES:
:CUSTOM_ID: W0011
:END:
")

(defmacro jd-org-test-with-fake (&rest body)
  "Run BODY with the fake jd and a temporary JDex.
Binds `dir', `file' (the JDex) and `log' (the fake's argument log)."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "jd-org-test" t))
          (file (expand-file-name "jdex.org" dir))
          (log (expand-file-name "log" dir))
          (jd-org-program (expand-file-name "fake-jd" jd-org-test-dir))
          (jd-org-file file)
          (jd-org-system nil)
          (jd-org-environment (list (concat "FAKE_JD_LOG=" log)
                                    (concat "FAKE_JD_FILE=" file))))
     (with-temp-file file (insert jd-org-test-jdex))
     (unwind-protect (progn ,@body)
       (when-let ((buf (find-buffer-visiting file)))
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf))
       (delete-directory dir t))))

(defun jd-org-test-fake (&rest pairs)
  "Set the fake's behaviour: PAIRS of NAME VALUE, such as \"OUT\" \"{}\"."
  (cl-loop for (k v) on pairs by #'cddr
           do (push (format "FAKE_JD_%s=%s" k v) jd-org-environment)))

(defun jd-org-test-log (log)
  "The fake jd's calls, one string each."
  (with-temp-buffer
    (insert-file-contents log)
    (split-string (buffer-string) "\n" t)))

;;;; Calling jd

(ert-deftest jd-org-call-returns-jd-json ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":true,\"id\":\"11.13\",\"warnings\":[]}")
    (let ((r (jd-org-call "new" "id" "11" "Boat")))
      (should (equal (alist-get 'id r) "11.13"))
      (should (equal (jd-org-test-log log) '("new id 11 Boat --json"))))))

(ert-deftest jd-org-call-signals-jd-code ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":false,\"code\":\"folder_exists\",\"message\":\"11.13 exists\"}"
                      "EXIT" "1")
    (let ((err (should-error (jd-org-call "new" "id" "11" "Boat")
                             :type 'jd-org-error)))
      (should (equal (cdr err) '("folder_exists" "11.13 exists"))))))

(ert-deftest jd-org-call-uses-stderr-when-jd-says-see-stderr ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":false,\"code\":\"unknown\",\"message\":\"see the message on stderr\"}"
                      "ERR" "jd: the adapter failed" "EXIT" "1")
    (let ((err (should-error (jd-org-call "new" "wp" "11.11" "X") :type 'jd-org-error)))
      (should (equal (cdr err) '("unknown" "jd: the adapter failed"))))))

(ert-deftest jd-org-call-without-json-reports-stderr ()
  (jd-org-test-with-fake
    (jd-org-test-fake "ERR" "jd: no such system" "EXIT" "2")
    (let ((err (should-error (jd-org-call "new" "id" "11" "X") :type 'jd-org-error)))
      (should (equal (cdr err) '(no-json "jd: no such system"))))))

(ert-deftest jd-org-call-passes-the-system-first ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":true}")
    (let ((jd-org-system "D25"))
      (jd-org-call "new" "id" "11" "X"))
    (should (equal (jd-org-test-log log) '("D25 new id 11 X --json")))))

;;;; Writing through jd

(ert-deftest jd-org-new-id-passes-title-words-and-flags ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":true,\"name\":\"11.13 Boat trip\"}")
    (jd-org-new-id "11" "Boat trip" :scope "Summer")
    (should (equal (jd-org-test-log log)
                   '("new id 11 Boat trip --scope=Summer --json")))))

(ert-deftest jd-org-new-id-refreshes-the-open-jdex ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":true}"
                      "APPEND" "*** 11.13 Boat\n:PROPERTIES:\n:CUSTOM_ID: 11.13\n:END:\n")
    (find-file-noselect file)
    (jd-org-new-id "11" "Boat")
    (with-current-buffer (find-buffer-visiting file)
      (should (string-match-p "11.13 Boat" (buffer-string))))
    (should (member "11.13" (mapcar (lambda (e) (plist-get e :id))
                                    (jd-org-entries file))))))

(ert-deftest jd-org-new-id-refuses-over-unsaved-edits ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":true}")
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "unsaved\n"))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (should-error (jd-org-new-id "11" "Boat") :type 'user-error))
    (should-not (file-exists-p log))))

(ert-deftest jd-org-new-wp-calls-jd ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":true,\"num\":\"W0012\"}")
    (should (equal (alist-get 'num (jd-org-new-wp "11.11" "Second one"))
                   "W0012"))
    (should (equal (jd-org-test-log log) '("new wp 11.11 Second one --json")))))

(ert-deftest jd-org-move-passes-absolute-path-and-as ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" "{\"ok\":true,\"to\":\"/x\"}")
    (let ((default-directory dir))
      (jd-org-move "invoice.pdf" "11.11" "2026-11 Invoice.pdf"))
    (should (equal (jd-org-test-log log)
                   (list (format "move %s 11.11 --as 2026-11 Invoice.pdf --json"
                                 (expand-file-name "invoice.pdf" dir)))))))

(ert-deftest jd-org-open-folder-asks-jd ()
  (jd-org-test-with-fake
    (jd-org-test-fake "OUT" (concat dir "\n"))
    (jd-org-open-folder "11.11")
    (should (equal (jd-org-test-log log) '("11.11")))
    (should (equal (file-name-as-directory default-directory)
                   (file-name-as-directory dir)))
    (kill-buffer)))

;;;; Reading the JDex

(ert-deftest jd-org-entries-reads-ids-with-and-without-custom-id ()
  (jd-org-test-with-fake
    (should (equal (mapcar (lambda (e) (plist-get e :id)) (jd-org-entries file))
                   '("10-19" "11" "11.11" "11.12" "12" "W0000-9999" "W0011")))))

(ert-deftest jd-org-goto-finds-by-custom-id-and-by-title ()
  (jd-org-test-with-fake
    (jd-org-goto "w0011")
    (should (equal (org-get-heading t t t t) "W0011~11.11 Renew it"))
    (jd-org-goto "11.12")
    (should (equal (org-get-heading t t t t) "11.12 Car"))
    (should-error (jd-org-goto "11.99") :type 'user-error)))

(ert-deftest jd-org-jdex-file-from-jd-config ()
  (jd-org-test-with-fake
    (let ((config (expand-file-name "config.json" dir))
          (jd-org-file nil))
      (with-temp-file config
        (insert (format "{\"version\":2,\"systems\":[{\"sys\":\"A\",\"jdex\":{\"path\":\"x\"}},{\"sys\":\"P76\",\"default\":true,\"jdex\":{\"app\":\"org\",\"path\":\"%s\"}}]}" file)))
      (jd-org-test-fake "OUT" config)
      (should (equal (jd-org-jdex-file) file))
      (let ((jd-org-system "A"))
        (should-error (jd-org-jdex-file) :type 'user-error)))))

(ert-deftest jd-org-agenda-shows-para-and-gtd ()
  (jd-org-test-with-fake
    (let ((org-agenda-custom-commands (jd-org-agenda-commands))
          (org-agenda-sticky nil))
      (org-agenda nil "ja")
      (let ((text (buffer-string)))
        (should (string-match-p "NEXT W0011~11.11 Renew it" text))
        (should (string-match-p "Areas\n.*12 House" text)))
      (org-agenda-quit))))

;;;; The real jd from jd-nnn

(defmacro jd-org-test-with-real (&rest body)
  "Run BODY against the real jd and a fresh system with an Org JDex."
  (declare (indent 0) (debug t))
  `(let ((real (getenv "JD_ORG_REAL_JD")))
     (skip-unless (and real (file-executable-p real)))
     (let* ((dir (make-temp-file "jd-org-real" t))
            (file (expand-file-name "jdex.org" dir))
            (root (expand-file-name "root" dir))
            (config (expand-file-name "config.json" dir))
            (jd-org-program real)
            (jd-org-file nil)
            (jd-org-system nil)
            (jd-org-environment (list (concat "HOME=" dir)
                                      (concat "JD_CONFIG=" config)
                                      "JD_ORG_EDITOR=true")))
       (make-directory (expand-file-name "10-19 Life admin/11 Me/11.11 Passport" root) t)
       (with-temp-file file
         (insert "* 10-19 Life admin\n** 11 Me\n*** 11.11 Passport\n** 12 House\n"))
       (with-temp-file config
         (insert (format "{\"version\":2,\"systems\":[{\"sys\":\"P76\",\"default\":true,\"root\":\"%s\",\"jdex\":{\"app\":\"org\",\"path\":\"%s\"}}]}"
                         root file)))
       (unwind-protect (progn ,@body)
         (when-let ((buf (find-buffer-visiting file))) (kill-buffer buf))
         (delete-directory dir t)))))

(ert-deftest jd-org-real-new-id-and-goto ()
  (jd-org-test-with-real
    (let ((r (jd-org-new-id "11" "Car")))
      (should (equal (alist-get 'id r) "11.12"))
      (jd-org--goto-link (alist-get 'note r))
      (should (equal (org-get-heading t t t t) "11.12 Car"))
      (should (equal (org-entry-get nil "CUSTOM_ID") "11.12"))
      (should (file-directory-p (alist-get 'folder r))))))

(ert-deftest jd-org-real-new-wp-links-its-id ()
  (jd-org-test-with-real
    (let ((r (jd-org-new-wp "11.11" "Renew it")))
      (should (string-prefix-p "W00" (alist-get 'num r)))
      (jd-org-goto (alist-get 'num r))
      (should (string-match-p "~11.11 Renew it" (org-get-heading t t t t))))))

(ert-deftest jd-org-real-error-comes-back-as-jd-code ()
  (jd-org-test-with-real
    (let ((err (should-error (jd-org-new-id "99" "Nothing") :type 'jd-org-error)))
      (should (equal (cadr err) "no_category_jdex")))))

(ert-deftest jd-org-real-move-and-undo ()
  (jd-org-test-with-real
    (let ((f (expand-file-name "invoice.pdf" dir)))
      (with-temp-file f (insert "x"))
      (let ((r (jd-org-move f "11.11")))
        (should (file-exists-p (alist-get 'to r)))
        (should-not (file-exists-p f))
        (jd-org-undo-move)
        (should (file-exists-p f))))))

(provide 'jd-org-test)
;;; jd-org-test.el ends here
