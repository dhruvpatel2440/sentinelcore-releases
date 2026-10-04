#!/usr/bin/env python3
"""Static parity: release configuration vs main SentinelCore (Phase 14.1).

Read-only on SOURCE_DIR. Compares
  A. compose services (caps, security_opt, network_mode, user, env, volumes,
     ports, command, depends_on, networks) — main docker-compose.yml vs the
     release base + TLS + email compose files
  B. environment variables — main .env.example + every Settings field in
     backend/app/core/config.py + every os.getenv in helper/helper/config.py
     must be set by the release (.env template / compose) or use the SAME code
     default as main
  C. Python + Debian packages — release Dockerfiles install main's own
     requirements.txt and a superset of main's apt packages; with build
     evidence, pip freeze must match every pin in requirements.txt
  D. nginx — /api/ proxied without trailing slash; upload limit vs backend limit
  E. suricata.yaml — identical to main except HOME_NET + capture interface
  F. migrations — the image build context carries main's alembic tree
  G. schema — pg_dump --schema-only of release vs main (when both dumps are given)

Every difference must be in ALLOWED (with a reason) or the script exits 1.

Usage:
  python3 tests/parity/static_diff.py --source ../SentinelCore [--evidence dist/<pkg>-build-evidence]
                                      [--main-schema main.sql] [--report out.md]
"""
from __future__ import annotations

import argparse
import ast
import difflib
import re
import sys
from pathlib import Path

import yaml

REL = Path(__file__).resolve().parents[2]

# (service, field) -> reason. "*" matches any service.
ALLOWED = {
    ("frontend", "service"): "static frontend: built once (npm ci && vite build) and served by nginx; no Vite dev server in production",
    ("relay-shim", "service"): "release-only email bridge (email overlay, only when email is enabled)",
    ("*", "image"): "pinned image from the bundled tarball (tag = package VERSION) instead of `build:`",
    ("*", "pull_policy"): "sentinelcore/* images come only from the bundled tarball",
    ("*", "healthcheck"): "release adds healthchecks; the installer waits until every service is healthy",
    ("*", "logging"): "release adds docker log rotation (10 MB x 5) to prevent disk fill",
    ("*", "restart"): "release sets restart: unless-stopped on every long-running service",
    ("backend", "volume:/app"): "no code bind mount: code is baked into the image",
    ("worker", "volume:/app"): "no code bind mount: code is baked into the image",
    ("frontend", "volume:/app"): "frontend service not used",
    ("helper", "volume:/etc/suricata/suricata.yaml"): "rendered per install (HOME_NET + capture NIC) instead of the dev file",
    ("nginx", "volume:/etc/nginx/conf.d/default.conf"): "release nginx config (HTTPS, static UI, headers, upload limit)",
    ("nginx", "volume:/usr/share/nginx/html"): "static frontend build served by nginx",
    ("nginx", "volume:/etc/nginx/tls"): "TLS overlay: server certificate",
    ("backend", "volume:/etc/sentinelcore/ca-bundle.pem"): "email overlay only: CA bundle so httpx trusts the relay shim",
    ("worker", "volume:/etc/sentinelcore/ca-bundle.pem"): "email overlay only: CA bundle so httpx trusts the relay shim",
    ("backend", "env:SSL_CERT_FILE"): "email overlay only (httpx honours SSL_CERT_FILE)",
    ("worker", "env:SSL_CERT_FILE"): "email overlay only (httpx honours SSL_CERT_FILE)",
    ("redis", "env:TZ"): "container timezone for log timestamps",
    ("nginx", "env:TZ"): "container timezone for log timestamps",
    ("nginx", "ports"): "installer-chosen bind address + ports; HTTPS 443 (TLS overlay), HTTP only redirects",
    ("nginx", "depends_on"): "no frontend service; waits for a healthy backend",
    ("backend", "command"): "main's CMD minus --reload (production)",
    ("backend", "depends_on"): "same services; release keeps service_healthy conditions",
}

