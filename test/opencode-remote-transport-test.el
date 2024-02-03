;;; opencode-remote-transport-test.el --- Transport tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Isolated transport tests; no server requests.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'opencode-remote-events
         (expand-file-name "../libraries/opencode-remote/opencode-remote-events"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))

(defmacro opencode-transport-test--http (&rest body)
  "Execute BODY with isolated URL retrieval and timers."
  (declare (indent 0) (debug t))
  `(let (retrieved timeout cancelled request-data request-headers request-url
                    request-redirects result calls cancel
                    (response (generate-new-buffer " *transport-test*")))
     (unwind-protect
         (cl-letf (((symbol-function 'url-retrieve)
                    (lambda (url callback &rest _)
                      (setq retrieved callback request-data url-request-data
                            request-headers url-request-extra-headers
                            request-redirects url-max-redirections request-url url)
                      response))
                   ((symbol-function 'run-at-time)
                    (lambda (_seconds _repeat fn) (setq timeout fn) 'test-timer))
                   ((symbol-function 'timerp) (lambda (x) (eq x 'test-timer)))
                   ((symbol-function 'cancel-timer) (lambda (_) (setq cancelled t))))
           (setq cancel
                 (opencode-remote-http-request
                  (list :base-url "http://localhost:8050" :headers '(("X-Test" . "snapshot")))
                  "GET" "/session" nil
                  (lambda (value error-text) (cl-incf calls) (setq result (list value error-text)))))
           ,@body
           ;; Each test inspects only the captures relevant to its contract.
           (ignore retrieved timeout cancelled request-data request-headers
                   request-url request-redirects result calls cancel))
       (when (buffer-live-p response) (kill-buffer response)))))

(defun opencode-transport-test--respond (buffer callback code body &optional status)
  "Fill BUFFER with CODE and BODY, then invoke CALLBACK with STATUS."
  (with-current-buffer buffer
    (setq-local url-http-response-status code)
    (insert "HTTP/1.1 response\r\nContent-Type: application/json\r\n\r\n" body)
    (funcall callback status)))

(ert-deftest opencode-http-204-cleanup ()
  (opencode-transport-test--http
    (setq calls 0)
    (opencode-transport-test--respond response retrieved 204 "")
    (should (equal result '(nil nil)))
    (should (= calls 1)) (should cancelled)
    (should-not (buffer-live-p response))
    (funcall timeout) (funcall cancel)
    (should (= calls 1))
    (should (null request-data)) (should (= request-redirects 0))))

(ert-deftest opencode-http-invalid-json-and-errors ()
  (dolist (case '((200 "<html>private</html>" nil "HTTP 200: Invalid JSON response")
                  (200 "{" nil "HTTP 200: Invalid JSON response")
                  (401 "private" nil "HTTP 401: request failed")
                  (302 "private" nil "HTTP 302: request failed")
                  (200 "private" (:error (error "Private")) "HTTP 200: transport error")))
    (opencode-transport-test--http
      (setq calls 0)
      (opencode-transport-test--respond response retrieved (nth 0 case) (nth 1 case) (nth 2 case))
      (should (equal result (list nil (nth 3 case))))
      (should (= calls 1)) (should cancelled)
      (should-not (buffer-live-p response)))))

(ert-deftest opencode-http-timeout-and-cancel ()
  (opencode-transport-test--http
    (setq calls 0)
    (funcall timeout) (funcall timeout) (funcall cancel)
    (should (equal result '(nil "Request timed out")))
    (should (= calls 1)) (should cancelled) (should-not (buffer-live-p response)))
  (opencode-transport-test--http
    (setq calls 0)
    (funcall cancel) (funcall cancel) (funcall timeout)
    (should (= calls 0)) (should cancelled) (should-not (buffer-live-p response))
    (with-temp-buffer (funcall retrieved nil))))

(ert-deftest opencode-http-context-and-url ()
  (let* ((opencode-remote-base-url (copy-sequence "http://localhost:8050/"))
         (opencode-remote-directory (copy-sequence "/tmp/a b/é"))
         (opencode-remote-workspace "a&b")
         (opencode-remote-password "test-only")
         (context (opencode-remote-http-context)))
    (aset opencode-remote-directory 1 ?X)
    (setq opencode-remote-base-url "http://elsewhere" opencode-remote-password "changed")
    (should (equal (opencode-remote-http-url context "/event")
                   "http://localhost:8050/event?directory=%2Ftmp%2Fa%20b%2F%C3%A9&workspace=a%26b"))
    (should (string-match-p "?x=1&directory=" (opencode-remote-http-url context "/session?x=1")))
    (should (equal (cdr (assoc "Authorization" (plist-get context :headers)))
                   (concat "Basic " (base64-encode-string "opencode:test-only" t))))
    (should-error (opencode-remote-http-url context "//elsewhere"))))

(ert-deftest opencode-http-post-empty-object-and-callback-error ()
  (let (buffer saved-data (count 0))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _)
                 (setq saved-data url-request-data buffer (generate-new-buffer " *http-sync*"))
                 (opencode-transport-test--respond buffer callback 200 "{}")
                 buffer)))
      (should-error
       (opencode-remote-http-request '(:base-url "http://localhost:8050") "POST" "/unused"
                                     (make-hash-table)
                                     (lambda (_result _error) (cl-incf count) (error "Callback failure")))
       :type 'error)
      (should (equal saved-data "{}")) (should (= count 1))
      (should-not (buffer-live-p buffer)))))

(ert-deftest opencode-http-start-failure ()
  (let ((calls 0) result)
    (cl-letf (((symbol-function 'url-retrieve) (lambda (&rest _) (error "Private"))))
      (funcall (opencode-remote-http-request
                '(:base-url "http://localhost:8050") "GET" "/event" nil
                (lambda (_value err) (cl-incf calls) (setq result err))))
      (should (= calls 1)) (should (equal result "HTTP transport error")))))

(ert-deftest opencode-events-fragmented-frames ()
  (let* (events (parser (opencode-remote-events-parser (lambda (event) (push event events)))))
    (dolist (chunk '(": heartbeat\r" "\n\r" "\ndata: {\r\n" "data: \"text\":\"é😀\"}\r" "\n\r" "\n"
                     "event: ignored\ndata: {\"n\":1}\n\ndata: {\"n\":1}\n\n"))
      (funcall parser chunk))
    (should (equal (nreverse events) '(((text . "é😀")) ((n . 1)) ((n . 1)))))))

(ert-deftest opencode-events-character-chunks-and-errors ()
  (let* (events (parser (opencode-remote-events-parser (lambda (event) (push event events)))))
    (mapc (lambda (char) (funcall parser (char-to-string char))) "data: {\"text\":\"é😀\"}\r\n\r\n")
    (should (equal events '(((text . "é😀"))))))
  (let ((parser (opencode-remote-events-parser #'ignore)))
    (should-error (funcall parser "data: HTML\n\n") :type 'opencode-remote-events-invalid)
    (should-error (funcall parser "data: {}\n\n") :type 'opencode-remote-events-invalid))
  (let ((opencode-remote-events-max-frame 16)
        (parser (opencode-remote-events-parser #'ignore)))
    (funcall parser "data: ")
    (should-error (funcall parser "12345678901234567") :type 'opencode-remote-events-invalid)))

(ert-deftest opencode-events-process-contract ()
  (let (options input disposed states events stderr)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq options args stderr (plist-get args :stderr)) 'mock))
              ((symbol-function 'process-send-string) (lambda (_ text) (setq input text)))
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'processp) (lambda (p) (eq p 'mock)))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'set-process-filter) #'ignore)
              ((symbol-function 'set-process-sentinel) #'ignore)
              ((symbol-function 'delete-process) (lambda (_) (setq disposed t))))
      (let ((close (opencode-remote-events-open
                    '(:base-url "http://localhost:8050" :headers (("Authorization" . "Basic test-only")))
                    (lambda (event) (push event events)) (lambda (state) (push state states)))))
        (should-not states)
        (should (equal (seq-take (plist-get options :command) 4) '("curl" "--disable" "--config" "-")))
        (should-not (string-match-p "test-only" (prin1-to-string (plist-get options :command))))
        (should (string-match-p "Authorization: Basic test-only" input))
        (should (equal (plist-get options :coding) '(utf-8-unix . utf-8-unix)))
        (funcall (plist-get options :filter) 'mock
                 "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n: heartbeat\n\n")
        (should (equal states '("connected")))
        (funcall (plist-get options :filter) 'mock "data: {}\n\n")
        (should (equal states '("connected"))) (should (= (length events) 1))
        (funcall close) (funcall close)
        (should disposed) (should-not (buffer-live-p stderr))
        (should (equal states '("connected")))))))

(ert-deftest opencode-events-disconnect-on-invalid-or-exit ()
  (dolist (failure '(parse exit start))
    (let (options states stderr)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq options args stderr (plist-get args :stderr))
                   (when (eq failure 'start) (error "Private failure"))
                   'mock))
                ((symbol-function 'process-send-string) #'ignore)
                ((symbol-function 'process-send-eof) #'ignore)
                ((symbol-function 'processp) (lambda (p) (eq p 'mock)))
                ((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'set-process-filter) #'ignore)
                ((symbol-function 'set-process-sentinel) #'ignore)
                ((symbol-function 'delete-process) #'ignore))
        (let ((close (opencode-remote-events-open
                      '(:base-url "http://localhost:8050") #'ignore
                      (lambda (state) (push state states)))))
          (pcase failure
            ('parse (funcall (plist-get options :filter) 'mock
                             "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: invalid\n\n"))
            ('exit (funcall (plist-get options :sentinel) 'mock "Private stderr")))
          (should (equal states (if (eq failure 'parse)
                                    '("disconnected" "connected")
                                  '("disconnected"))))
          (should-not (buffer-live-p stderr))
          (funcall close)
          (should (equal states (if (eq failure 'parse)
                                    '("disconnected" "connected")
                                                                      '("disconnected")))))))))
                                  
                                  (ert-deftest opencode-events-byte-fragmented-utf8 ()
  ;; Exercise Emacs's incremental process decoder, not just Lisp substrings.
  (let* (events
         (parser (opencode-remote-events-parser (lambda (event) (push event events))))
         (process (make-process :name "transport-utf8-test" :buffer nil :noquery t
                                :command '("cat") :connection-type 'pipe
                                :coding '(utf-8-unix . binary)
                                :filter (lambda (_ text) (funcall parser text))
                                :sentinel #'ignore)))
    (unwind-protect
        (progn
          (mapc (lambda (byte)
                  (process-send-string process (unibyte-string byte))
                  (accept-process-output process 0.01))
                (encode-coding-string "data: {\"text\":\"é😀\"}\r\n\r\n" 'utf-8))
          (let ((deadline (+ (float-time) 2)))
            (while (and (not events) (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (should (equal events '(((text . "é😀"))))))
      (when (process-live-p process) (delete-process process)))))

(provide 'opencode-remote-transport-test)
;;; opencode-remote-transport-test.el ends here
