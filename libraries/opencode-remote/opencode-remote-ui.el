;;; opencode-remote-ui.el --- Native Emacs chat interface -*- lexical-binding: t; -*-

;;; Commentary:
;; Read-only conversation transcript with an independent multiline composer.

;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'opencode-remote-http)
(require 'opencode-remote-events)

(cl-defstruct (opencode-remote-chat-state
               (:constructor opencode-remote-chat-state-create))
  key context id transcript composer status connection spinner-index spinner-timer
  event-dispose reconnect-timer requests queued history-loaded history-loading closed parts messages
  approvals questions prompts prompt-index draft pending-user-id pending-user-prompt)

(defvar opencode-remote--states (make-hash-table :test #'equal)
  "Open chat states keyed by server, scope, and session ID.")
(defvar-local opencode-remote--buffer-state nil)
(defvar-local opencode-remote--closing nil)
(defconst opencode-remote--spinner ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(defvar opencode-remote-transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'opencode-remote-close)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "C-c C-o") #'opencode-remote-focus-composer)
    (define-key map (kbd "C-c C-k") #'opencode-remote-abort)
    (define-key map (kbd "C-c C-a") #'opencode-remote-reply-permission)
    (define-key map (kbd "C-c C-q") #'opencode-remote-reply-question)
    map))

(define-derived-mode opencode-remote-transcript-mode special-mode "OpenCode"
  "Read-only OpenCode conversation transcript."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defvar opencode-remote-composer-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'opencode-remote-send)
    (define-key map (kbd "C-c C-k") #'opencode-remote-abort)
    (define-key map (kbd "C-c C-o") #'opencode-remote-focus-transcript)
    (define-key map (kbd "C-c C-a") #'opencode-remote-reply-permission)
    (define-key map (kbd "C-c C-q") #'opencode-remote-reply-question)
    (define-key map (kbd "M-p") #'opencode-remote-previous-prompt)
    (define-key map (kbd "M-n") #'opencode-remote-next-prompt)
    map))

(define-derived-mode opencode-remote-composer-mode text-mode "OpenCode-Input"
  "Multiline prompt composer for OpenCode."
  (setq-local header-line-format '(:eval (opencode-remote--header-line)))
  (setq-local word-wrap t)
  (setq-local truncate-lines nil))

(defun opencode-remote--header-line ()
  "Return live status text for the current OpenCode buffer."
  (let ((state opencode-remote--buffer-state))
    (when state
      (let* ((status (opencode-remote-chat-state-status state))
             (spinner (if (member status '(submitting busy retry cancelling))
                          (aref opencode-remote--spinner
                                (mod (or (opencode-remote-chat-state-spinner-index state) 0)
                                     (length opencode-remote--spinner)))
                        "")))
        (format " OpenCode %s%s | events: %s | session: %s"
                (capitalize (symbol-name (or status 'idle)))
                (if (string-empty-p spinner) "" (concat " " spinner))
                (or (opencode-remote-chat-state-connection state) "connecting")
                (opencode-remote-chat-state-id state))))))

(defun opencode-remote--refresh-header (state)
  "Refresh header lines for STATE."
  (dolist (buffer (list (opencode-remote-chat-state-transcript state)
                        (opencode-remote-chat-state-composer state)))
    (when (buffer-live-p buffer) (with-current-buffer buffer (force-mode-line-update t)))))

(defun opencode-remote--state-key (context session-id)
  (list (plist-get context :base-url) (plist-get context :directory)
        (plist-get context :workspace) session-id))

(defun opencode-remote--state-for (context session-id)
  "Return or create the persistent Emacs state for CONTEXT and SESSION-ID."
  (let* ((key (opencode-remote--state-key context session-id))
         (existing (gethash key opencode-remote--states)))
    (or existing
        (let* ((safe-id (replace-regexp-in-string "[^[:alnum:]-]" "_" session-id))
               (scope-hash (substring (secure-hash 'sha1 (prin1-to-string key)) 0 8))
               (state (opencode-remote-chat-state-create
                       :key key :context context :id session-id :status 'loading :closed t
                       :connection "connecting" :spinner-index 0
                       :transcript (get-buffer-create (format "*OpenCode: %s-%s*" safe-id scope-hash))
                       :composer (get-buffer-create (format "*OpenCode Input: %s-%s*" safe-id scope-hash))
                       :parts (make-hash-table :test #'equal)
                       :messages (make-hash-table :test #'equal)
                       :approvals (make-hash-table :test #'equal)
                       :questions (make-hash-table :test #'equal)
                       :prompts nil :prompt-index 0)))
          (puthash key state opencode-remote--states)
          state))))

(defun opencode-remote--http (state method path data callback)
  "Issue an asynchronous scoped request for STATE, routing its result to CALLBACK."
  (let (cancel)
    (setq cancel
          (opencode-remote-http-request
           (opencode-remote-chat-state-context state) method path data
           (lambda (value error-text)
             (setf (opencode-remote-chat-state-requests state)
                   (delq cancel (opencode-remote-chat-state-requests state)))
             (unless (opencode-remote-chat-state-closed state)
               (funcall callback value error-text)))))
    (push cancel (opencode-remote-chat-state-requests state))
    cancel))

(defun opencode-remote--insert-notice (state text &optional face)
  "Append a styled notice to STATE's transcript."
  (let ((buffer (opencode-remote-chat-state-transcript state)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert (propertize (concat "\n" text "\n") 'face (or face 'shadow))))))))

(defun opencode-remote--message-header (state message-id role)
  "Ensure a heading for MESSAGE-ID and return non-nil if it was inserted."
  (let ((messages (opencode-remote-chat-state-messages state)))
    (unless (gethash message-id messages)
      (let ((buffer (opencode-remote-chat-state-transcript state)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (let ((inhibit-read-only t)
                  (start (make-marker)) (end (make-marker)))
              (goto-char (point-max))
              (unless (bolp) (insert "\n"))
              (set-marker start (point) buffer)
              (insert (propertize (format "\n%s\n" (capitalize (or role "assistant")))
                                  'face 'bold))
              (set-marker end (point) buffer)
              (set-marker-insertion-type end t)
              (puthash message-id (cons start end) messages)))))
      t)))

(defun opencode-remote--remove-message (state message-id)
  "Remove MESSAGE-ID and its transcript regions from STATE."
  (let* ((messages (opencode-remote-chat-state-messages state))
         (region (gethash message-id messages))
         (buffer (opencode-remote-chat-state-transcript state)))
    (when (and region (buffer-live-p buffer))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (delete-region (car region) (cdr region))))
      (remhash message-id messages)
      (dolist (key (hash-table-keys (opencode-remote-chat-state-parts state)))
        (when (equal (car key) message-id)
          (let ((markers (gethash key (opencode-remote-chat-state-parts state))))
            (set-marker (car markers) nil)
            (set-marker (cdr markers) nil))
          (remhash key (opencode-remote-chat-state-parts state)))))))

(defun opencode-remote--part-string (part)
  "Return readable transcript text for OpenCode PART."
  (pcase (alist-get 'type part)
    ("text" (or (alist-get 'text part) ""))
    ("tool" (let* ((tool-state (alist-get 'state part))
                    (status (or (alist-get 'status tool-state)
                                (alist-get 'status part) "running")))
               (propertize (format "  ▸ %s — %s"
                                   (or (alist-get 'tool part) (alist-get 'name part) "tool")
                                   status)
                           'face (if (equal status "error") 'error 'font-lock-keyword-face)
                           'help-echo (format "OpenCode tool activity: %s" status))))
    ("reasoning" "")
    ("file" (format "[File: %s]" (or (alist-get 'filename part) (alist-get 'url part) "attachment")))
    ("image" "[Image attachment]")
    (_ "")))

(defun opencode-remote--show-tool-detail (button)
  "Display structured tool activity attached to BUTTON."
  (let ((buffer (get-buffer-create "*OpenCode Tool Activity*"))
        (part (button-get button 'opencode-part)))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pp-to-string part))))
    (display-buffer buffer)))

(defun opencode-remote--render-part (state message-id part &optional delta)
  "Render PART for MESSAGE-ID in STATE; DELTA appends the event delta text."
  (let* ((part-id (or (alist-get 'id part) (alist-get 'partID part) "text"))
         (key (cons message-id part-id))
         (region (gethash key (opencode-remote-chat-state-parts state)))
         (buffer (opencode-remote-chat-state-transcript state))
         (window (get-buffer-window buffer t))
         (follow-tail (and window (>= (window-end window t) (point-max))))
         (text (if delta
                   (concat (if (and region (marker-buffer (car region))
                                    (buffer-live-p (marker-buffer (car region))))
                               (with-current-buffer (marker-buffer (car region))
                                 (buffer-substring-no-properties (marker-position (car region))
                                                                 (marker-position (cdr region))))
                             "")
                           (or (alist-get 'delta part) ""))
                 (opencode-remote--part-string part))))
    (when (buffer-live-p buffer)
      (opencode-remote--message-header state message-id
                                       (or (alist-get 'role part) "assistant"))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (markers (or region (cons (make-marker) (make-marker)))))
          (if (and region (marker-position (car markers)) (marker-position (cdr markers)))
              (progn (goto-char (car markers)) (delete-region (car markers) (cdr markers)))
            (goto-char (point-max))
            (when (and (> (point) (point-min)) (not (bolp))) (insert "\n"))
            (set-marker (car markers) (point) buffer))
          (goto-char (car markers))
          (insert text)
          (when (and (equal (alist-get 'type part) "tool") (> (point) (marker-position (car markers))))
            (make-text-button (marker-position (car markers)) (point)
                              'action #'opencode-remote--show-tool-detail
                              'opencode-part part))
          (set-marker-insertion-type (car markers) nil)
          (set-marker (cdr markers) (point) buffer)
          (set-marker-insertion-type (cdr markers) t)
          (puthash key markers (opencode-remote-chat-state-parts state))
          (let ((message-region (gethash message-id (opencode-remote-chat-state-messages state))))
            (when message-region (set-marker (cdr message-region) (point) buffer)))
          (when follow-tail
            (set-window-point window (point-max))
            (save-selected-window
              (with-selected-window window
                (goto-char (point-max))
                (recenter -1)))))))))

(defun opencode-remote--render-history (state messages)
  "Render server MESSAGES into STATE's transcript."
  (let ((buffer (opencode-remote-chat-state-transcript state))
        pending-found)
    (clrhash (opencode-remote-chat-state-parts state))
    (clrhash (opencode-remote-chat-state-messages state))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (erase-buffer)))
      (dolist (message messages)
        (let* ((info (alist-get 'info message))
               (message-id (alist-get 'id info))
               (role (alist-get 'role info))
               (parts (alist-get 'parts message)))
          (when (and (equal role "user")
                     (cl-some (lambda (part)
                                (equal (alist-get 'text part)
                                       (opencode-remote-chat-state-pending-user-prompt state)))
                              parts))
            (setq pending-found t))
          (when message-id
            (opencode-remote--message-header state message-id role)
            (dolist (part parts)
              (opencode-remote--render-part state message-id part)))))
      (when pending-found
        (setf (opencode-remote-chat-state-pending-user-id state) nil
              (opencode-remote-chat-state-pending-user-prompt state) nil))
      (when (and (not pending-found) (opencode-remote-chat-state-pending-user-id state))
        (opencode-remote--message-header state (opencode-remote-chat-state-pending-user-id state) "user")
        (opencode-remote--render-part
         state (opencode-remote-chat-state-pending-user-id state)
         `((id . "text") (type . "text")
           (text . ,(opencode-remote-chat-state-pending-user-prompt state))))))))

(defun opencode-remote--status-set (state status)
  "Set STATE's activity STATUS and maintain a spinner only while active."
  (setf (opencode-remote-chat-state-status state) status)
  (if (member status '(submitting busy retry cancelling))
      (unless (timerp (opencode-remote-chat-state-spinner-timer state))
        (setf (opencode-remote-chat-state-spinner-timer state)
              (run-at-time 0.12 0.12 #'opencode-remote--spinner-tick state)))
    (when (timerp (opencode-remote-chat-state-spinner-timer state))
      (cancel-timer (opencode-remote-chat-state-spinner-timer state)))
    (setf (opencode-remote-chat-state-spinner-timer state) nil))
  (opencode-remote--refresh-header state))

(defun opencode-remote--spinner-tick (state)
  "Advance STATE's animated status indicator while work remains active."
  (when (and (not (opencode-remote-chat-state-closed state))
             (member (opencode-remote-chat-state-status state) '(submitting busy retry cancelling)))
    (setf (opencode-remote-chat-state-spinner-index state)
          (1+ (or (opencode-remote-chat-state-spinner-index state) 0)))
    (opencode-remote--refresh-header state)))

(defun opencode-remote--event-for-session-p (state event)
  (let* ((props (alist-get 'properties event))
         (session-id (or (alist-get 'sessionID props)
                         (alist-get 'sessionId props))))
    (or (equal session-id (opencode-remote-chat-state-id state))
        (equal (alist-get 'type event) "server.connected"))))

(defun opencode-remote--handle-event (state event)
  "Apply one OpenCode EVENT to STATE."
  (when (and (not (opencode-remote-chat-state-closed state))
             (opencode-remote--event-for-session-p state event))
    (let* ((type (alist-get 'type event))
           (props (alist-get 'properties event)))
      (pcase type
        ("session.status"
         (let* ((status (alist-get 'status props))
                (kind (alist-get 'type status)))
           (opencode-remote--status-set state
                                       (cond ((equal kind "busy") 'busy)
                                             ((equal kind "retry") 'retry)
                                             (t 'idle)))))
        ("session.idle" (opencode-remote--status-set state 'idle))
        ("message.updated"
         (let ((info (alist-get 'info props)))
           (when (alist-get 'id info)
             (opencode-remote--message-header state (alist-get 'id info)
                                               (alist-get 'role info)))))
        ("message.part.updated"
         (let ((part (alist-get 'part props)))
           (when (and (alist-get 'id part) (alist-get 'messageID part))
             (when (and (equal (alist-get 'type part) "text")
                        (equal (alist-get 'text part) (opencode-remote-chat-state-pending-user-prompt state)))
               (opencode-remote--remove-message state (opencode-remote-chat-state-pending-user-id state))
               (setf (opencode-remote-chat-state-pending-user-id state) nil
                     (opencode-remote-chat-state-pending-user-prompt state) nil))
             (opencode-remote--render-part state (alist-get 'messageID part) part))))
        ("message.part.delta"
         (when (equal (alist-get 'field props) "text")
           (opencode-remote--render-part
            state (alist-get 'messageID props)
            `((id . ,(alist-get 'partID props)) (type . "text")
              (delta . ,(alist-get 'delta props))) t)))
        ("permission.asked"
         (let ((id (alist-get 'id props)))
           (when id
                          (puthash id props (opencode-remote-chat-state-approvals state))
                          (opencode-remote--status-set state 'permission)
                          (opencode-remote--insert-notice state (format "Permission requested: %s — use C-c C-a to respond"
                             (or (alist-get 'permission props) "tool action")) 'warning))))
        ("question.asked"
         (let ((id (alist-get 'id props)))
           (when id
             (puthash id props (opencode-remote-chat-state-questions state))
             (opencode-remote--status-set state 'question)
             (opencode-remote--insert-notice state "OpenCode asks a question — use C-c C-q to answer" 'warning))))
        ("permission.v2.asked"
         (let ((request (alist-get 'properties event)))
           (when (alist-get 'id request)
             (puthash (alist-get 'id request) (append request '((version . v2)))
                      (opencode-remote-chat-state-approvals state))
             (opencode-remote--status-set state 'permission)
             (opencode-remote--insert-notice
              state (format "Permission requested: %s (%s) — C-c C-a to respond"
                             (or (alist-get 'action request) "action")
                             (string-join (alist-get 'resources request) ", ")) 'warning))))
        ("question.v2.asked"
         (let ((request (alist-get 'properties event)))
           (when (alist-get 'id request)
             (puthash (alist-get 'id request) (append request '((version . v2)))
                      (opencode-remote-chat-state-questions state))
             (opencode-remote--status-set state 'question)
             (opencode-remote--insert-notice state "OpenCode asks a question — use C-c C-q to answer" 'warning))))
        ((or "permission.replied" "permission.v2.replied")
         (let ((id (or (alist-get 'requestID props) (alist-get 'id props))))
           (when id (remhash id (opencode-remote-chat-state-approvals state)))
           (when (eq (opencode-remote-chat-state-status state) 'permission)
             (opencode-remote--status-set state 'busy))))
        ((or "question.replied" "question.rejected"
             "question.v2.replied" "question.v2.rejected")
         (let ((id (or (alist-get 'requestID props) (alist-get 'id props))))
           (when id (remhash id (opencode-remote-chat-state-questions state)))
           (when (eq (opencode-remote-chat-state-status state) 'question)
             (opencode-remote--status-set state 'busy))))
        ("session.error"
         (opencode-remote--status-set state 'error)
         (opencode-remote--insert-notice state "OpenCode reported a session error." 'error))
        (_ nil)))))

(defun opencode-remote--refresh-history (state)
  "Reload STATE's transcript and reconcile queued events with server history."
  (unless (or (opencode-remote-chat-state-closed state)
              (opencode-remote-chat-state-history-loading state))
    (setf (opencode-remote-chat-state-history-loaded state) nil
          (opencode-remote-chat-state-history-loading state) t
          (opencode-remote-chat-state-queued state) nil)
    (opencode-remote--http
     state "GET" (format "/session/%s/message?limit=100"
                         (url-hexify-string (opencode-remote-chat-state-id state))) nil
     (lambda (messages error-text)
       (setf (opencode-remote-chat-state-history-loading state) nil)
       (if error-text
           (progn
             (opencode-remote--status-set state 'error)
             (opencode-remote--insert-notice state (concat "Could not load history: " error-text) 'error)
             (setf (opencode-remote-chat-state-history-loaded state) t)
             (dolist (event (nreverse (opencode-remote-chat-state-queued state)))
               (opencode-remote--handle-event state event))
             (setf (opencode-remote-chat-state-queued state) nil))
         (opencode-remote--render-history state messages)
         (setf (opencode-remote-chat-state-history-loaded state) t)
         (dolist (event (nreverse (opencode-remote-chat-state-queued state)))
           (opencode-remote--handle-event state event))
         (setf (opencode-remote-chat-state-queued state) nil)
         (unless (memq (opencode-remote-chat-state-status state)
                       '(busy retry permission question submitting cancelling))
           (opencode-remote--status-set state 'idle))
         (opencode-remote--http
          state "GET" "/session/status" nil
          (lambda (statuses error-text)
            (unless error-text
              (let* ((session-id (opencode-remote-chat-state-id state))
                     (entry (cl-assoc session-id statuses
                                      :key (lambda (item) (format "%s" (car item)))
                                      :test #'equal))
                     (kind (alist-get 'type (cdr entry))))
                (when entry
                  (opencode-remote--status-set
                   state (cond ((equal kind "busy") 'busy)
                               ((equal kind "retry") 'retry)
                               (t 'idle)))))))))))))

(defun opencode-remote--connect-events (state)
  "Open/reopen the event stream for STATE."
  (unless (opencode-remote-chat-state-closed state)
    (setf (opencode-remote-chat-state-connection state) "connecting")
    (opencode-remote--refresh-header state)
    (setf (opencode-remote-chat-state-event-dispose state)
          (opencode-remote-events-open
           (opencode-remote-chat-state-context state)
           (lambda (event)
             (if (opencode-remote-chat-state-history-loaded state)
                 (opencode-remote--handle-event state event)
               (push event (opencode-remote-chat-state-queued state))))
           (lambda (connection)
             (setf (opencode-remote-chat-state-connection state) connection)
             (opencode-remote--refresh-header state)
             (when (equal connection "connected")
               (opencode-remote--refresh-history state))
             (when (equal connection "disconnected")
               (unless (opencode-remote-chat-state-closed state)
                 (setf (opencode-remote-chat-state-reconnect-timer state)
                       (run-at-time 2 nil #'opencode-remote--connect-events state)))))))))

(defun opencode-remote--open-state (state)
  "Initialize buffers, load history, and subscribe for STATE."
  (when (opencode-remote-chat-state-closed state)
    (let* ((safe-id (replace-regexp-in-string "[^[:alnum:]-]" "_" (opencode-remote-chat-state-id state)))
           (scope-hash (substring (secure-hash 'sha1 (prin1-to-string
                                                       (opencode-remote-chat-state-key state))) 0 8))
           (draft (opencode-remote-chat-state-draft state)))
      (setf (opencode-remote-chat-state-transcript state)
            (get-buffer-create (format "*OpenCode: %s-%s*" safe-id scope-hash))
            (opencode-remote-chat-state-composer state)
            (get-buffer-create (format "*OpenCode Input: %s-%s*" safe-id scope-hash))
            (opencode-remote-chat-state-parts state) (make-hash-table :test #'equal)
            (opencode-remote-chat-state-messages state) (make-hash-table :test #'equal)
            (opencode-remote-chat-state-history-loaded state) nil
            (opencode-remote-chat-state-history-loading state) nil
            (opencode-remote-chat-state-queued state) nil)
      (when (buffer-live-p (opencode-remote-chat-state-composer state))
        (with-current-buffer (opencode-remote-chat-state-composer state)
          (let ((inhibit-read-only t)) (erase-buffer) (insert (or draft "")))))))
  (let ((transcript (opencode-remote-chat-state-transcript state))
        (composer (opencode-remote-chat-state-composer state)))
    (setf (opencode-remote-chat-state-closed state) nil)
    (with-current-buffer transcript
      (opencode-remote-transcript-mode)
      (setq-local opencode-remote--buffer-state state)
      (setq-local header-line-format '(:eval (opencode-remote--header-line)))
      (add-hook 'kill-buffer-hook #'opencode-remote--buffer-killed nil t))
    (with-current-buffer composer
      (opencode-remote-composer-mode)
      (setq-local opencode-remote--buffer-state state)
      (add-hook 'kill-buffer-hook #'opencode-remote--buffer-killed nil t))
    (opencode-remote--connect-events state)
    (opencode-remote--refresh-history state)
    (opencode-remote--refresh-header state)
    (opencode-remote--display-state state)))

(defun opencode-remote--display-state (state)
  "Display transcript above composer for STATE."
  (let ((transcript (opencode-remote-chat-state-transcript state))
        (composer (opencode-remote-chat-state-composer state)))
    (pop-to-buffer transcript)
    (let ((window (display-buffer
                   composer
                   '((display-buffer-below-selected)
                     (window-height . 0.25)))))
      (when (window-live-p window) (select-window window)))
    (opencode-remote-focus-composer)))

(defun opencode-remote--buffer-killed ()
  "Clean up local activity when a chat view buffer is killed."
  (unless opencode-remote--closing
    (let ((state opencode-remote--buffer-state))
      (when state (opencode-remote--close-state state)))))

(defun opencode-remote--close-state (state)
  "Dispose local network activity for STATE without aborting server work."
  (unless (opencode-remote-chat-state-closed state)
    (let ((composer (opencode-remote-chat-state-composer state)))
      (when (buffer-live-p composer)
        (setf (opencode-remote-chat-state-draft state)
              (with-current-buffer composer
                (buffer-substring-no-properties (point-min) (point-max)))))
    (setf (opencode-remote-chat-state-closed state) t)
    (when (functionp (opencode-remote-chat-state-event-dispose state))
      (funcall (opencode-remote-chat-state-event-dispose state)))
    (when (timerp (opencode-remote-chat-state-spinner-timer state))
      (cancel-timer (opencode-remote-chat-state-spinner-timer state)))
    (when (timerp (opencode-remote-chat-state-reconnect-timer state))
      (cancel-timer (opencode-remote-chat-state-reconnect-timer state)))
    (mapc #'funcall (opencode-remote-chat-state-requests state))
    (setf (opencode-remote-chat-state-requests state) nil)))

(defun opencode-remote-close ()
  "Close this OpenCode view without interrupting server-side work."
  (interactive)
  (let* ((state opencode-remote--buffer-state)
         (transcript (and state (opencode-remote-chat-state-transcript state)))
         (composer (and state (opencode-remote-chat-state-composer state))))
    (when state (opencode-remote--close-state state))
    (dolist (buffer (list transcript composer))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (setq-local opencode-remote--closing t))
        (kill-buffer buffer)))
    (when (one-window-p) (switch-to-buffer (other-buffer)))))

(defun opencode-remote-focus-composer ()
  "Move point to the OpenCode composer."
  (interactive)
  (when opencode-remote--buffer-state
    (let ((window (get-buffer-window (opencode-remote-chat-state-composer opencode-remote--buffer-state))))
      (if window (select-window window) (pop-to-buffer (opencode-remote-chat-state-composer opencode-remote--buffer-state)))
      (when (fboundp 'evil-insert-state) (evil-insert-state)))))

(defun opencode-remote-focus-transcript ()
  "Move point to the OpenCode transcript."
  (interactive)
  (when opencode-remote--buffer-state
    (let ((window (get-buffer-window (opencode-remote-chat-state-transcript opencode-remote--buffer-state))))
      (if window (select-window window) (pop-to-buffer (opencode-remote-chat-state-transcript opencode-remote--buffer-state))))))

(defun opencode-remote--session-path (state suffix)
  (format "/session/%s/%s" (url-hexify-string (opencode-remote-chat-state-id state)) suffix))

(defun opencode-remote-send ()
  "Submit all text in the current session's composer asynchronously."
  (interactive)
  (let* ((state opencode-remote--buffer-state)
         (composer (and state (opencode-remote-chat-state-composer state)))
         (prompt (and (buffer-live-p composer)
                      (with-current-buffer composer (string-trim (buffer-substring-no-properties (point-min) (point-max)))))))
    (unless state (user-error "This is not an OpenCode buffer"))
    (unless (memq (opencode-remote-chat-state-status state) '(idle error))
      (user-error "OpenCode is still handling the current request"))
    (when (string-empty-p (or prompt "")) (user-error "Composer is empty"))
    (opencode-remote--status-set state 'submitting)
    (opencode-remote--http
     state "POST" (opencode-remote--session-path state "prompt_async")
     `((parts . (((type . "text") (text . ,prompt)))))
     (lambda (_result error-text)
       (if error-text
           (progn (opencode-remote--status-set state 'idle)
                  (opencode-remote--insert-notice state (concat "Send failed: " error-text) 'error))
         (let ((message-id (format "emacs-%s" (float-time))))
           (setf (opencode-remote-chat-state-pending-user-id state) message-id
                 (opencode-remote-chat-state-pending-user-prompt state) prompt)
           (opencode-remote--message-header state message-id "user")
           (opencode-remote--render-part state message-id
                                         `((id . "text") (type . "text") (text . ,prompt))))
         (with-current-buffer composer (let ((inhibit-read-only t)) (erase-buffer)))
         (push prompt (opencode-remote-chat-state-prompts state))
         (setf (opencode-remote-chat-state-prompt-index state) 0)
         (opencode-remote--status-set state 'busy)
         (with-current-buffer composer (opencode-remote-focus-transcript))))))
    (opencode-remote-focus-transcript) t))

(defun opencode-remote-abort ()
  "Request OpenCode to cancel the active generation."
  (interactive)
  (let ((state opencode-remote--buffer-state))
    (unless state (user-error "This is not an OpenCode buffer"))
    (unless (memq (opencode-remote-chat-state-status state) '(submitting busy retry permission question))
      (user-error "No active OpenCode request"))
    (opencode-remote--status-set state 'cancelling)
    (opencode-remote--http state "POST" (opencode-remote--session-path state "abort") nil
                           (lambda (_result error-text)
                             (when error-text
                               (opencode-remote--status-set state 'busy)
                               (opencode-remote--insert-notice state (concat "Cancel failed: " error-text) 'error))))))

(defun opencode-remote--pending-choice (table prompt)
  (let* ((ids (hash-table-keys table))
         (choice (completing-read prompt (mapcar #'(lambda (id) (format "%s" id)) ids) nil t)))
    (car (rassoc choice (mapcar (lambda (id) (cons id (format "%s" id))) ids)))))

(defun opencode-remote-reply-permission ()
  "Respond to a pending tool permission request."
  (interactive)
  (let* ((state opencode-remote--buffer-state)
         (table (and state (opencode-remote-chat-state-approvals state))))
    (unless (and table (> (hash-table-count table) 0)) (user-error "No pending permission request"))
    (let* ((id (opencode-remote--pending-choice table "Permission request: "))
           (request (gethash id table))
           (reply (completing-read "Reply: " '("once" "always" "reject") nil t))
           (path (if (eq (alist-get 'version request) 'v2)
                     (format "/api/session/%s/permission/%s/reply"
                             (url-hexify-string (opencode-remote-chat-state-id state))
                             (url-hexify-string id))
                   (format "/permission/%s/reply" (url-hexify-string id)))))
      (when (and (equal reply "always") (not (yes-or-no-p "Allow this permission persistently? ")))
        (user-error "Persistent approval cancelled"))
      (opencode-remote--http
       state "POST" path `((reply . ,reply))
       (lambda (_result error-text)
         (if error-text (opencode-remote--insert-notice state (concat "Permission reply failed: " error-text) 'error)
           (remhash id table)
           (opencode-remote--status-set state 'busy)
           (opencode-remote--insert-notice state
                                           (format "Permission %s: %s" reply (or (alist-get 'permission request) "request")))))))))

(defun opencode-remote-reply-question ()
  "Answer or reject a pending OpenCode question using completion."
  (interactive)
  (let* ((state opencode-remote--buffer-state)
         (table (and state (opencode-remote-chat-state-questions state))))
    (unless (and table (> (hash-table-count table) 0)) (user-error "No pending question"))
    (let* ((id (opencode-remote--pending-choice table "Question: "))
           (request (gethash id table))
           (v2 (eq (alist-get 'version request) 'v2))
           (base (if v2 (format "/api/session/%s/question/%s"
                                (url-hexify-string (opencode-remote-chat-state-id state))
                                (url-hexify-string id))
                   (format "/question/%s" (url-hexify-string id))))
           (action (completing-read "Action: " '("answer" "reject") nil t)))
      (if (equal action "reject")
          (opencode-remote--http
           state "POST" (concat base "/reject") nil
           (lambda (_result error-text)
             (if error-text
                 (opencode-remote--insert-notice state (concat "Question rejection failed: " error-text) 'error)
               (remhash id table)
               (opencode-remote--status-set state 'busy)
               (opencode-remote--insert-notice state "Question rejected."))))
        (let ((answers
               (mapcar (lambda (question)
                         (let ((options (mapcar (lambda (option) (alist-get 'label option))
                                                (alist-get 'options question)))
                               (prompt (or (alist-get 'question question) "Choose: ")))
                           (cond ((null options) (list (read-string (concat prompt " "))))
                                 ((alist-get 'multiple question)
                                  (completing-read-multiple prompt options nil t))
                                 (t (list (completing-read prompt options nil t)))))
                       (alist-get 'questions request))))
          (opencode-remote--http
           state "POST" (concat base "/reply")
           `((answers . ,(vconcat (mapcar #'vconcat answers))))
           (lambda (_result error-text)
             (if error-text
                 (opencode-remote--insert-notice state (concat "Answer failed: " error-text) 'error)
               (remhash id table)
               (opencode-remote--status-set state 'busy)
               (opencode-remote--insert-notice state "Question answered."))))))))))

(defun opencode-remote-previous-prompt ()
  "Replace composer text with an earlier submitted prompt."
  (interactive)
  (opencode-remote--cycle-prompt 1))

(defun opencode-remote-next-prompt ()
  "Replace composer text with a later submitted prompt."
  (interactive)
  (opencode-remote--cycle-prompt -1))

(defun opencode-remote--cycle-prompt (direction)
  (let* ((state opencode-remote--buffer-state)
         (prompts (and state (opencode-remote-chat-state-prompts state))))
    (unless prompts (user-error "No prompt history"))
    (let* ((index (max 0 (min (1- (length prompts))
                              (+ (opencode-remote-chat-state-prompt-index state) direction))))
           (composer (opencode-remote-chat-state-composer state)))
      (setf (opencode-remote-chat-state-prompt-index state) index)
      (with-current-buffer composer
        (let ((inhibit-read-only t)) (erase-buffer) (insert (nth index prompts))))
      (opencode-remote-focus-composer))))

(defun opencode-remote--select-session (context)
  "Select an existing session explicitly from CONTEXT."
  (let* ((sessions (opencode-remote-http-request
                    context "GET" "/session" nil
                    (lambda (result error-text)
                      (if error-text (user-error "Could not list sessions: %s" error-text)
                        (let* ((choices (mapcar #'opencode-remote--session-label result))
                               (choice (completing-read "OpenCode session: " choices nil t))
                               (index (cl-position choice choices :test #'equal)))
                          (unless index (user-error "Select an existing session"))
                          (opencode-remote--open-session context (alist-get 'id (nth index result))))))))
    sessions)))

(defun opencode-remote--session-label (session)
  (format "%s — %s" (or (alist-get 'title session) "Untitled") (alist-get 'id session)))

(defun opencode-remote-chat ()
  "Asynchronously list and open an existing OpenCode session."
  (interactive)
  (opencode-remote--select-session (opencode-remote-http-context)))

(defun opencode-remote--open-session (context session-id)
  (unless (and (stringp session-id) (not (string-empty-p session-id)))
    (user-error "Server returned an invalid session id"))
  (let ((state (opencode-remote--state-for context session-id)))
    (if (opencode-remote-chat-state-closed state)
        (opencode-remote--open-state state)
      (opencode-remote--display-state state))))

(defun opencode-remote-new-chat ()
  "Create a new server-side session and open its native chat view."
  (interactive)
  (let* ((context (opencode-remote-http-context))
         (title (read-string "New OpenCode session title: " "Emacs chat")))
    (opencode-remote-http-request
     context "POST" "/session" `((title . ,title))
     (lambda (session error-text)
       (if error-text (user-error "Could not create session: %s" error-text)
         (opencode-remote--open-session context (alist-get 'id session)))))))

(provide 'opencode-remote-ui)
;;; opencode-remote-ui.el ends here
