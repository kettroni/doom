;;; opencode-remote-events.el --- Incremental SSE transport -*- lexical-binding: t; -*-
;;; Commentary:
;; No reconnect or deduplication policy belongs in this transport.
;;; Code:
(require 'opencode-remote-http
         (expand-file-name "opencode-remote-http"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(define-error 'opencode-remote-events-invalid "Invalid event stream")
(defconst opencode-remote-events-max-frame (* 4 1024 1024))

(defun opencode-remote-events-parser (callback)
  "Return a closure feeding decoded text chunks to CALLBACK as JSON alists.
Accept LF and CRLF, including CRLF split across chunks.  Invalid JSON or
frames exceeding `opencode-remote-events-max-frame' signal a sanitized error."
  (let ((pending "") (data nil) (size 0) (failed nil))
    (lambda (chunk)
      (when failed (signal 'opencode-remote-events-invalid nil))
      (let ((start 0) end)
        (while (< start (length chunk))
          (setq end (string-match "\n" chunk start))
          (let ((part (substring chunk start (if end (1+ end) (length chunk)))))
            (cl-incf size (string-bytes part))
            (when (> size opencode-remote-events-max-frame)
              (setq failed t pending "" data nil)
              (signal 'opencode-remote-events-invalid nil))
            (setq pending (concat pending part)))
          (setq start (if end (1+ end) (length chunk)))
          (when end
            (let ((line (string-remove-suffix "\r" (substring pending 0 -1))))
              (setq pending "")
              (cond
               ((string-empty-p line)
                (let ((payload (and data (string-join (nreverse data) "\n"))))
                  (setq data nil size 0)
                  (when payload
                    (let ((event
                           (condition-case nil
                               (progn
                                 (unless (string-match-p "\\`[[:space:]]*{" payload)
                                   (error "Not an object"))
                                 (json-parse-string payload :object-type 'alist :array-type 'list
                                                    :null-object nil :false-object nil))
                             (error (setq failed t)
                                    (signal 'opencode-remote-events-invalid nil)))))
                      (funcall callback event)))))
               ((or (equal line "data") (string-prefix-p "data:" line))
                (let ((value (if (equal line "data") "" (substring line 5))))
                  (push (if (string-prefix-p " " value) (substring value 1) value) data)))))))))))

(defun opencode-remote-events--config-quote (text)
  "Quote TEXT for curl stdin configuration without emitting it."
  (concat "\"" (replace-regexp-in-string
                 "[\\\"\r\n]"
                 (lambda (match)
                   (pcase match ("\r" "\\r") ("\n" "\\n") (_ (concat "\\" match))))
                 text t t) "\""))

(defun opencode-remote-events-open (context on-event on-state)
  "Open CONTEXT's event stream and return an idempotent silent disposer.
ON-EVENT receives JSON alists.  ON-STATE receives strings connected or
disconnected.  Authentication is sent exclusively through curl stdin."
  (let (process stderr closed connected headers-ready (response-pending ""))
    (cl-labels
        ((dispose ()
           (setq closed t)
           (when (processp process)
             (set-process-filter process nil)
             (set-process-sentinel process #'ignore)
             (when (process-live-p process) (delete-process process)))
           (when (buffer-live-p stderr) (kill-buffer stderr)))
         (disconnect ()
           (unless closed (dispose) (funcall on-state "disconnected"))))
      (let ((parser (opencode-remote-events-parser
                     (lambda (event)
                       (unless closed
                         (unless connected
                           (setq connected t)
                           (funcall on-state "connected"))
                         (unless closed (funcall on-event event)))))))
        (condition-case nil
            (let ((url (opencode-remote-http-url context "/event"))
                  (config ""))
              (dolist (header (plist-get context :headers))
                (unless (equal (downcase (car header)) "accept")
                  (setq config (concat config "header = "
                                       (opencode-remote-events--config-quote
                                        (concat (car header) ": " (cdr header))) "\n"))))
              (setq config (concat config "header = \"Accept: text/event-stream\"\n"))
              (setq stderr (generate-new-buffer " *opencode-event-stderr*"))
              (setq process
                    (make-process
                     :name "opencode-events" :buffer nil :stderr stderr :noquery t
                     :coding '(utf-8-unix . utf-8-unix) :connection-type 'pipe
                     :command (list "curl" "--disable" "--config" "-" "--no-buffer"
                                    "--silent" "--show-error" "--fail" "--include" "--max-redirs" "0"
                                    "--proxy" "" "--noproxy" "*" "--request" "GET" url)
                     :filter (lambda (_proc text)
                               (unless closed
                                 (condition-case nil
                                     (if headers-ready
                                         (funcall parser text)
                                       (setq response-pending (concat response-pending text))
                                       (when (> (string-bytes response-pending) (* 128 1024))
                                         (disconnect))
                                       (let ((boundary (string-match "\r?\n\r?\n" response-pending)))
                                         (when boundary
                                           (let* ((header-end (match-end 0))
                                                  (headers (substring response-pending 0 header-end))
                                                  (body (substring response-pending header-end)))
                                             (setq headers-ready t response-pending "")
                                             (if (and (string-match "\\`HTTP/[0-9.]+[ \t]+\\([0-9][0-9][0-9]\\)" headers)
                                                      (<= 200 (string-to-number (match-string 1 headers)))
                                                      (< (string-to-number (match-string 1 headers)) 300))
                                                 (progn
                                                   (unless connected
                                                     (setq connected t)
                                                     (funcall on-state "connected"))
                                                   (unless (or closed (string-empty-p body))
                                                     (funcall parser body)))
                                               (disconnect))))))
                                   (opencode-remote-events-invalid (disconnect)))))
                     :sentinel (lambda (proc _message)
                                 (when (memq (process-status proc) '(exit signal failed closed))
                                   (disconnect)))))
              (process-send-string process config)
              (process-send-eof process))
          (error (disconnect))))
      #'dispose)))

(provide 'opencode-remote-events)
;;; opencode-remote-events.el ends here
