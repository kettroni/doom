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
(map! :map magit-mode-map :nv "C-<tab>" #'+workspace/switch-right)