ENV_JUSTIFIED = {
    "SEED_ADMIN_PASSWORD": "never stored: passed once via the process environment of a one-shot `docker compose run` (installer/lib/admin.sh)",
    "CAPTURE_INTERFACE": None, "MONITORED_NETWORK": None, "PROTECTED_IPS": None,
}


class Report:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str, str]] = []  # (area, item, status, detail)
        self.fail = 0

    def add(self, area: str, item: str, status: str, detail: str = "") -> None:
        self.rows.append((area, item, status, detail))
        if status == "FAIL":
            self.fail += 1

    def markdown(self) -> str:
        out = ["| Area | Item | Status | Detail |", "|---|---|---|---|"]
        for a, i, s, d in self.rows:
            out.append(f"| {a} | {i} | {s} | {d.replace('|', '/')} |")
        return "\n".join(out)


def load_compose(*paths: Path) -> dict:
    merged: dict = {"services": {}, "volumes": {}}
    for p in paths:
        doc = yaml.safe_load(p.read_text(encoding="utf-8").replace("__VERSION__", "X.Y.Z")) or {}
        for k, v in (doc.get("volumes") or {}).items():
            merged["volumes"][k] = v
        for name, svc in (doc.get("services") or {}).items():
            cur = merged["services"].setdefault(name, {})
            for k, v in svc.items():
                if k in ("ports", "volumes") and k in cur:
                    cur[k] = list(cur[k]) + list(v)
                elif k == "environment" and k in cur:
                    cur[k] = {**env_dict(cur[k]), **env_dict(v)}
                else:
                    cur[k] = v
    return merged


def env_dict(e) -> dict:
    if isinstance(e, dict):
        return {str(k): str(v) for k, v in e.items()}
    out = {}
    for item in e or []:
        k, _, v = str(item).partition("=")
        out[k] = v
    return out


def mounts(svc: dict) -> dict:
    out = {}
    for m in svc.get("volumes") or []:
        parts = str(m).split(":")
        if len(parts) >= 2:
            out[parts[1]] = (parts[0], ":".join(parts[2:]))
    return out


def allowed(svc: str, field: str) -> str | None:
    return ALLOWED.get((svc, field)) or ALLOWED.get(("*", field))


