# Doom Emacs batch MCP server

`emacs_mcp_server.py` provides a local stdio MCP server for an agent to inspect this Doom directory, validate/evaluate Emacs Lisp, and make exact-match edits to config files.

## Safety and behavior

- The MCP `initialize` response includes persistent agent guidance: behavior-changing Doom config/code edits must be behaviorally tested before they are reported as done. Syntax checks and `doom sync` alone are insufficient; use a relevant batch Emacs/ERT test, and explicitly identify any runtime paths that could not be tested.
- The server has **no Git tools** and never runs Git commands. It does not initialize or alter repositories.
- It does **not connect to your running Emacs**. `elisp_validate`, `elisp_eval_batch`, and the pre-write check for `.el` edits run fresh `emacs --batch -Q` subprocesses.
- `-Q` avoids loading your normal init files. The batch evaluator does not automatically load Doom config; tools can read the config files separately for context.
- Config read/search/edit access is confined to `DOOM_MCP_CONFIG_DIR` (defaults to `~/.doom.d`). Path traversal and symlinks escaping that directory are rejected for read/edit.
- `doom_config_replace` requires exactly one match and syntax-validates the proposed complete `.el` file before an atomic replacement. It does not perform formatting or semantic validation.
- `elisp_edit_form` locates one top-level form by its second element (for example, the name in a `defun`), requires a unique match, verifies the replacement has the same name, syntax-checks the complete result, and then atomically writes it. Parsing is read-only; the target form is never evaluated.
- `doom_config_summary` and `elisp_find_symbol` are static/textual aids with file/line provenance, not a full semantic index. `elisp_find_symbol` can report references in quoted data as well as executable code.
- `doom_config_check` syntax-checks one or all `.el` files and flags duplicate top-level definitions as a heuristic. It does not load Doom or resolve packages.
- `elisp_run_ert` runs only explicitly provided test files in a fresh batch Emacs. Those tests execute code with your OS-user permissions; run only trusted tests.
- **Arbitrary Elisp evaluation is not a security sandbox.** It executes with the MCP process's OS-user permissions and may access files, processes, and the network. Use only trusted code. The timeout bounds the subprocess duration, not the capabilities of code that already performed side effects.

## Run

Requires Python 3 and Emacs on `PATH`. Start the server with:

```sh
python3 "$HOME/.doom.d/libraries/emacs-mcp-server/emacs_mcp_server.py"
```

For an MCP client, register a stdio server with command `python3` and the script path as its sole argument. Example configuration shape (adapt the outer key to your client):

```json
{
  "mcpServers": {
    "doom-emacs-batch": {
      "command": "python3",
      "args": ["/absolute/path/to/.doom.d/libraries/emacs-mcp-server/emacs_mcp_server.py"],
      "env": {
        "DOOM_MCP_CONFIG_DIR": "/absolute/path/to/.doom.d",
        "DOOM_MCP_EMACS": "/opt/homebrew/bin/emacs"
      }
    }
  }
}
```

Environment variables are optional; the config directory defaults to `~/.doom.d`, and Emacs defaults to `emacs` on `PATH`.

## Tools

### Inspect and navigate

- `doom_config_tree`, `doom_config_read`, `doom_config_search`
- `doom_config_summary` — enabled module entries, declared packages, top-level definitions, local `load!` forms, and key-customization lines, with locations
- `elisp_find_symbol` — search definitions/references by symbol; choose `definitions`, `references`, or `both`

### Validate, edit, and test

- `elisp_validate` — parses and checks delimiters without evaluating submitted forms
- `doom_config_check` — syntax-check a file or all `.el` files and report heuristic duplicate top-level definitions
- `elisp_edit_form` — structurally replace a uniquely named top-level form, then validate before writing
- `doom_config_replace` — exact single-occurrence replacement with pre-write Lisp syntax validation
- `elisp_run_ert` — run explicitly selected test files; optional selector is an ERT name-matching regex
- `elisp_eval_batch` — evaluate forms in order and return their values in a fresh batch Emacs

`doom_config_summary` and `elisp_find_symbol` inspect source text; they do not claim full Lisp semantic analysis. The config inspection tools let an agent learn enabled modules/packages and local conventions before editing. The server does not infer undocumented behavior or inject your config into the batch evaluator.
