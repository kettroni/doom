;;; opencode-remote-notifications.el --- Emacs notifications for OpenCode -*- lexical-binding: t; -*-

;;; Commentary:
;; Observe OpenCode's existing authenticated SSE endpoint; no container-side
;; plugin, signal file, or additional bind mount is required.

;;; Code:

(require 'cl-lib)
(require 'opencode-remote-http)
(require 'opencode-remote-events)

(defvar opencode-remote-notifications--dispose nil)
(defvar opencode-remote-notifications--reconnect-timer nil)
(defvar opencode-remote-notifications--enabled nil)
(defvar opencode-remote-notifications--active-sessions (make-hash-table :test #'equal))

(defun opencode-remote-notifications--session-id (event)
  "Extract the session ID from OpenCode EVENT properties."
  (let ((properties (alist-get 'properties event)))
    (or (alist-get 'sessionID properties)
        (alist-get 'sessionId properties))))

(defun opencode-remote-notifications--notify (session-id)
  "Show an Emacs echo-area notification for SESSION-ID."
  (message "OpenCode prompt finished%s"
           (if (and (stringp session-id) (not (string-empty-p session-id)))
               (format " (session %s)" (substring session-id 0 (min 8 (length session-id))))
             "")))

(defun opencode-remote-notifications--event (event)
  "Update completion tracking from OpenCode SSE EVENT."
  (let ((session-id (opencode-remote-notifications--session-id event))
        (type (alist-get 'type event))
        (properties (alist-get 'properties event)))
    (when session-id
      (cond
       ((equal type "session.status")
        (when (member (alist-get 'type (alist-get 'status properties)) '("busy" "retry"))
          (puthash session-id t opencode-remote-notifications--active-sessions)))
       ((and (equal type "session.idle")
             (gethash session-id opencode-remote-notifications--active-sessions))
        (remhash session-id opencode-remote-notifications--active-sessions)
        (opencode-remote-notifications--notify session-id))))))

(defun opencode-remote-notifications--seed-active-sessions (context)
  "Initialize active-session tracking from the server status endpoint."
  (opencode-remote-http-request
   context "GET" "/session/status" nil
   (lambda (statuses _error-text)
     (when (and opencode-remote-notifications--enabled statuses)
       (dolist (entry statuses)
         (when (member (alist-get 'type (cdr entry)) '("busy" "retry"))
           (puthash (format "%s" (car entry)) t
                    opencode-remote-notifications--active-sessions)))))))

(defun opencode-remote-notifications--schedule-reconnect ()
  "Schedule one reconnect attempt if monitoring remains enabled."
  (when (and opencode-remote-notifications--enabled
             (not (timerp opencode-remote-notifications--reconnect-timer)))
    (setq opencode-remote-notifications--reconnect-timer
          (run-at-time 5 nil #'opencode-remote-notifications--connect))))

(defun opencode-remote-notifications--connect ()
  "Connect the notification monitor to the configured OpenCode server."
  (setq opencode-remote-notifications--reconnect-timer nil)
  (when (and opencode-remote-notifications--enabled
             (not opencode-remote-notifications--dispose))
    (condition-case nil
        (let ((context (opencode-remote-http-context)))
          (let ((dispose
                 (opencode-remote-events-open
                  context
                  #'opencode-remote-notifications--event
                  (lambda (connection)
                    (if (equal connection "connected")
                        (opencode-remote-notifications--seed-active-sessions context)
                      (setq opencode-remote-notifications--dispose nil)
                      (opencode-remote-notifications--schedule-reconnect))))))
            (setq opencode-remote-notifications--dispose dispose)
            ;; The transport can report a synchronous startup failure before
            ;; returning its disposer; don't let that stale disposer block retry.
            (when (timerp opencode-remote-notifications--reconnect-timer)
              (funcall dispose)
              (setq opencode-remote-notifications--dispose nil))))
      (error
       (setq opencode-remote-notifications--dispose nil)
       (opencode-remote-notifications--schedule-reconnect)))))

(defun opencode-remote-notifications-start ()
  "Start monitoring the configured OpenCode server for completed prompts."
  (interactive)
  (setq opencode-remote-notifications--enabled t)
  (unless (or opencode-remote-notifications--dispose
              (timerp opencode-remote-notifications--reconnect-timer))
    (opencode-remote-notifications--connect))
  (message "OpenCode completion notifications enabled"))

(defun opencode-remote-notifications-stop ()
  "Stop monitoring the OpenCode server."
  (interactive)
  (setq opencode-remote-notifications--enabled nil)
  (when (timerp opencode-remote-notifications--reconnect-timer)
    (cancel-timer opencode-remote-notifications--reconnect-timer))
  (setq opencode-remote-notifications--reconnect-timer nil)
  (when (functionp opencode-remote-notifications--dispose)
    (funcall opencode-remote-notifications--dispose))
  (setq opencode-remote-notifications--dispose nil)
  (clrhash opencode-remote-notifications--active-sessions)
  (message "OpenCode completion notifications disabled"))

(add-hook 'kill-emacs-hook #'opencode-remote-notifications-stop)

(provide 'opencode-remote-notifications)
;;; opencode-remote-notifications.el ends here
