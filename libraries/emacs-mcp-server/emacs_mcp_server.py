#!/usr/bin/env python3
"""Local stdio MCP server for inspecting and safely editing a Doom config.

This server never invokes Git and never connects to a running Emacs. Elisp
validation and evaluation run in fresh `emacs --batch -Q` subprocesses.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

SERVER_NAME = "doom-emacs-batch"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2025-11-25"
CONFIG_ROOT = Path(os.environ.get("DOOM_MCP_CONFIG_DIR", str(Path.home() / ".doom.d"))).expanduser().resolve()
EMACS = os.environ.get("DOOM_MCP_EMACS", "emacs")
MAX_FILE_BYTES = 1_000_000

TOOLS = [
    {
        "name": "doom_config_tree",
        "description": "List files under the configured Doom directory (read-only).",
        "inputSchema": {"type": "object", "properties": {"max_depth": {"type": "integer", "minimum": 1, "maximum": 8}}, "additionalProperties": False},
    },
    {
        "name": "doom_config_read",
        "description": "Read a UTF-8 text file under the configured Doom directory.",
        "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"], "additionalProperties": False},
    },
    {
        "name": "doom_config_search",
        "description": "Search text files under the configured Doom directory for a literal string.",
        "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "minLength": 1}, "max_results": {"type": "integer", "minimum": 1, "maximum": 500}}, "required": ["query"], "additionalProperties": False},
    },
    {
        "name": "elisp_validate",
        "description": "Validate Emacs Lisp syntax with a fresh `emacs --batch -Q` process; does not evaluate forms.",
        "inputSchema": {"type": "object", "properties": {"code": {"type": "string"}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 60}}, "required": ["code"], "additionalProperties": False},
    },
    {
        "name": "elisp_eval_batch",
        "description": "Evaluate arbitrary Emacs Lisp in a fresh, isolated `emacs --batch -Q` subprocess (not the running Emacs). Elisp runs with your OS-user permissions; use only trusted code. Does not load your Doom config unless the code explicitly does so.",
        "inputSchema": {"type": "object", "properties": {"code": {"type": "string"}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 60}}, "required": ["code"], "additionalProperties": False},
    },
    {
        "name": "doom_config_replace",
        "description": "Replace one exact text occurrence in a Doom config file. The new file is syntax-checked with batch Emacs before atomic write. No Git actions are performed.",
        "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "old_text": {"type": "string", "minLength": 1}, "new_text": {"type": "string"}}, "required": ["path", "old_text", "new_text"], "additionalProperties": False},
    },
    {
        "name": "doom_config_summary",
        "description": "Summarize configured Doom modules, declared packages, custom Lisp definitions, and locally loaded files with source locations.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "elisp_find_symbol",
        "description": "Find definitions and/or references for a Lisp symbol in Elisp files under the Doom config directory.",
        "inputSchema": {"type": "object", "properties": {"symbol": {"type": "string", "minLength": 1}, "mode": {"type": "string", "enum": ["definitions", "references", "both"]}, "max_results": {"type": "integer", "minimum": 1, "maximum": 500}}, "required": ["symbol"], "additionalProperties": False},
    },
    {
        "name": "elisp_edit_form",
        "description": "Replace one uniquely named top-level Lisp form in a config file. The target and replacement are parsed (not evaluated), and the entire resulting file is syntax-checked before writing.",
        "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "form_name": {"type": "string", "minLength": 1}, "new_form": {"type": "string"}}, "required": ["path", "form_name", "new_form"], "additionalProperties": False},
    },
    {
        "name": "doom_config_check",
        "description": "Syntax-check one Elisp file or every Elisp file under the Doom config directory; reports duplicate top-level definitions as a heuristic warning.",
        "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}, "additionalProperties": False},
    },
    {
        "name": "elisp_run_ert",
        "description": "Run explicitly selected ERT test files in a fresh `emacs --batch -Q` process. Test files execute with your OS-user permissions; only run trusted tests. Doom init is not loaded automatically.",
        "inputSchema": {"type": "object", "properties": {"test_files": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 30}, "selector": {"type": "string", "description": "Optional ERT test selector, e.g. t or a test name."}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 300}}, "required": ["test_files"], "additionalProperties": False},
    },
]


def _config_path(relative: str) -> Path:
    candidate = (CONFIG_ROOT / relative).resolve()
    if candidate != CONFIG_ROOT and CONFIG_ROOT not in candidate.parents:
        raise ValueError("Path must remain inside the configured Doom directory")
    if not candidate.is_file():
        raise ValueError(f"Not a regular file in the config directory: {relative}")
    if candidate.stat().st_size > MAX_FILE_BYTES:
        raise ValueError("File exceeds the 1 MB safety limit")
    return candidate


def _run_emacs(code: str, *, evaluate: bool, timeout: int = 10) -> dict[str, Any]:
    timeout = max(1, min(int(timeout), 60))
    # Pass user code in a temporary file, not a shell string. -Q prevents user
    # init files from being loaded; batch mode is a separate Emacs process.
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".el", delete=False) as handle:
        source = Path(handle.name)
        handle.write(code)
        handle.write("\n")
    try:
        if evaluate:
            source_literal = json.dumps(str(source))
            evaluator = (
                f"(with-temp-buffer (insert-file-contents {source_literal}) "
                "(goto-char (point-min)) (let (values) "
                "(while (progn (skip-chars-forward \" \\t\\n\\r\") "
                "(while (eq (char-after) ?;) (forward-line 1) (skip-chars-forward \" \\t\\n\\r\")) "
                "(< (point) (point-max))) "
                "(push (eval (read (current-buffer)) t) values)) "
                "(prin1 (nreverse values))))"
            )
            command = [EMACS, "--batch", "-Q", "--no-site-file", "--eval", evaluator]
        else:
            # Read and parse forms without loading or evaluating the submitted file.
            source_literal = json.dumps(str(source))
            validator = (
                f"(with-temp-buffer (insert-file-contents {source_literal}) "
                "(check-parens) (goto-char (point-min)) "
                "(while (progn (skip-chars-forward \" \\t\\n\\r\") "
                "(while (eq (char-after) ?;) (forward-line 1) (skip-chars-forward \" \\t\\n\\r\")) "
                "(< (point) (point-max))) "
                "(read (current-buffer))))"
            )
            command = [EMACS, "--batch", "-Q", "--no-site-file", "--eval", validator]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
        return {"ok": completed.returncode == 0, "exit_code": completed.returncode, "stdout": completed.stdout[-12000:], "stderr": completed.stderr[-12000:]}
    except FileNotFoundError:
        return {"ok": False, "error": f"Emacs executable not found: {EMACS}"}
    except subprocess.TimeoutExpired as exc:
        return {"ok": False, "error": f"Batch Emacs timed out after {timeout}s", "stdout": (exc.stdout or "")[-12000:] if isinstance(exc.stdout, str) else ""}
    finally:
        source.unlink(missing_ok=True)


def _elisp_files() -> list[Path]:
    return [p for p in sorted(CONFIG_ROOT.rglob("*.el")) if p.is_file() and not any(part.startswith(".") for part in p.relative_to(CONFIG_ROOT).parts) and p.stat().st_size <= MAX_FILE_BYTES]


def _doom_summary() -> dict[str, Any]:
    summary: dict[str, Any] = {"root": str(CONFIG_ROOT), "modules": [], "packages": [], "definitions": [], "local_loads": [], "key_customization_lines": []}
    init = CONFIG_ROOT / "init.el"
    if init.is_file():
        inside_doom = False
        depth = 0
        for number, line in enumerate(init.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if not inside_doom and "(doom!" in stripped and not stripped.startswith(";"):
                inside_doom = True
                depth = 1
            elif inside_doom:
                if stripped.startswith(";"):
                    continue
                # The init module list is conventionally one module per line.
                match = re.match(r"^\s*(\(?[A-Za-z][\w-]*)(?:\s+([^;]*?))?\s*(?:;.*)?$", line)
                if match and match.group(1) not in {"doom!", "IS-MAC"}:
                    item = {"module": match.group(1).lstrip("("), "line": number}
                    if match.group(2):
                        item["flags_or_form"] = match.group(2).strip().rstrip(")")
                    summary["modules"].append(item)
                depth += line.count("(") - line.count(")")
                if depth <= 0:
                    inside_doom = False
    for path in _elisp_files():
        relative = str(path.relative_to(CONFIG_ROOT))
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeError:
            continue
        for number, line in enumerate(lines, 1):
            if line.lstrip().startswith(";"):
                continue
            loc = {"path": relative, "line": number}
            package = re.search(r"\(package!\s+([^\s()]+)", line)
            if package:
                summary["packages"].append({"name": package.group(1), **loc})
            definition = re.search(r"\((?:defun|defmacro|defvar|defconst|defcustom|defalias)\s+([A-Za-z0-9_+*/:<>=!?$%&~^-]+)", line)
            if definition:
                summary["definitions"].append({"name": definition.group(1), **loc})
            loaded = re.search(r"\(load!\s+['\"]?([^\s()'\"]+)", line)
            if loaded:
                summary["local_loads"].append({"file": loaded.group(1), **loc})
            if re.search(r"\((?:map!|map\s+|global-set-key|define-key)\b", line):
                summary["key_customization_lines"].append({"text": line.strip()[:240], **loc})
    return summary


def _find_symbol(symbol: str, mode: str, limit: int) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9_+*/:<>=!?$%&~^-]+", symbol):
        raise ValueError("symbol must be a single Emacs Lisp symbol name")
    definitions, references = [], []
    def_pattern = re.compile(r"\((?:defun|defmacro|defvar|defconst|defcustom|defalias|define-minor-mode|define-derived-mode)\s+" + re.escape(symbol) + r"(?=[\s)])")
    ref_pattern = re.compile(r"(?<![A-Za-z0-9_+*/:<>=!?$%&~^-])" + re.escape(symbol) + r"(?![A-Za-z0-9_+*/:<>=!?$%&~^-])")
    for path in _elisp_files():
        relative = str(path.relative_to(CONFIG_ROOT))
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeError:
            continue
        for number, line in enumerate(lines, 1):
            if line.lstrip().startswith(";"):
                continue
            location = {"path": relative, "line": number, "text": line.strip()[:500]}
            if mode in ("definitions", "both") and def_pattern.search(line):
                definitions.append(location)
            if mode in ("references", "both") and ref_pattern.search(line):
                references.append(location)
    return {"symbol": symbol, "definitions": definitions[:limit], "references": references[:limit], "truncated": len(definitions) > limit or len(references) > limit, "note": "Textual Elisp scan; quoted data and comments inside forms may appear as references."}


def _inspect_forms(text: str) -> list[dict[str, Any]]:
    valid = _run_emacs(text, evaluate=False)
    if not valid["ok"]:
        raise ValueError("Elisp syntax invalid: " + json.dumps(valid, ensure_ascii=False))
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".el", delete=False) as handle:
        source = Path(handle.name)
        handle.write(text)
    source_literal = json.dumps(str(source))
    parser = (
        f"(with-temp-buffer (insert-file-contents {source_literal}) (goto-char (point-min)) "
        "(while (< (point) (point-max)) "
        "(skip-chars-forward \" \\t\\n\\r\") "
        "(while (eq (char-after) ?;) (forward-line 1) (skip-chars-forward \" \\t\\n\\r\")) "
        "(when (< (point) (point-max)) "
        "(let* ((start (point)) (form (read (current-buffer))) (end (point)) "
        "(head (if (consp form) (format \"%s\" (car form)) \"\")) "
        "(name (if (and (consp form) (consp (cdr form))) "
        "(let ((value (cadr form))) (if (symbolp value) (symbol-name value) (format \"%s\" value))) \"\"))) "
        "(princ (format \"%d\\t%d\\t%s\\t%s\\n\" start end head name))))))"
    )
    try:
        result = subprocess.run([EMACS, "--batch", "-Q", "--no-site-file", "--eval", parser], capture_output=True, text=True, timeout=15, check=False)
        if result.returncode:
            raise ValueError("Could not parse forms: " + result.stderr[-2000:])
        rows = []
        for row in result.stdout.splitlines():
            columns = row.split("\t", 3)
            if len(columns) == 4:
                start, end, head, form_name = columns
                rows.append({"start": int(start), "end": int(end), "head": head, "name": form_name})
        return rows
    except FileNotFoundError as exc:
        raise ValueError(f"Emacs executable not found: {EMACS}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ValueError("Batch Emacs timed out while parsing forms") from exc
    finally:
        source.unlink(missing_ok=True)


def _run_ert(test_files: list[str], selector: str | None, timeout: int) -> dict[str, Any]:
    if not test_files or len(test_files) > 30:
        raise ValueError("Provide between 1 and 30 test files")
    paths = [_config_path(relative) for relative in test_files]
    if any(path.suffix != ".el" for path in paths):
        raise ValueError("ERT test files must have a .el suffix")
    timeout = max(1, min(int(timeout), 300))
    command = [EMACS, "--batch", "-Q", "--no-site-file", "-L", str(CONFIG_ROOT)]
    for path in paths:
        command.extend(["--load", str(path)])
    selector_form = "t" if selector is None else json.dumps(selector)
    command.extend(["--eval", f"(ert-run-tests-batch-and-exit {selector_form})"])
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
        output = (result.stdout + result.stderr)[-16000:]
        return {"ok": result.returncode == 0, "exit_code": result.returncode, "test_files": [str(path.relative_to(CONFIG_ROOT)) for path in paths], "output": output}
    except FileNotFoundError as exc:
        raise ValueError(f"Emacs executable not found: {EMACS}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ValueError(f"ERT run timed out after {timeout}s") from exc


def _atomic_write(path: Path, content: str) -> None:
    mode = path.stat().st_mode
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def _tool(name: str, args: dict[str, Any]) -> Any:
    if name == "elisp_run_ert":
        return _run_ert(args["test_files"], args.get("selector"), args.get("timeout_seconds", 60))
    if name == "doom_config_summary":
        return _doom_summary()
    if name == "elisp_find_symbol":
        return _find_symbol(str(args["symbol"]), str(args.get("mode", "both")), max(1, min(int(args.get("max_results", 100)), 500)))
    if name == "elisp_edit_form":
        path = _config_path(str(args["path"]))
        if path.suffix != ".el":
            raise ValueError("elisp_edit_form only edits .el files")
        content = path.read_text(encoding="utf-8")
        target = str(args["form_name"])
        forms = _inspect_forms(content)
        matches = [form for form in forms if form["name"] == target]
        if len(matches) != 1:
            raise ValueError(f"Expected one top-level form named {target!r}; found {len(matches)}. No change made.")
        replacements = _inspect_forms(str(args["new_form"]))
        if len(replacements) != 1 or replacements[0]["name"] != target:
            raise ValueError("new_form must contain exactly one top-level form with the same name as form_name")
        form = matches[0]
        updated = content[:form["start"] - 1] + str(args["new_form"]) + content[form["end"] - 1:]
        checked = _run_emacs(updated, evaluate=False)
        if not checked["ok"]:
            raise ValueError("Edit rejected: " + json.dumps(checked, ensure_ascii=False))
        _atomic_write(path, updated)
        return {"ok": True, "path": str(path.relative_to(CONFIG_ROOT)), "form_name": target, "start_line": content.count("\n", 0, form["start"] - 1) + 1, "syntax_checked": True}
    if name == "doom_config_check":
        if args.get("path"):
            candidates = [_config_path(str(args["path"]))]
            if candidates[0].suffix != ".el":
                raise ValueError("doom_config_check only checks .el files")
        else:
            candidates = _elisp_files()
        files, warnings = [], []
        for path in candidates:
            text = path.read_text(encoding="utf-8")
            result = _run_emacs(text, evaluate=False)
            relative = str(path.relative_to(CONFIG_ROOT))
            files.append({"path": relative, "ok": result["ok"], **({"error": result.get("stderr", result.get("error", ""))[-3000:]} if not result["ok"] else {})})
            if result["ok"]:
                names = re.findall(r"^\s*\((?:defun|defmacro|defvar|defconst|defcustom)\s+([A-Za-z0-9_+*/:<>=!?$%&~^-]+)", text, re.MULTILINE)
                counts: dict[str, int] = {}
                for symbol in names:
                    counts[symbol] = counts.get(symbol, 0) + 1
                warnings.extend({"path": relative, "symbol": symbol, "count": count, "kind": "duplicate-top-level-definition", "heuristic": True} for symbol, count in counts.items() if count > 1)
        return {"ok": all(file["ok"] for file in files), "files_checked": len(files), "files": files, "warnings": warnings, "warning_note": "Duplicate definitions are a textual heuristic; no Doom runtime or package resolution is performed."}
    if name == "doom_config_tree":
        depth = max(1, min(int(args.get("max_depth", 3)), 8))
        rows = []
        for path in sorted(CONFIG_ROOT.rglob("*")):
            if any(part.startswith(".") for part in path.relative_to(CONFIG_ROOT).parts):
                continue
            rel = path.relative_to(CONFIG_ROOT)
            if len(rel.parts) <= depth and path.is_file():
                rows.append(str(rel))
        return {"root": str(CONFIG_ROOT), "files": rows[:1000]}
    if name == "doom_config_read":
        path = _config_path(str(args["path"]))
        return {"path": str(path.relative_to(CONFIG_ROOT)), "content": path.read_text(encoding="utf-8")}
    if name == "doom_config_search":
        query = str(args["query"])
        limit = max(1, min(int(args.get("max_results", 100)), 500))
        matches = []
        for path in sorted(CONFIG_ROOT.rglob("*")):
            if not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
                continue
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except (UnicodeError, OSError):
                continue
            for number, line in enumerate(lines, 1):
                if query in line:
                    matches.append({"path": str(path.relative_to(CONFIG_ROOT)), "line": number, "text": line[:1000]})
                    if len(matches) >= limit:
                        return {"matches": matches, "truncated": True}
        return {"matches": matches, "truncated": False}
    if name == "elisp_validate":
        return _run_emacs(str(args["code"]), evaluate=False, timeout=args.get("timeout_seconds", 10))
    if name == "elisp_eval_batch":
        return _run_emacs(str(args["code"]), evaluate=True, timeout=args.get("timeout_seconds", 10))
    if name == "doom_config_replace":
        path = _config_path(str(args["path"]))
        old, new = str(args["old_text"]), str(args["new_text"])
        content = path.read_text(encoding="utf-8")
        occurrences = content.count(old)
        if occurrences != 1:
            raise ValueError(f"Expected exactly one occurrence of old_text; found {occurrences}. No change made.")
        updated = content.replace(old, new, 1)
        if path.suffix == ".el":
            result = _run_emacs(updated, evaluate=False)
            if not result["ok"]:
                raise ValueError("Edit rejected: batch Emacs syntax validation failed: " + json.dumps(result, ensure_ascii=False))
        mode = path.stat().st_mode
        fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                output.write(updated)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temp_name, mode)
            os.replace(temp_name, path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)
        return {"ok": True, "path": str(path.relative_to(CONFIG_ROOT)), "replacements": 1, "syntax_checked": path.suffix == ".el"}
    raise ValueError(f"Unknown tool: {name}")


def _response(request_id: Any, result: Any = None, error: dict[str, Any] | None = None) -> dict[str, Any]:
    message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    return message


def _handle(message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    if method == "notifications/initialized" or method == "notifications/cancelled":
        return None
    if method == "initialize":
        return _response(request_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": (
                "For Doom configuration or code changes intended to alter behavior, "
                "run a relevant behavioral test before reporting the change as done. "
                "Syntax checks and doom sync alone do not verify behavior. Prefer a "
                "batch Emacs/ERT check that exercises the changed behavior or keymap; "
                "when full runtime integration cannot be tested, test the reachable "
                "behavior with suitable stubs and clearly state what remains unverified. "
                "Never claim a behavior is fixed unless the test verifies it."
            ),
        })
    if method == "ping":
        return _response(request_id, {})
    if method == "tools/list":
        return _response(request_id, {"tools": TOOLS})
    if method == "tools/call":
        try:
            result = _tool(str(params.get("name", "")), params.get("arguments") or {})
            return _response(request_id, {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=2)}], "isError": False})
        except Exception as exc:  # tool errors are returned as MCP tool results
            return _response(request_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
    if request_id is None:
        return None
    return _response(request_id, error={"code": -32601, "message": f"Method not found: {method}"})


def main() -> None:
    # MCP stdio requires one JSON-RPC message per line; stdout is protocol-only.
    for line in sys.stdin:
        try:
            request = json.loads(line)
            response = _handle(request)
        except Exception as exc:
            response = _response(None, error={"code": -32700, "message": str(exc)})
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
