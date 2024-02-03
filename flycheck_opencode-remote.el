;;; opencode-remote.el --- OpenCode native Emacs client -*- lexical-binding: t; -*-

;;; Commentary:
;; Entry point for the HTTP, event-stream, and native chat UI modules.

;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'opencode-remote-ui)
(require 'opencode-remote-notifications)

(provide 'opencode-remote)
;;; opencode-remote.el ends here
