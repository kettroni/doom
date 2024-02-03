;;; opencode-remote-ui-test.el --- Native chat UI tests -*- lexical-binding: t; -*-
;;; Commentary:
;; UI and request lifecycle tests use mocked transport only.
;;; Code:

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path
             (expand-file-name "../libraries/opencode-remote"
                               (file-name-directory
                                (or load-file-name buffer-file-name))))
(require 'opencode-remote-ui)

(defun opencode-ui-test--state (&optional session-id)
  "Create disposable test state for SESSION-ID."
  (let* ((id (or session-id "ses_test"))
         (state (opencode-remote-chat-state-create
                 :key (list "http://localhost" id) :context '(:base-url "http://localhost")
                 :id id :status 'idle :connection "connected"
                 :transcript (generate-new-buffer " *oc-test-transcript*")
                 :composer (generate-new-buffer " *oc-test-composer*")
                 :parts (make-hash-table :test #'equal) :messages (make-hash-table :test #'equal)
                 :approvals (make-hash-table :test #'equal) :questions (make-hash-table :test #'equal)
                 :prompts nil :prompt-index 0)))
    (with-current-buffer (opencode-remote-chat-state-transcript state)
      (opencode-remote-transcript-mode)
      (setq-local opencode-remote--buffer-state state))
    (with-current-buffer (opencode-remote-chat-state-composer state)
      (opencode-remote-composer-mode)
      (setq-local opencode-remote--buffer-state state))
    state))

(defun opencode-ui-test--cleanup (state)
  "Dispose STATE and its temporary buffers."
  (opencode-remote--close-state state)
  (dolist (buffer (list (opencode-remote-chat-state-transcript state)
                        (opencode-remote-chat-state-composer state)))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(ert-deftest opencode-ui-transcript-parts-replace-and-delta-update ()
  (let ((state (opencode-ui-test--state)))
    (unwind-protect
        (progn
          (opencode-remote--handle-event
           state '((type . "message.updated")
                   (properties . ((sessionID . "ses_test") (info . ((id . "msg1") (role . "assistant")))))))
          (opencode-remote--handle-event
           state '((type . "message.part.updated")
                   (properties . ((sessionID . "ses_test")
                                  (part . ((id . "prt1") (messageID . "msg1") (type . "text") (text . "Hello")))))))
          (let ((region (gethash (cons "msg1" "prt1") (opencode-remote-chat-state-parts state))))
            (should (buffer-live-p (marker-buffer (car region))))
            (should (eq (marker-buffer (car region)) (opencode-remote-chat-state-transcript state))))
          (opencode-remote--handle-event
           state '((type . "message.part.delta")
                   (properties . ((sessionID . "ses_test") (messageID . "msg1")
                                  (partID . "prt1") (field . "text") (delta . " world")))))
          (with-current-buffer (opencode-remote-chat-state-transcript state)
            (should (string-match-p "Hello world" (buffer-string)))
            (should (= (how-many "Assistant" (point-min) (point-max)) 1)))
          (opencode-remote--handle-event
           state '((type . "message.part.updated")
                   (properties . ((sessionID . "ses_test")
                                  (part . ((id . "prt1") (messageID . "msg1") (type . "text") (text . "Revised")))))))
          (with-current-buffer (opencode-remote-chat-state-transcript state)
            (should (string-match-p "Revised" (buffer-string)))
            (should-not (string-match-p "Hello world" (buffer-string)))))
      (opencode-ui-test--cleanup state))))

(ert-deftest opencode-ui-tool-activity-is-expandable ()
  (let ((state (opencode-ui-test--state)))
    (unwind-protect
        (progn
          (opencode-remote--render-part
           state "msg1" '((id . "tool1") (messageID . "msg1") (type . "tool")
                           (tool . "bash") (state . ((status . "running") (input . ((command . "pwd")))))))
          (with-current-buffer (opencode-remote-chat-state-transcript state)
            (let* ((position (text-property-not-all (point-min) (point-max) 'button nil))
                   (button (and position (button-at position))))
              (should button)
              (should (equal (alist-get 'tool (button-get button 'opencode-part)) "bash")))))
      (opencode-ui-test--cleanup state))))

(ert-deftest opencode-ui-session-state-separated-by-session ()
  (let ((opencode-remote--states (make-hash-table :test #'equal)))
    (let ((a (opencode-remote--state-for '(:base-url "http://localhost") "ses_a"))
          (b (opencode-remote--state-for '(:base-url "http://localhost") "ses_b")))
      (unwind-protect
          (progn
            (should-not (eq a b))
            (should-not (eq (opencode-remote-chat-state-composer a)
                            (opencode-remote-chat-state-composer b)))
            (with-current-buffer (opencode-remote-chat-state-composer a) (insert "draft a"))
            (with-current-buffer (opencode-remote-chat-state-composer b) (insert "draft b"))
            (should (equal (with-current-buffer (opencode-remote-chat-state-composer a) (buffer-string)) "draft a"))
            (should (equal (with-current-buffer (opencode-remote-chat-state-composer b) (buffer-string)) "draft b")))
        (opencode-ui-test--cleanup a)
        (opencode-ui-test--cleanup b)))))

(ert-deftest opencode-ui-send-multiline-is-asynchronous-and-recoverable ()
  (let ((state (opencode-ui-test--state)) sent callback)
    (unwind-protect
        (cl-letf (((symbol-function 'opencode-remote--http)
                   (lambda (_state method path data cb)
                     (setq sent (list method path data) callback cb)))
                  ((symbol-function 'opencode-remote-focus-transcript) #'ignore))
          (with-current-buffer (opencode-remote-chat-state-composer state)
            (insert "first line\nsecond line")
            (opencode-remote-send))
          (should (equal (car sent) "POST"))
          (should (equal (cadr sent) "/session/ses_test/prompt_async"))
          (should (equal (alist-get 'text (car (alist-get 'parts (nth 2 sent))))
                         "first line\nsecond line"))
          (should (equal (with-current-buffer (opencode-remote-chat-state-composer state)
                           (buffer-string)) "first line\nsecond line"))
          (should (eq (opencode-remote-chat-state-status state) 'submitting))
          (funcall callback nil "sanitized test error")
          (should (eq (opencode-remote-chat-state-status state) 'idle))
          (should (equal (with-current-buffer (opencode-remote-chat-state-composer state)
                           (buffer-string)) "first line\nsecond line"))
          (with-current-buffer (opencode-remote-chat-state-transcript state)
            (should (string-match-p "sanitized test error" (buffer-string)))))
      (opencode-ui-test--cleanup state))))

(ert-deftest opencode-ui-mode-init-preserves-session-and-queued-events ()
  (let* ((state (opencode-ui-test--state)) (done nil))
    (unwind-protect
        (cl-letf (((symbol-function 'opencode-remote-events-open)
                   (lambda (_context _event on-state)
                     (funcall on-state "connected") #'ignore))
                  ((symbol-function 'opencode-remote-http-request)
                   (lambda (_context _method path _data callback)
                     (cond
                      ((string-match-p "/message" path)
                       (funcall callback
                                '(((info . ((id . "msg0") (role . "assistant")))
                                   (parts . (((id . "part0") (type . "text") (text . "history")))))) nil))
                      ((equal path "/session/status") (funcall callback nil nil)))
                     #'ignore))
                  ((symbol-function 'opencode-remote--display-state) (lambda (_state) (setq done t))))
          (opencode-remote--open-state state)
          (should done)
          (should (equal (opencode-remote-chat-state-id state) "ses_test"))
          (should (opencode-remote-chat-state-history-loaded state))
          (should (equal (buffer-local-value 'opencode-remote--buffer-state
                                             (opencode-remote-chat-state-composer state)) state))
          (with-current-buffer (opencode-remote-chat-state-transcript state)
            (should (string-match-p "history" (buffer-string)))))
      (opencode-ui-test--cleanup state))))

(ert-deftest opencode-ui-send-success-and-stream-reconciliation ()
  (let ((state (opencode-ui-test--state)) callback)
    (unwind-protect
        (cl-letf (((symbol-function 'opencode-remote--http)
                   (lambda (_state _method _path _data cb) (setq callback cb)))
                  ((symbol-function 'opencode-remote-focus-transcript) #'ignore))
          (with-current-buffer (opencode-remote-chat-state-composer state)
            (insert "draft prompt")
            (opencode-remote-send))
          (funcall callback nil nil)
          (should (eq (opencode-remote-chat-state-status state) 'busy))
          (should (equal (with-current-buffer (opencode-remote-chat-state-composer state)
                           (buffer-string)) ""))
          (opencode-remote--handle-event
           state '((type . "message.updated")
                   (properties . ((sessionID . "ses_test") (info . ((id . "server-msg") (role . "user")))))))
          (opencode-remote--handle-event
           state '((type . "message.part.updated")
                   (properties . ((sessionID . "ses_test")
                                  (part . ((id . "server-part") (messageID . "server-msg")
                                           (type . "text") (text . "draft prompt")))))))
          (should-not (opencode-remote-chat-state-pending-user-id state))
          (with-current-buffer (opencode-remote-chat-state-transcript state)
            (should (= (how-many "draft prompt" (point-min) (point-max)) 1))))
      (opencode-ui-test--cleanup state))))

(ert-deftest opencode-ui-v2-permission-uses-session-scoped-route ()
  (let ((state (opencode-ui-test--state)) sent callback)
    (unwind-protect
        (cl-letf (((symbol-function 'opencode-remote--http)
                   (lambda (_state method path data cb)
                     (setq sent (list method path data) callback cb)))
                  ((symbol-function 'completing-read)
                   (lambda (prompt _choices &rest _)
                     (if (string-prefix-p "Permission" prompt) "per_v2" "once"))))
          (puthash "per_v2" '((id . "per_v2") (action . "shell") (version . v2))
                   (opencode-remote-chat-state-approvals state))
          (with-current-buffer (opencode-remote-chat-state-composer state)
            (opencode-remote-reply-permission))
          (should (equal (car sent) "POST"))
          (should (equal (cadr sent) "/api/session/ses_test/permission/per_v2/reply"))
          (should (equal (alist-get 'reply (nth 2 sent)) "once"))
          (funcall callback nil nil)
          (should-not (gethash "per_v2" (opencode-remote-chat-state-approvals state))))
      (opencode-ui-test--cleanup state))))

(ert-deftest opencode-ui-v2-question-reject-route ()
  (let ((state (opencode-ui-test--state)) sent callback)
    (unwind-protect
        (cl-letf (((symbol-function 'opencode-remote--http)
                   (lambda (_state method path data cb)
                     (setq sent (list method path data) callback cb)))
                  ((symbol-function 'completing-read)
                   (lambda (prompt _choices &rest _)
                     (if (string-prefix-p "Question" prompt) "que_v2" "reject"))))
          (puthash "que_v2" '((id . "que_v2") (questions . nil) (version . v2))
                   (opencode-remote-chat-state-questions state))
          (with-current-buffer (opencode-remote-chat-state-composer state)
            (opencode-remote-reply-question))
          (should (equal (car sent) "POST"))
          (should (equal (cadr sent) "/api/session/ses_test/question/que_v2/reject"))
          (should-not (nth 2 sent))
          (funcall callback nil nil)
          (should-not (gethash "que_v2" (opencode-remote-chat-state-questions state))))
      (opencode-ui-test--cleanup state))))

(provide 'opencode-remote-ui-test)
;;; opencode-remote-ui-test.el ends here
