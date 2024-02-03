;;; opencode-remote-http.el --- Scoped HTTP transport -*- lexical-binding: t; -*-

;;; Commentary:
;; Independent transport; contexts are private snapshots, read-only by contract.
;;; Code:
(require 'cl-lib)
(require 'json)
(require 'url)
(require 'url-http)
(require 'subr-x)

(defvar url-http-response-status)

(defgroup opencode-remote nil "Connect to an existing OpenCode server." :group 'tools)
(defcustom opencode-remote-base-url "http://127.0.0.1:8050" "Server base URL." :type 'string :group 'opencode-remote)
(defcustom opencode-remote-password nil "Server password, or nil for the existing server setting." :type '(choice (const nil) string) :group 'opencode-remote)
(defcustom opencode-remote-username "opencode" "HTTP authentication username." :type 'string :group 'opencode-remote)
(defcustom opencode-remote-directory nil "Server-side directory, never a local working directory." :type '(choice (const nil) string) :group 'opencode-remote)
(defcustom opencode-remote-workspace nil "Server-side workspace identifier." :type '(choice (const nil) string) :group 'opencode-remote)
(defcustom opencode-remote-http-timeout 30 "Request timeout in seconds." :type 'number :group 'opencode-remote)

(defun opencode-remote--password ()
  "Return the configured password without displaying it."
  (or opencode-remote-password
      (and (boundp 'opencode-server-password) (symbol-value 'opencode-server-password))
      (read-passwd "OpenCode server password: ")))

(defun opencode-remote-http-context ()
  "Capture a read-only-by-contract snapshot, including authentication headers."
  (let ((base (string-remove-suffix "/" opencode-remote-base-url)))
    (unless (and (string-match-p "\\`https?://" base)
                 (not (string-match-p "[\r\n?#]" base))
                 (not (url-user (url-generic-parse-url base))))
      (error "Invalid server base URL"))
    (list :base-url (copy-sequence base)
          :directory (and opencode-remote-directory (copy-sequence opencode-remote-directory))
          :workspace (and opencode-remote-workspace (copy-sequence opencode-remote-workspace))
          :headers (list (cons "Authorization"
                               (concat "Basic " (base64-encode-string
                                                 (encode-coding-string
                                                  (concat opencode-remote-username ":" (opencode-remote--password)) 'utf-8) t)))
                         (cons "Accept" "application/json")
                         (cons "Content-Type" "application/json")))))

(defun opencode-remote-http-url (context path)
  "Build PATH using the captured server-side scope in CONTEXT."
  (unless (and (string-prefix-p "/" path) (not (string-prefix-p "//" path))
               (not (string-match-p "[\r\n#]" path)))
    (error "Invalid request path"))
  (let ((query (delq nil
                     (mapcar (lambda (entry)
                               (let ((value (plist-get context (car entry))))
                                 (when value (concat (cdr entry) "=" (url-hexify-string value)))))
                             '((:directory . "directory") (:workspace . "workspace"))))))
    (concat (plist-get context :base-url) path
            (when query (concat (if (string-match-p "?" path) "&" "?")
                                (string-join query "&"))))))

(defun opencode-remote-http-request (context method path data callback)
  "Request METHOD and PATH in CONTEXT; call CALLBACK with (RESULT ERROR-STRING).
The callback runs at most once.  Return a silent local cancellation function.
Cancellation never sends an application-level abort.  GET ignores DATA.
Hash tables encode empty objects.  Non-204 successes require application/json
or a media type with a +json suffix.  Response errors include the HTTP status
when available, but never include response bodies or credentials."
  (let ((done nil) buffer timer callback-error)
    (cl-labels
        ((cleanup ()
           (when (timerp timer) (cancel-timer timer))
           (when (buffer-live-p buffer)
             (let ((process (get-buffer-process buffer)))
               (when process (delete-process process)))
             (kill-buffer buffer)))
         (finish (result error-text)
           (unless done
             (setq done t)
             (cleanup)
             (condition-case err
                 (funcall callback result error-text)
               (error (setq callback-error err) (signal (car err) (cdr err)))))))
      (condition-case err
          (let ((url-request-method method)
                (url-request-extra-headers (copy-tree (plist-get context :headers)))
                (url-request-data (and (not (equal method "GET")) data
                                       (encode-coding-string (json-encode data) 'utf-8)))
                (url-max-redirections 0)
                (url-proxy-services nil)
                (url-automatic-caching nil))
            (setq timer (run-at-time opencode-remote-http-timeout nil
                                     (lambda () (finish nil "Request timed out"))))
            (setq buffer
                  (url-retrieve
                   (opencode-remote-http-url context path)
                   (lambda (status)
                     (let ((response-buffer (current-buffer)))
                       (if done
                           (when (buffer-live-p response-buffer) (kill-buffer response-buffer))
                         (setq buffer response-buffer)
                         (let ((result nil) error-text)
                           (condition-case nil
                               (cond
                                ((plist-get status :error) (setq error-text "HTTP transport error"))
                                ((not (and (integerp url-http-response-status)
                                           (<= 200 url-http-response-status)
                                           (< url-http-response-status 300)))
                                 (setq error-text "HTTP request failed"))
                                ((= url-http-response-status 204))
                                (t
                                 (goto-char (point-min))
                                 (unless (re-search-forward "\r?\n\r?\n" nil t)
                                   (error "Invalid response"))
                                 (let* ((body-start (point))
                                        (content-type
                                         (save-excursion
                                           (goto-char (point-min))
                                           (let ((case-fold-search t))
                                             (when (re-search-forward
                                                    "^Content-Type:[ \t]*\\([^\r\n]*\\)"
                                                    body-start t)
                                               (downcase (string-trim
                                                          (car (split-string
                                                                (match-string-no-properties 1) ";")))))))))
                                   (if (not (and content-type
                                                 (or (equal content-type "application/json")
                                                     (string-match-p
                                                      "\\`[-!#$%&'*+.^_`|~[:alnum:]]+/[-!#$%&'*+.^_`|~[:alnum:]]+\\+json\\'"
                                                      content-type))))
                                       (setq error-text "Unexpected Content-Type")
                                     (setq result (json-parse-string
                                                   (decode-coding-string
                                                    (buffer-substring-no-properties body-start (point-max)) 'utf-8)
                                                   :object-type 'alist :array-type 'list
                                                   :null-object nil :false-object nil))))))
                             (error (setq error-text "Invalid JSON response")))
                           (when (and error-text (integerp url-http-response-status))
                             (setq error-text
                                   (format "HTTP %d: %s" url-http-response-status
                                           (string-remove-prefix "HTTP " error-text))))
                           (finish result error-text)))))
                   nil t t))
            (if done (cleanup)
              (unless (buffer-live-p buffer) (finish nil "HTTP transport error"))))
        (error (if callback-error (signal (car err) (cdr err))
                 (finish nil "HTTP transport error"))))
      (lambda () (unless done (setq done t) (cleanup))))))

(provide 'opencode-remote-http)
;;; opencode-remote-http.el ends here
