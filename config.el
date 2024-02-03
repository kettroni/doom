;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Display stuff
(toggle-frame-fullscreen)
(setq doom-font (font-spec :family "Fira Code" :size 21 :weight 'semi-light))
(setq doom-theme 'doom-gruvbox)
(setq display-line-numbers-type 'relative)
(setq doom-modeline-height 1)
(custom-set-faces
 '(mode-line ((t (:family "Fira Code" :height 0.80))))
 '(mode-line-inactive ((t (:family "Fira Code" :height 0.80)))))

;; Paths
(setq org-directory "~/org/")

;; This sets projectile path
(setq projectile-project-search-path '("~/code"))
(setq projectile-auto-discover t)

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

;; Harpoon
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
(map! :nvig "C-<iso-lefttab>" #'+workspace/switch-left)

;; compile
(map! :nvg "C-M-c" #'+ivy/project-compile)
(defun compile-maximize ()
  "Execute a compile command from the current project's root and maximizes window."
  (interactive)
  (recompile)
  (doom/window-maximize-buffer))
(map! :nvg "M-C" #'compile-maximize)

;; doom scratch buffer
(defun open-doom-scratch-buffer-maximized ()
  "Open or close the *doom:scratch* buffer and maximize it."
  (interactive)
  (if (get-buffer-window "*doom:scratch*")
      (switch-to-buffer (other-buffer))
    (doom/open-scratch-buffer)
    (call-interactively #'+popup/raise)))
(map! :leader "x" #'open-doom-scratch-buffer-maximized)

;; magit
(after! magit
  (map! :map magit-mode-map
        :nv "C-<tab>" #'+workspace/switch-right
        :nv "C-k"     #'harpoon-go-to-1
        :nv "C-j"     #'harpoon-go-to-2
        :nv "C-q"     #'harpoon-go-to-3))

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
(map! :leader "e" #'eval-surrounding-or-next-closure)

(defun cider-repl-new-buffer ()
  "Wrapper for `cider-jack-in-clj' that avoids splitting the window."
  (interactive)
  (+eval/open-repl-same-window)
  (switch-to-buffer (other-buffer)))
(after! cider
  (map! :leader
        (:prefix ("o" . "open")
         :desc "Open repl in new buffer" "r" #'cider-repl-new-buffer)
        "l" #'cider-load-buffer
        "y" #'cider-kill-last-result))

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

(map! :map evil-normal-state-map
      ")" 'next-open-paren
      "(" 'previous-open-paren
      "[" 'evil-backward-section-begin
      "]" 'evil-forward-section-begin
      "C-a" 'magit-status)

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

(map! "M-)" #'wrap-closure-insert)