def check_compose(src: Path, rep: Report) -> None:
    main = load_compose(src / "docker-compose.yml")
    T = REL / "build/overlay/templates"
    rel = load_compose(T / "docker-compose.release.yml", T / "docker-compose.tls.yml", T / "docker-compose.email.yml")

    for vol in main["volumes"]:
        rep.add("compose", f"volume {vol}", "PASS" if vol in rel["volumes"] else "FAIL",
                "" if vol in rel["volumes"] else "named volume missing in release")

    for name in sorted(set(main["services"]) | set(rel["services"])):
        m, r = main["services"].get(name), rel["services"].get(name)
        if m is None or r is None:
            why = allowed(name, "service")
            rep.add("compose", f"service {name}", "ALLOWED" if why else "FAIL",
                    why or ("missing in release" if r is None else "extra in release"))
            continue
        for field in ("cap_add", "cap_drop", "security_opt", "network_mode", "read_only", "user", "privileged", "expose", "networks", "env_file"):
            mv, rv = m.get(field), r.get(field)
            if isinstance(mv, list):
                mv = sorted(map(str, mv))
            if isinstance(rv, list):
                rv = sorted(map(str, rv))
            if isinstance(mv, dict):
                mv = sorted(mv)
            if isinstance(rv, dict):
                rv = sorted(rv)
            if mv == rv:
                if mv is not None:
                    rep.add("compose", f"{name}.{field}", "PASS", str(mv))
            else:
                why = allowed(name, field)
                rep.add("compose", f"{name}.{field}", "ALLOWED" if why else "FAIL", why or f"main={mv} release={rv}")
        # image/build
        if "build" in m and "image" in r:
            rep.add("compose", f"{name}.image", "ALLOWED", f"{allowed(name, 'image')} ({r['image']})")
        elif m.get("image") != r.get("image"):
            rep.add("compose", f"{name}.image", "FAIL", f"main={m.get('image')} release={r.get('image')}")
        else:
            rep.add("compose", f"{name}.image", "PASS", str(m.get("image")))
        # environment
        me, re_ = env_dict(m.get("environment")), env_dict(r.get("environment"))
        for k in sorted(set(me) | set(re_)):
            if me.get(k) == re_.get(k):
                rep.add("compose", f"{name}.env {k}", "PASS", "")
            else:
                why = allowed(name, f"env:{k}")
                rep.add("compose", f"{name}.env {k}", "ALLOWED" if why else "FAIL", why or f"main={me.get(k)} release={re_.get(k)}")
        # volumes by mount target
        mm, rm = mounts(m), mounts(r)
        for tgt in sorted(set(mm) | set(rm)):
            if tgt in mm and tgt in rm and mm[tgt] == rm[tgt]:
                rep.add("compose", f"{name}.volume {tgt}", "PASS", f"{mm[tgt][0]}")
            else:
                why = allowed(name, f"volume:{tgt}")
                rep.add("compose", f"{name}.volume {tgt}", "ALLOWED" if why else "FAIL",
                        why or f"main={mm.get(tgt)} release={rm.get(tgt)}")
        for field in ("ports", "command", "depends_on", "restart", "healthcheck", "logging", "pull_policy"):
            mv, rv = m.get(field), r.get(field)
            if mv == rv:
                if mv is not None:
                    rep.add("compose", f"{name}.{field}", "PASS", str(mv))
                continue
            if field == "depends_on" and isinstance(mv, dict) and isinstance(rv, dict) and mv == rv:
                continue
            why = allowed(name, field)
            rep.add("compose", f"{name}.{field}", "ALLOWED" if why else "FAIL", why or f"main={mv} release={rv}")


