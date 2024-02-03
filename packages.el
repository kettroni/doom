;; -*- no-byte-compile: t; -*-
;;; $DOOMDIR/packages.el

(package! harpoon)
(package! copilot
  :recipe (:host github :repo "copilot-emacs/copilot.el" :files ("*.el")))

(package! plantuml-mode)
(package! gptel :recipe (:nonrecursive t))
(package! mcp
  :recipe (:host github :repo "lizqwerscott/mcp.el" :files ("*.el")))

(package! eca :recipe (:host github :repo "editor-code-assistant/eca-emacs" :files ("*.el")))

(package! exec-path-from-shell)

(package! pasteex-mode
  :recipe (:host github :repo "dnxbjyj/pasteex-mode" :files ("*.el")))

(package! opencode :recipe (:host github :repo "colobas/opencode.el" :files ("*.el")))
