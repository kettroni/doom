;;; opencode-remote-notifications-test.el --- Completion event tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Event tracking tests; no OpenCode server is required.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'opencode-remote-notifications
         (expand-file-name "../libraries/opencode-remote/opencode-remote-notifications"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(ert-deftest opencode-notification-busy-to-idle-notifies-once ()
  (let ((opencode-remote-notifications--active-sessions (make-hash-table :test #'equal))
        notifications)
    (cl-letf (((symbol-function 'opencode-remote-notifications--notify)
               (lambda (session-id) (push session-id notifications))))
      (opencode-remote-notifications--event
       '((type . "session.status")
         (properties . ((sessionID . "session-123")
                        (status . ((type . "busy")))))))
      (opencode-remote-notifications--event
       '((type . "session.idle")
         (properties . ((sessionID . "session-123")))))
      (opencode-remote-notifications--event
       '((type . "session.idle")
         (properties . ((sessionID . "session-123")))))
      (should (equal notifications '("session-123")))
      (should-not (gethash "session-123" opencode-remote-notifications--active-sessions)))))

(ert-deftest opencode-notification-ignores-unobserved-idle-session ()
  (let ((opencode-remote-notifications--active-sessions (make-hash-table :test #'equal))
        notified)
    (cl-letf (((symbol-function 'opencode-remote-notifications--notify)
               (lambda (_session-id) (setq notified t))))
      (opencode-remote-notifications--event
       '((type . "session.idle")
         (properties . ((sessionID . "session-456")))))
      (should-not notified))))

(provide 'opencode-remote-notifications-test)
;;; opencode-remote-notifications-test.el ends here