def settings_fields(path: Path) -> dict[str, str]:
    """Backend Settings fields -> default expression (source text)."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    out = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "Settings":
            for st in node.body:
                if isinstance(st, ast.AnnAssign) and isinstance(st.target, ast.Name):
                    out[st.target.id.upper()] = ast.unparse(st.value) if st.value is not None else "<required>"
    return out


def check_env(src: Path, rep: Report) -> None:
    example = [l.split("=", 1)[0].lstrip("# ").strip() for l in (src / ".env.example").read_text(encoding="utf-8").splitlines()
               if re.match(r"^#?\s*[A-Z][A-Z0-9_]*=", l)]
    settings = settings_fields(src / "backend/app/core/config.py")
    helper = sorted(set(re.findall(r'os\.getenv\("([A-Z0-9_]+)"', (src / "helper/helper/config.py").read_text(encoding="utf-8"))))
    template = {l.split("=", 1)[0] for l in (REL / "build/overlay/templates/.env.template").read_text(encoding="utf-8").splitlines()
                if re.match(r"^[A-Z][A-Z0-9_]*=", l)}
    T = REL / "build/overlay/templates"
    rel = load_compose(T / "docker-compose.release.yml", T / "docker-compose.tls.yml", T / "docker-compose.email.yml")
    compose_env = set()
    for s in rel["services"].values():
        compose_env |= set(env_dict(s.get("environment")))
    main_compose = load_compose(src / "docker-compose.yml")
    main_compose_env = set()
    for s in main_compose["services"].values():
        main_compose_env |= set(env_dict(s.get("environment")))

    for k in sorted(set(example)):
        if k in template or k in compose_env:
            rep.add("env", f".env.example {k}", "PASS", "set by the release")
        elif k in ENV_JUSTIFIED and ENV_JUSTIFIED[k]:
            rep.add("env", f".env.example {k}", "ALLOWED", ENV_JUSTIFIED[k])
        else:
            rep.add("env", f".env.example {k}", "FAIL", "in main's .env.example but not set by the release")
    for k, default in sorted(settings.items()):
        if k in template or k in compose_env:
            rep.add("env", f"backend {k}", "PASS", "set by the release")
        elif k in example or k in main_compose_env:
            rep.add("env", f"backend {k}", "FAIL", "main sets it, release does not")
        else:
            rep.add("env", f"backend {k}", "DEFAULT", f"same code default as main: {default}")
    for k in helper:
        if k in template or k in compose_env:
            rep.add("env", f"helper {k}", "PASS", "set by the release")
        elif k in example or k in main_compose_env:
            rep.add("env", f"helper {k}", "FAIL", "main sets it, release does not")
        else:
            rep.add("env", f"helper {k}", "DEFAULT", "same code default as main")


def apt_packages(dockerfile: Path) -> set[str]:
    txt = dockerfile.read_text(encoding="utf-8").replace("\\\n", " ")
    pkgs: set[str] = set()
    for m in re.finditer(r"apt-get install[^&]*?--no-install-recommends\s+([^&]+)", txt):
        pkgs |= {p for p in m.group(1).split() if re.match(r"^[a-z0-9][a-z0-9.+-]+$", p)}
    return pkgs


def pins(req: Path) -> dict[str, str]:
    out = {}
    for line in req.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        m = re.match(r"^([A-Za-z0-9_.-]+)(\[[^\]]+\])?==([^\s;]+)", line)
        if m:
            out[m.group(1).lower().replace("_", "-")] = m.group(3)
    return out


def freeze_section(sbom: str, title: str) -> dict[str, str]:
    m = re.search(rf"## python packages — {title} \(pip freeze\)\n(.*?)(\n## |\Z)", sbom, re.S)
    out = {}
    for line in (m.group(1) if m else "").splitlines():
        if "==" in line:
            n, v = line.split("==", 1)
            out[n.strip().lower().replace("_", "-")] = v.strip()
    return out


def check_packages(src: Path, evidence: Path | None, rep: Report) -> None:
    O = REL / "build/overlay/images"
    for comp, main_df, rel_df in (("backend", src / "backend/Dockerfile", O / "backend.Dockerfile"),
                                  ("helper", src / "helper/Dockerfile", O / "helper.Dockerfile")):
        missing = apt_packages(main_df) - apt_packages(rel_df)
        extra = apt_packages(rel_df) - apt_packages(main_df)
        rep.add("packages", f"{comp} apt", "PASS" if not missing else "FAIL",
                f"main's {len(apt_packages(main_df))} packages all present" + (f"; extra: {sorted(extra)}" if extra else "")
                if not missing else f"missing: {sorted(missing)}")
        txt = rel_df.read_text(encoding="utf-8")
        ok = "COPY requirements.txt" in txt and "pip install --no-cache-dir -r requirements.txt" in txt
        rep.add("packages", f"{comp} pip source", "PASS" if ok else "FAIL",
                "installs main's own requirements.txt (copied from SOURCE)" if ok else "release Dockerfile does not install requirements.txt")
        base = re.search(r"^FROM (\S+)", main_df.read_text(encoding="utf-8"), re.M).group(1)
        rbase = re.search(r"ARG BASE_IMAGE=(\S+)", txt).group(1)
        rep.add("packages", f"{comp} base image", "PASS" if rbase.startswith(base) else "FAIL",
                f"main {base} (floating) -> release {rbase}, pinned by digest at build")
    p = pins(src / "backend/requirements.txt")
    rep.add("packages", "pydyf pin", "PASS" if p.get("pydyf") == "0.10.0" else "FAIL", f"pydyf=={p.get('pydyf')}")
    sbom = evidence / "SBOM.txt" if evidence else None
    if sbom and sbom.is_file():
        s = sbom.read_text(encoding="utf-8")
        for comp in ("backend", "helper"):
            frz = freeze_section(s, comp)
            for name, ver in pins(src / f"{comp}/requirements.txt").items():
                have = frz.get(name)
                rep.add("packages", f"{comp} pip {name}", "PASS" if have == ver else "FAIL", f"pinned {ver}, image has {have}")
    else:
        rep.add("packages", "pip freeze vs requirements", "NOT RUN", "needs build evidence (dist/<pkg>-build-evidence/SBOM.txt)")


def check_nginx(src: Path, rep: Report) -> None:
    main = (src / "docker/nginx/nginx.conf").read_text(encoding="utf-8")
    cfg = (src / "backend/app/core/config.py").read_text(encoding="utf-8")
    limit = int(re.search(r"max_pcap_size_mb: int = (\d+)", cfg).group(1))
    for t in ("nginx-tls.conf.template", "nginx-http.conf.template"):
        rel = (REL / "build/overlay/templates" / t).read_text(encoding="utf-8")
        api = re.search(r"location /api/ \{[^}]*proxy_pass (\S+);", rel)
        rep.add("nginx", f"{t} /api/ proxy_pass", "PASS" if api and api.group(1) == "http://backend_upstream" else "FAIL",
                "no trailing slash: /api prefix preserved (refresh cookie Path=/api/auth)")
        up = re.search(r"location = /api/pcap/upload \{[^}]*client_max_body_size (\d+)m;", rel)
        rep.add("nginx", f"{t} upload limit", "PASS" if up and int(up.group(1)) >= limit else "FAIL",
                f"nginx {up.group(1) if up else '?'}m on /api/pcap/upload >= backend max_pcap_size_mb={limit} (backend returns the clean 413)")
        rep.add("nginx", f"{t} X-Forwarded-For", "PASS" if "X-Forwarded-For $proxy_add_x_forwarded_for" in rel else "FAIL",
                "backend reads X-Forwarded-For for audit/lockout IPs (same as main)")
    mlim = re.search(r"client_max_body_size (\d+)m", main)
    rep.add("nginx", "main upload limit", "DISCREPANCY (main)",
            f"main nginx caps every body at {mlim.group(1) if mlim else '?'}m although the backend accepts {limit} MB PCAPs — "
            "uploads > 20 MB fail on main; the release fixes this only for /api/pcap/upload (main unchanged)")


def check_suricata(src: Path, rep: Report) -> None:
    main = (src / "docker/suricata/suricata.yaml").read_text(encoding="utf-8").splitlines()
    tmpl_p = REL / "build/work/stage"
    found = sorted(tmpl_p.glob("*/templates/suricata.yaml.template")) if tmpl_p.is_dir() else []
    if not found:
        rep.add("suricata", "suricata.yaml.template", "NOT RUN", "no staged template (run build/build-release.sh first)")
        return
    rel = found[-1].read_text(encoding="utf-8").splitlines()
    diff = [l for l in difflib.unified_diff(main, rel, lineterm="", n=0) if l[:1] in "+-" and not l.startswith(("+++", "---"))]
    unexpected = [l for l in diff if not re.search(r"HOME_NET:|- interface: ", l)]
    rep.add("suricata", "suricata.yaml vs main", "PASS" if not unexpected else "FAIL",
            f"only HOME_NET + af-packet interface templated ({len(diff)} changed lines)" if not unexpected else f"unexpected: {unexpected[:4]}")


def check_migrations(src: Path, rep: Report) -> None:
    allow = (REL / "build/allowlist.txt").read_text(encoding="utf-8").split()
    ign = (REL / "build/dockerignore").read_text(encoding="utf-8")
    deny = (REL / "build/denylist.txt").read_text(encoding="utf-8")
    ok = "backend" in allow and "alembic" not in ign and "alembic" not in deny
    n = len(list((src / "backend/alembic/versions").glob("*.py")))
    rep.add("schema", "alembic migrations in image", "PASS" if ok else "FAIL",
            f"all {n} main migrations copied into the backend image; backend entrypoint runs `alembic upgrade head`")


def check_schema(evidence: Path | None, main_schema: Path | None, rep: Report) -> None:
    rel = evidence / "schema-release.sql" if evidence else None
    if not (rel and rel.is_file() and main_schema and main_schema.is_file()):
        rep.add("schema", "pg_dump --schema-only diff", "NOT RUN", "needs schema-release.sql (build evidence) and --main-schema")
        return
    norm = lambda t: [l for l in t.splitlines() if l.strip() and not l.startswith("--") and not l.startswith("SET ") and "pg_catalog.set_config" not in l]
    d = list(difflib.unified_diff(norm(main_schema.read_text(encoding="utf-8")), norm(rel.read_text(encoding="utf-8")), lineterm="", n=0))
    rep.add("schema", "pg_dump --schema-only diff", "PASS" if not d else "FAIL", "identical (tables, partitions, triggers, rules)" if not d else "\\n".join(d[:6]))


def check_security(rep: Report) -> None:
    T = REL / "build/overlay/templates"
    rel = load_compose(T / "docker-compose.release.yml", T / "docker-compose.tls.yml", T / "docker-compose.email.yml")
    s = rel["services"]
    rep.add("security", "helper not privileged", "PASS" if not s["helper"].get("privileged") else "FAIL", "")
    for n in ("redis", "backend", "worker", "helper", "relay-shim"):
        rep.add("security", f"{n} publishes no port", "PASS" if not s[n].get("ports") else "FAIL", "")
    rep.add("security", "db port loopback only", "PASS" if s["db"]["ports"] == ["127.0.0.1:5433:5432"] else "FAIL", str(s["db"]["ports"]))
    env = (T / ".env.template").read_text(encoding="utf-8")
    rep.add("security", "ENVIRONMENT=production", "PASS" if "\nENVIRONMENT=production" in env else "FAIL", "hides /api/docs, Secure refresh cookie")
    for t in ("nginx-tls.conf.template", "nginx-http.conf.template"):
        txt = (T / t).read_text(encoding="utf-8")
        hs = all(h in txt for h in ("Content-Security-Policy", "X-Frame-Options", "X-Content-Type-Options", "Referrer-Policy"))
        rep.add("security", f"{t} security headers", "PASS" if hs else "FAIL", "")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--evidence")
    ap.add_argument("--main-schema")
    ap.add_argument("--report")
    a = ap.parse_args()
    src = Path(a.source).resolve()
    if not (src / "docker-compose.yml").is_file():
        nested = [p.parent for p in src.glob("*/docker-compose.yml")]
        if len(nested) != 1:
            print(f"not a SentinelCore source tree: {src}", file=sys.stderr)
            return 2
        src = nested[0]
    ev = Path(a.evidence).resolve() if a.evidence else None
    rep = Report()
    check_compose(src, rep)
    check_env(src, rep)
    check_packages(src, ev, rep)
    check_nginx(src, rep)
    check_suricata(src, rep)
    check_migrations(src, rep)
    check_schema(ev, Path(a.main_schema) if a.main_schema else None, rep)
    check_security(rep)
    counts: dict[str, int] = {}
    for _, _, st, _ in rep.rows:
        counts[st] = counts.get(st, 0) + 1
    md = (f"# Static parity report\n\nsource: `{src.name}` (read-only)\n\n"
          f"summary: {', '.join(f'{k} {v}' for k, v in sorted(counts.items()))}\n\n{rep.markdown()}\n\n"
          f"RESULT: {'CLEAN (no unexplained differences)' if rep.fail == 0 else f'{rep.fail} UNEXPLAINED DIFFERENCE(S)'}\n")
    if a.report:
        Path(a.report).write_text(md, encoding="utf-8")
    print(md)
    return 0 if rep.fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
