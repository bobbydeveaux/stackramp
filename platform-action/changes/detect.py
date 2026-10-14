#!/usr/bin/env python3
"""Decide which StackRamp deployables a push/PR needs to deploy.

Input comes from the environment (set by action.yml):
  CONFIG_JSON       stackramp.yaml converted to JSON (yq -o=json)
  CONFIG_PATH       path of stackramp.yaml in the repo
  CALLER_WORKFLOW   path of the app's workflow that called platform.yml
  CHANGED_FILES     JSON array of changed paths (dorny/paths-filter list-files)
  FORCE_REASON      non-empty => deploy everything (dispatch, schedule, no diff)
  HAS_FRONTEND / HAS_BACKEND / HAS_MCP / HAS_KUBERNETES   "true"/"false"
  FRONTEND_DIR / BACKEND_DIR / MCP_DIR / KUBERNETES_CHART
  KUBERNETES_IMAGES JSON array [{name, dockerfile, context}]
  MACHINE_BACKENDS  JSON array of machine/public backends (platform-action output)
  APP_NAME          app name (image repository prefix)

Writes key=value lines to $GITHUB_OUTPUT and a table to $GITHUB_STEP_SUMMARY.

Rules (any doubt => deploy more, never less):
  * FORCE_REASON set                         -> everything
  * stackramp.yaml or the caller workflow changed, or a deploy.full_deploy_paths
    glob matched                             -> everything
  * otherwise a service deploys when a changed file matches its dir/** or one of
    its watch_paths, and the file is not matched by the ignore list
    (built-in defaults + deploy.ignore_paths).
Services sharing a dir (e.g. the API and a worker built from the same source)
both deploy when that dir changes.
"""
import json
import os
import re
import sys

# Paths that never change a deployed artifact. They only matter for files
# inside a service dir (or when a service dir is the repo root): anything
# outside every service dir deploys nothing anyway.
DEFAULT_IGNORE = [
    "*.md",               # root README, CHANGELOG, AGENTS ...
    "**/README.md",
    "**/CHANGELOG.md",
    "LICENSE",
    "docs/**",
    "marketing/**",
    "brand/**",
    ".github/**",         # other CI workflows (the caller workflow is checked first)
    ".claude/**",
    ".vscode/**",
    ".idea/**",
]


def glob_to_regex(pattern: str) -> "re.Pattern[str]":
    """Glob -> regex with gitignore/picomatch-like semantics (dotfiles match).

    `*` stays within one path segment, `**` spans segments, `?` is one char,
    `{a,b}` alternates. `dir/**` also matches `dir` itself.
    """
    p = pattern.strip()
    if p.startswith("./"):
        p = p[2:]
    i, out = 0, []
    while i < len(p):
        c = p[i]
        if p.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif p.startswith("/**", i) and i + 3 == len(p):
            out.append("(?:/.*)?")
            i += 3
        elif p.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "{":
            j = p.find("}", i)
            if j == -1:
                out.append(re.escape(c))
                i += 1
            else:
                alts = p[i + 1:j].split(",")
                out.append("(?:" + "|".join(re.escape(a) for a in alts) + ")")
                i = j + 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


class Globs:
    def __init__(self, patterns):
        self.patterns = [p for p in (patterns or []) if isinstance(p, str) and p.strip()]
        self.res = [glob_to_regex(p) for p in self.patterns]

    def match(self, path: str) -> bool:
        return any(r.match(path) for r in self.res)


def dir_glob(d: str) -> str:
    d = (d or "").strip()
    if d.startswith("./"):
        d = d[2:]
    d = d.rstrip("/")
    if d in ("", "."):
        return "**"
    return d + "/**"


def as_list(v):
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    return [x for x in v if isinstance(x, str)]


def env_json(name, default):
    raw = os.environ.get(name, "")
    if not raw.strip():
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return default


