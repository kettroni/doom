;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; display stuff
(setq doom-font (font-spec :family "Fira Code" :size 22 :weight 'semi-light))
(setq doom-theme 'doom-gruvbox)
(setq display-line-numbers-type 'relative)
(setq doom-modeline-height 5.0)
(custom-set-faces
 '(mode-line ((t (:family "Fira Code" :height 1.0))))
 '(mode-line-inactive ((t (:family "Fira Code" :height 1.0)))))

(setq scroll-margin 3)



;; Forces a standard dual-fallback transparent layout profile
(set-frame-parameter nil 'alpha '(85 . 85))
(add-to-list 'default-frame-alist '(alpha . (85 . 85)))

;; Github auth src
(setq auth-sources '("~/.authinfo"))

;; org
(setq org-directory "~/org/")

;; projectile
(setq projectile-project-search-path '("~/code"))
(setq projectile-auto-discover t)

;; Bind after Projectile loads so the command and its keymap are available.
(after! projectile
  (map! :leader
        :desc "Switch project" "p p" #'projectile-switch-project))

;; My multiple cursors setup.
(defhydra mc-hydra (:color pink
                    :hint nil
                    :pre (evil-mc-pause-cursors))
  "
^Match^            ^Line-wise^           ^Manual^
^^^^^^----------------------------------------------------
_g_: match all     _J_: make & go down   _o_: toggle here
_m_: make & next   _K_: make & go up     _r_: remove last
_M_: make & prev   ^ ^                   _R_: remove all
_n_: skip & next   ^ ^                   _p_: pause/resume
_N_: skip & prev


Current pattern: %`evil-mc-pattern

"
  ("g" #'evil-mc-make-all-cursors)
  ("m" #'evil-mc-make-and-goto-next-match)
  ("M" #'evil-mc-make-and-goto-prev-match)
  ("n" #'evil-mc-skip-and-goto-next-match)
  ("N" #'evil-mc-skip-and-goto-prev-match)
  ("J" #'evil-mc-make-cursor-move-next-line)
  ("K" #'evil-mc-make-cursor-move-prev-line)
  ("o" #'+multiple-cursors/evil-mc-toggle-cursor-here)
  ("r" #'+multiple-cursors/evil-mc-undo-cursor)
  ("R" #'evil-mc-undo-all-cursors)
  ("p" #'+multiple-cursors/evil-mc-toggle-cursors)
  ("q" #'evil-mc-resume-cursors "quit" :color blue)
  ("<escape>" #'evil-mc-resume-cursors "quit" :color blue))
(map!
 (:when (modulep! :editor multiple-cursors)
   :prefix "g"
   :nv "o" #'mc-hydra/body))

;; harpoon
(setq harpoon-project-package '+workspace-current-name)
(setq harpoon-without-project-function '+workspace-current-name)
(map! "C-1" 'harpoon-go-to-1
      "C-2" 'harpoon-go-to-2
      "C-3" 'harpoon-go-to-3
      "C-4" 'harpoon-go-to-4
      "C-5" 'harpoon-go-to-5
      ;; TODO: fix this.
      ;; "C-6" 'harpoon-go-to-6
      "C-7" 'harpoon-go-to-7
      "C-8" 'harpoon-go-to-8
      "C-9" 'harpoon-go-to-9
      "C-0" 'harpoon-clear
      ;; Alternative for faster changing.
      "C-k" 'harpoon-go-to-1
      "C-j" 'harpoon-go-to-2
      "C-q" 'harpoon-go-to-3
      "C-'" 'harpoon-go-to-4
      :leader "a" 'harpoon-add-file)
(defun entry-or-exit-harpoon ()
  (interactive)
  (if (eq major-mode 'harpoon-mode)
      (progn
        (basic-save-buffer)
        (+popup/close))
    (harpoon-toggle-file)
    (+popup/buffer)))
(map! :leader "u" #'entry-or-exit-harpoon)

;; workspace
(map! :nvig "C-<tab>" #'+workspace/switch-right)
(map! :nvig "C-S-<tab>" #'+workspace/switch-left)

;; frame
(map! :nvig "M-<tab>" #'+evil/next-frame)
(map! :nvig "M-S-<tab>" #'+evil/previous-frame)

;; compile
(defun compile-maximize ()
  "Execute a compile command from the current project's root and maximizes window."
  (interactive)
  (+ivy/project-compile)
  (evil-window-down 1)
  (doom/window-maximize-buffer))
(map! :nvg "C-M-c" #'compile-maximize)

;; Preserve Counsel's compile candidates while enabling shell and filename
;; completion in its Ivy minibuffer.
(after! counsel
  (define-key counsel-compile-map (kbd "TAB") #'completion-at-point)
  (defun my/counsel-compile-shell-completion-setup ()
    "Enable shell command completion in the Counsel compile prompt."
    (when (and (boundp 'ivy-last)
               ivy-last
               (eq (ivy-state-caller ivy-last) 'counsel-compile))
      (require 'shell)
      (setq-local default-directory
                  (or counsel-compile--current-build-dir default-directory))
      (shell-completion-vars)))
  (add-hook 'minibuffer-setup-hook
            #'my/counsel-compile-shell-completion-setup))

(defun recompile-close ()
  "Execute a recompile command from the current project's root and close minibuffer."
  (interactive)
  (project-recompile)
  (+popup/toggle))
(map! :nvg "M-r" #'recompile-close)
(defun recompile-maximize ()
  "Execute a compile command from the current project's root and maximizes window."
  (interactive)
  (recompile)
  (evil-window-down 1)
  (doom/window-maximize-buffer))
(map! :nvg "M-C" #'recompile-maximize)

;; doom scratch buffer
(defun open-doom-scratch-buffer-maximized ()
  "Open or close the *doom:scratch* buffer and maximize it."
  (interactive)
  (if (get-buffer-window "*doom:scratch*")
      (switch-to-buffer (other-buffer))
    (doom/open-scratch-buffer)
    (call-interactively #'+popup/raise)))
(defun open-doom-project-scratch-buffer-maximized ()
  "Open or close the *doom:project-scratch* buffer and maximize it."
  (interactive)
  (if (get-buffer-window "*doom:project-scratch*")
      (switch-to-buffer (other-buffer))
    (doom/open-project-scratch-buffer)
    (call-interactively #'+popup/raise)))
(map! :leader "x" #'open-doom-scratch-buffer-maximized
      (:prefix ("p" . "project")
       :desc "Open project scratch buffer" "x" #'open-doom-project-scratch-buffer-maximized))

;; magit
(after! magit
  (map! :map magit-mode-map
        :nv "C-<tab>" #'+workspace/switch-right
        :nv "C-k"     #'harpoon-go-to-1
        :nv "C-j"     #'harpoon-go-to-2
        :nv "C-q"     #'harpoon-go-to-3
        :nv "C-M-f"   #'magit-commit-instant-fixup))

;; clojure
(defun eval-surrounding-or-next-closure ()
  "Evaluates surrounding closure if found, otherwise the next closure."
  (interactive)
  (save-excursion
    (let ((original-point (point)))
      (evil-visual-char)
      (call-interactively #'evil-a-paren)
      (call-interactively #'+eval:region)
      (goto-char original-point))))
;; (map! :leader "e" #'eval-surrounding-or-next-closure)

(defun cider-repl-new-buffer ()
  "Wrapper for `cider-jack-in-clj' that avoids splitting the window."
  (interactive)
  (+eval/open-repl-same-window)
  ;; (switch-to-buffer (other-buffer))
  )
(defun open-or-create-repl ()
  "Switch to a CIDER REPL buffer for the current workspace.
If not found, create a new CIDER REPL buffer."
  (interactive)
  (let* ((workspace-name (+workspace-current-name))
         (matching-buffers (seq-filter (lambda (buf)
                                         (and (string-prefix-p "*cider-repl" (buffer-name buf))
                                              (string-match-p workspace-name (buffer-name buf))))
                                       (buffer-list))))
    (if matching-buffers
        (switch-to-buffer (car matching-buffers))
      (cider-repl-new-buffer))))
(defun open-or-create-cljs-repl ()
  "Switch to a CIDER REPL buffer for the current workspace.
If not found, create a new CIDER REPL buffer.
Switch to previous buffer if the current buffer is the REPL."
  (interactive)
  (let* ((workspace-name (+workspace-current-name))
         (matching-buffers (seq-filter (lambda (buf)
                                         (and (string-prefix-p "*cider-repl" (buffer-name buf))
                                              (string-match-p workspace-name (buffer-name buf))
                                              (string-match-p "cljs" (buffer-name buf))))
                                       (buffer-list))))
    (if matching-buffers
        ;; If the current buffer is a REPL, switch to the previous buffer.
        (if (string-match-p "*cider-repl" (buffer-name))
            (previous-buffer)
          ;; Otherwise, switch to the first matching buffer.
          (switch-to-buffer (car matching-buffers)))
      (cider-repl-new-buffer))))
(defun cider-eval-last-repl ()
  (interactive)
  (open-or-create-repl)
  (while (not (string-match "*cider-repl" (buffer-name)))
    (accept-process-output nil 0.1))
  (cider-repl-backward-input)
  (cider-repl-return)
  (previous-buffer))

;; cider bindings in clojure mode and clojure repl, like this but for both clojure and cider repls
(map! :map (clojure-mode-map cider-repl-mode-map)
      (:desc "Open repl in new buffer" "M-n" #'open-or-create-repl
       :desc "Open cider scratch buffer" "M-s" #'open-doom-project-scratch-buffer-maximized)
      "C-M-e" #'clojure-align
      :leader
      "l" #'cider-load-buffer
      "y" #'cider-kill-last-result
      "v" #'cider-eval-last-repl)

(setq! clojure-indent-style 'align-arguments)

;; evil-normal state
(defun next-open-paren ()
  (interactive)
  (forward-char 1)
  (while (not (looking-at-p "("))
    (forward-char 1)))
(defun previous-open-paren ()
  (interactive)
  (backward-char 1)
  (while (not (looking-at-p "("))
    (backward-char 1)))
(defun previous-closing-paren ()
  (interactive)
  (backward-char 1)
  (while (not (looking-at-p ")"))
    (backward-char 1)))
(defun next-open-paren-same-level ()
  "Move point to the next open parenthesis at the same level."
  (interactive)
  (evil-visual-char)
  (call-interactively #'evil-a-paren)
  (evil-force-normal-state)
  (next-open-paren))
(defun previous-open-paren-same-level ()
  "Move point to the previous open parenthesis at the same level."
  (interactive)
  (evil-visual-char)
  (call-interactively #'evil-a-paren)
  (evil-force-normal-state)
  (evil-jump-item)
  (previous-closing-paren)
  (evil-jump-item))
(defun wrap-closure-insert ()
  "Wraps the surrounding closure with new parentheses and starts inserting."
  (interactive)
  (evil-visual-char)
  (call-interactively #'evil-a-paren)
  (evil-surround-region (region-beginning) (region-end) ?\( ?\))
  (evil-insert 1)
  (evil-forward-char)
  (insert " ")
  (evil-backward-char))
(defun wrap-visual-insert ()
  "Wraps the surrounding closure with new parentheses and starts inserting."
  (interactive)
  (evil-surround-region (region-beginning) (region-end) ?\( ?\))
  (evil-insert 1)
  (evil-forward-char)
  (insert " ")
  (evil-backward-char))
(remove-hook 'doom-first-input-hook #'evil-snipe-mode)
(defun avy-goto-lisp-char (char1 &optional arg beg end)
  "Jump to the currently visible CHAR1 followed by CHAR2.
The window scope is determined by `avy-all-windows'.
When ARG is non-nil, do the opposite of `avy-all-windows'.
BEG and END narrow the scope where candidates are searched."
  (interactive (list (let ((c1 (read-char "char 1: " t)))
                       (if (memq c1 '(? ?\b))
                           (keyboard-quit)
                         c1))
                     current-prefix-arg
                     nil nil))
  (when (eq char1 ?
)
    (setq char1 ?\n))
  (avy-with avy-goto-char-2
    (avy-jump
     (regexp-quote (string ?\( char1))
     :window-flip arg
     :beg beg
     :end end)))
(map! :map (evil-normal-state-map evil-visual-state-map)
      ")" 'next-open-paren
      "(" 'previous-open-paren
      "[" 'previous-open-paren-same-level
      "]" 'next-open-paren-same-level
      "C-a" 'magit-status
      "M-)" #'wrap-closure-insert
      "?" #'cider-eval-dwim
      "C-?" #'eval-surrounding-or-next-closure
      "^" #'cider-inspect-last-result
      "<backspace>" #'avy-goto-lisp-char
      "m"   #'avy-resume
      ";" #'avy-prev
      "," #'avy-next
      "s" #'avy-isearch
      "RET" #'evil-avy-goto-char-timer)
(map! :map evil-visual-state-map "M-)" #'wrap-visual-insert)
(setq! avy-timeout-seconds 0.25)

;; evil-insert state
(map! (:nvi "C-y" #'evil-paste-after)
      (:i "C-n" #'evil-next-line
          "C-p" #'evil-previous-line))

(after! evil
  (add-to-list 'evil-buffer-regexps '("^\\*vterm" . nil)))

;; Enable this only in vterm buffers used for the remote OpenCode TUI.
;; It forwards OpenCode's Meta shortcuts and opts this buffer into OSC 52.
(defvar opencode-vterm-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-o") #'opencode-vterm-mode)
    ;; Keep Doom workspace navigation available in the terminal view.
    (define-key map (kbd "C-<tab>") #'+workspace/switch-right)
    (define-key map (kbd "C-S-<tab>") #'+workspace/switch-left)
    ;; Minor-mode maps outrank Evil's state-local map, so put terminal
    ;; forwarding here too (notably C-SPC, which Company can otherwise grab).
    (dolist (key '("C-n" "C-p" "C-y" "C-SPC"))
      (define-key map (kbd key) #'vterm--self-insert))
    (dolist (key '("M-c" "M-n" "M-g" "M-r" "M-h" "M-m" "M-j" "M-i" "M-v" "M-s" "M-w" "M-u" "M-p" "M-q" "M-d" "M-<up>" "M-<down>"))
      (define-key map (kbd key) #'vterm--self-insert-meta))
    map)
  "Keymap for `opencode-vterm-mode'.")

(define-minor-mode opencode-vterm-mode
  "Make a vterm buffer suitable for interacting with remote OpenCode."
  :lighter " OpenCode-vterm"
  :keymap opencode-vterm-mode-map
  (unless (derived-mode-p 'vterm-mode)
    (setq opencode-vterm-mode nil)
    (user-error "OpenCode-vterm mode can only be enabled in a vterm buffer"))
  (if opencode-vterm-mode
      (progn
        ;; Accept remote OSC 52 clipboard writes only in explicitly opted-in
        ;; OpenCode vterm buffers; vterm disables this globally for security.
        (setq-local vterm-enable-manipulate-selection-data-by-osc52 t)
        (when (fboundp 'company-mode) (company-mode -1))
        (when (and (boundp 'evil-local-set-key) (bound-and-true-p evil-local-mode))
          (dolist (key '("C-n" "C-p" "C-y" "C-SPC"))
            (evil-local-set-key 'insert (kbd key) #'vterm--self-insert))
          (dolist (key '("M-c" "M-n" "M-g" "M-r" "M-h" "M-m" "M-j" "M-i" "M-v" "M-s" "M-w" "M-u" "M-p" "M-q" "M-d" "M-<up>" "M-<down>"))
            (evil-local-set-key 'insert (kbd key) #'vterm--self-insert-meta))))
    (kill-local-variable 'vterm-enable-manipulate-selection-data-by-osc52)
    (when (and (boundp 'evil-local-set-key) (bound-and-true-p evil-local-mode))
      (dolist (key '("C-n" "C-p" "C-y" "C-SPC" "M-c" "M-n" "M-g" "M-r" "M-h" "M-m" "M-j" "M-i" "M-v" "M-s" "M-w" "M-u" "M-p" "M-q" "M-d" "M-<up>" "M-<down>"))
        (evil-local-set-key 'insert (kbd key) nil)))))

(defvar-local my-vterm-toggle-return-buffer nil
  "Non-vterm buffer to return to when toggling out of this vterm.")

(defun my/toggle-vterm-workspace-buffer ()
  "Toggle between this workspace's vterm and the last non-vterm buffer.
Create a fullscreen vterm session if this workspace has none."
  (interactive)
  (let* ((current (current-buffer))
         (workspace-buffers (+workspace-buffer-list)))
    (if (derived-mode-p 'vterm-mode)
        (let ((target (and (buffer-live-p my-vterm-toggle-return-buffer)
                           (memq my-vterm-toggle-return-buffer workspace-buffers)
                           (not (with-current-buffer my-vterm-toggle-return-buffer
                                  (derived-mode-p 'vterm-mode)))
                           my-vterm-toggle-return-buffer)))
          (unless target
            (setq target
                  (seq-find (lambda (buffer)
                              (and (memq buffer workspace-buffers)
                                   (with-current-buffer buffer
                                     (not (derived-mode-p 'vterm-mode)))))
                            (buffer-list))))
          (unless target
            (user-error "No previous non-vterm buffer in this workspace"))
          (switch-to-buffer target))
      (let ((terminal (seq-find (lambda (buffer)
                                  (with-current-buffer buffer
                                    (derived-mode-p 'vterm-mode)))
                                workspace-buffers)))
        (if terminal
            (progn
              (with-current-buffer terminal
                (setq-local my-vterm-toggle-return-buffer current))
              (switch-to-buffer terminal)
              (doom/window-maximize-buffer))
          (vterm t)
          (setq-local my-vterm-toggle-return-buffer current)
          (doom/window-maximize-buffer))))))

(map! :nvi "M-t" #'my/toggle-vterm-workspace-buffer)
(after! vterm
  (map! :map vterm-mode-map
        "C-c C-o" #'opencode-vterm-mode
        "C-<tab>" #'+workspace/switch-right
        "C-S-<tab>" #'+workspace/switch-left
        "M-t" #'my/toggle-vterm-workspace-buffer))

;; disable autosave modes
(setq +format-on-save-disabled-modes
      '(emacs-lisp-mode  ; elisp's mechanisms are good enough
        sql-mode         ; sqlformat is currently broken
        tex-mode         ; latexindent is broken
        latex-mode
        nix-mode))

;; safe-local-variables
(defun add-safe-variables ()
  (push '(cider-shadow-cljs-command . "lein with-profile cljs,cljs-dev,user run -m shadow.cljs.devtools.cli -- ") safe-local-variable-values)
  (push '(cider-shadow-cljs-command . "lein with-profile cljs,cljs-dev run -m shadow.cljs.devtools.cli -- ") safe-local-variable-values))

(add-hook 'after-init-hook 'add-safe-variables)

;; plantuml
(setq plantuml-jar-path (expand-file-name "~/.emacs.d/.local/etc/plantuml.jar")
      plantuml-default-exec-mode 'jar
      image-use-external-converter 't)

;; ;; accept completion from copilot and fallback to company
(use-package! copilot
  :hook (prog-mode . copilot-mode)
  :bind (:map copilot-completion-map
              ("<tab>" . 'copilot-accept-completion)
              ("TAB" . 'copilot-accept-completion)
              ("C-TAB" . 'copilot-accept-completion-by-word)
              ("C-<tab>" . 'copilot-accept-completion-by-word))
  :config
  (add-to-list 'copilot-indentation-alist '(prog-mode 2))
  (add-to-list 'copilot-indentation-alist '(org-mode 2))
  (add-to-list 'copilot-indentation-alist '(text-mode 2))
  (add-to-list 'copilot-indentation-alist '(closure-mode 2))
  (add-to-list 'copilot-indentation-alist '(emacs-lisp-mode 2)))

;; Bindings: use :leader "oc" and M-c to toggle ECA chat fullscreen
(defun eca-toggle-buffer-fullscreen ()
  "Toggle ECA chat fullscreen, starting ECA when no chat exists."
  (interactive)
  ;; e.g. <eca-chat[*project-name*]:1:0>, so we need to match the buffer name with a regex, not exact match.
  (let ((eca-buffer (seq-find (lambda (buf)
                                (string-match-p "^<eca-chat\\[.*\\]:[0-9]+:[0-9]+>$" (buffer-name buf)))
                              (buffer-list))))
    (cond
     ((and eca-buffer (get-buffer-window eca-buffer))
      (previous-buffer))
     (eca-buffer
      (switch-to-buffer eca-buffer)
      (delete-other-windows))
     (t
      ;; ECA defaults to a dedicated side window; nil makes it use this window.
      (setq eca-chat-window-side nil)
      (delete-other-windows)
      (eca)))))

(map! :leader "oc" #'eca-toggle-buffer-fullscreen)
(global-set-key (kbd "M-c") #'eca-toggle-buffer-fullscreen)

;; Direct Meta bindings for frequently used ECA chat actions.
(map! :map eca-chat-mode-map
      :nv "M-d" #'eca-mcp-details
      :nv "M-q" #'eca-transient-menu
      :nv "M-n" #'eca-chat-new
      :nv "M-g" #'eca-chat-select
      :nv "M-r" #'eca-chat-rename
      :nv "M-h" #'eca-chat-timeline
      :nv "M-m" #'eca-chat-select-model
      :nv "M-j" #'eca-chat-cycle-agent
      :nv "M-i" #'eca-chat-select-agent
      :nv "M-v" #'eca-chat-select-variant
      :nv "M-s" #'eca-chat-stop-prompt
      :nv "M-o" #'eca-chat-load-older-history
      :nv "M-w" #'eca-chat-copy-at-point
      :nv "M-u" #'eca-chat-clear-prompt
      :nv "M-p" #'eca-chat-repeat-prompt
      :nv "M-<up>" #'eca-chat-go-to-prev-expandable-block
      :nv "M-<down>" #'eca-chat-go-to-next-expandable-block
      :nv "M-RET" #'eca-chat-send-prompt-at-chat
      :i "M-RET" #'eca-chat-send-prompt-at-chat)

;; close eca-mcp-details buffer with M-d in eca-settings-mode
(map! :map eca-settings-mode-map
      :nv "M-d" #'+workspace/close-window-or-workspace)

(defun quick-switch-to-magit-status ()
  "Switch to the magit-status buffer if it exists, otherwise open it.
  e.g. '*magit: <project-name>*' buffer."
  (interactive)
  (let ((magit-buffer (seq-find (lambda (buf)
                                   (string-match-p "^\\*magit: .*\\*$" (buffer-name buf)))
                                 (buffer-list))))
    (if magit-buffer
        (switch-to-buffer magit-buffer)
      (magit-status))))

(map! :nv "M-g" #'quick-switch-to-magit-status)

(map! :map magit-mode-map
      :nv "M-g" #'previous-buffer)

(map! :leader "te" #'exec-path-from-shell-initialize)

(add-to-list 'load-path (expand-file-name "libraries/opencode-remote" doom-user-dir))
(require 'opencode-remote)
(map! :leader
      :desc "OpenCode chat" "o c" #'opencode-remote-chat
      :desc "New OpenCode chat" "o n" #'opencode-remote-new-chat)
(map! :map opencode-remote-transcript-mode-map
      :n "q" #'opencode-remote-close
      :n "C-c C-k" #'opencode-remote-abort
      :n "C-c C-o" #'opencode-remote-focus-composer
      :n "C-c C-a" #'opencode-remote-reply-permission
      :n "C-c C-q" #'opencode-remote-reply-question)
(map! :map opencode-remote-composer-mode-map
      :i "C-c C-c" #'opencode-remote-send
      :i "C-c C-k" #'opencode-remote-abort
      :i "C-c C-o" #'opencode-remote-focus-transcript
      :i "C-c C-a" #'opencode-remote-reply-permission
      :i "C-c C-q" #'opencode-remote-reply-question
      :i "M-p" #'opencode-remote-previous-prompt
      :i "M-n" #'opencode-remote-next-prompt)

;; Local-only credentials live in secrets.el (copy secrets.el.example to create it).
(load (expand-file-name "secrets.el" doom-user-dir) t t)
;; Machine-local private settings (project paths, employer-specific config, etc.).
(load (expand-file-name "local.el" doom-user-dir) t t)
(opencode-remote-notifications-start)

(setq nrepl-use-ssh-fallback-for-remote-hosts t)