def main() -> int:
    cfg = env_json("CONFIG_JSON", {}) or {}
    deploy_cfg = cfg.get("deploy") or {}
    config_path = os.environ.get("CONFIG_PATH", "stackramp.yaml")
    caller = os.environ.get("CALLER_WORKFLOW", "")
    force_reason = os.environ.get("FORCE_REASON", "").strip()
    changed = env_json("CHANGED_FILES", None)
    app = os.environ.get("APP_NAME", cfg.get("name", "app"))

    def flag(name):
        return os.environ.get(name, "false") == "true"

    machine = env_json("MACHINE_BACKENDS", []) or []
    k8s_images = env_json("KUBERNETES_IMAGES", []) or []

    ignore = list(DEFAULT_IGNORE) if deploy_cfg.get("default_ignore_paths", True) is not False else []
    ignore += as_list(deploy_cfg.get("ignore_paths"))
    ignore_g = Globs(ignore)
    full_g = Globs([config_path, caller] + as_list(deploy_cfg.get("full_deploy_paths")))

    # ── per-service watch sets ───────────────────────────────────────────────
    services = []  # (key, label, Globs)
    if flag("HAS_FRONTEND"):
        services.append(("frontend", "frontend", Globs(
            [dir_glob(os.environ.get("FRONTEND_DIR", "frontend"))]
            + as_list((cfg.get("frontend") or {}).get("watch_paths")))))
    if flag("HAS_BACKEND"):
        services.append(("backend", "backend (API)", Globs(
            [dir_glob(os.environ.get("BACKEND_DIR", "backend"))]
            + as_list((cfg.get("backend") or {}).get("watch_paths")))))
    if flag("HAS_MCP"):
        services.append(("mcp", "mcp", Globs(
            [dir_glob(os.environ.get("MCP_DIR", "mcp"))]
            + as_list((cfg.get("mcp") or {}).get("watch_paths")))))
    if flag("HAS_KUBERNETES"):
        pats = [dir_glob(os.environ.get("KUBERNETES_CHART", "deploy/helm"))]
        for img in k8s_images:
            pats.append(dir_glob(img.get("context") or "."))
            if img.get("dockerfile"):
                pats.append(img["dockerfile"])
        pats += as_list((cfg.get("kubernetes") or {}).get("watch_paths"))
        services.append(("kubernetes", "kubernetes", Globs(pats)))
    raw_backends = {b.get("name"): b for b in (cfg.get("backends") or []) if isinstance(b, dict)}
    for m in machine:
        name = m.get("name", "")
        extra = as_list((raw_backends.get(name) or {}).get("watch_paths"))
        services.append(("machine:" + name, "backend " + name, Globs([dir_glob(m.get("dir"))] + extra)))

    # ── decide ───────────────────────────────────────────────────────────────
    reason = ""
    hits = {key: [] for key, _, _ in services}
    config_g = Globs([config_path])
    config_changed = bool(changed) and any(config_g.match(f) for f in changed)
    if force_reason:
        reason = force_reason
    elif changed is None:
        reason = "no change list available"
    else:
        full_hits = [f for f in changed if full_g.match(f)]
        if full_hits:
            reason = "changed: " + ", ".join(full_hits[:5])
        else:
            for f in changed:
                if ignore_g.match(f):
                    continue
                for key, _, g in services:
                    if g.match(f):
                        hits[key].append(f)

    full = bool(reason)
    deploy = {key: (full or bool(hits[key])) for key, _, _ in services}

    machine_deploy = [m for m in machine if deploy.get("machine:" + m.get("name", ""), False)]

    # Images to pre-build (in parallel with the scans), grouped so services
    # built from the same dir + language share ONE build pushed under each
    # service's image name. _backend.yml / _mcp.yml skip their own build when
    # the image for this commit already exists.
    groups = {}

    def add_build(d, lang, image):
        d = (d or "").strip().rstrip("/") or "."
        k = (d, lang)
        groups.setdefault(k, {"dir": d, "language": lang, "images": []})
        if image not in groups[k]["images"]:
            groups[k]["images"].append(image)

    if deploy.get("backend"):
        add_build(os.environ.get("BACKEND_DIR", "backend"), os.environ.get("BACKEND_LANGUAGE", ""), app)
    if deploy.get("mcp"):
        add_build(os.environ.get("MCP_DIR", "mcp"), os.environ.get("MCP_LANGUAGE", "go"), f"{app}-mcp")
    for m in machine_deploy:
        add_build(m.get("dir"), m.get("language", ""), f"{app}-{m.get('name')}")
    build_groups = []
    for g in groups.values():
        g["images"] = " ".join(g["images"])
        build_groups.append(g)

    out = {
        "deploy_frontend": str(deploy.get("frontend", False)).lower(),
        "deploy_backend": str(deploy.get("backend", False)).lower(),
        "deploy_mcp": str(deploy.get("mcp", False)).lower(),
        "deploy_kubernetes": str(deploy.get("kubernetes", False)).lower(),
        "machine_deploy": json.dumps(machine_deploy, separators=(",", ":")),
        "build_groups": json.dumps(build_groups, separators=(",", ":")),
        "any_deploy": str(any(deploy.values())).lower(),
        "full_deploy": str(full).lower(),
        "deploy_reason": reason or "per-service path match",
        "config_changed": str(config_changed).lower(),
    }

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            for k, v in out.items():
                fh.write(f"{k}={v}\n")
    else:
        json.dump(out, sys.stdout, indent=1)
        print()

    # Human-readable plan.
    lines = ["### StackRamp deploy plan", ""]
    lines.append(f"**Mode:** {'deploy everything — ' + reason if full else 'per-service (changed paths)'}")
    if changed is not None:
        lines.append(f"**Changed files:** {len(changed)}")
    lines.append(f"**Caller workflow:** `{caller or '(unknown)'}`")
    lines += ["", "| Service | Deploy | Matched files |", "|---|---|---|"]
    for key, label, _ in services:
        files = hits[key]
        shown = ", ".join(f"`{f}`" for f in files[:3]) + (f" +{len(files) - 3}" if len(files) > 3 else "")
        lines.append(f"| {label} | {'yes' if deploy[key] else 'skip'} | {shown or ('(forced)' if full else '')} |")
    if not services:
        lines.append("| (none) | | |")
    summary = "\n".join(lines) + "\n"
    print(summary)
    sm = os.environ.get("GITHUB_STEP_SUMMARY")
    if sm:
        with open(sm, "a") as fh:
            fh.write(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
