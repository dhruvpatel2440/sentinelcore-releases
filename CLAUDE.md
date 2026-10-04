# CLAUDE.md — sentinelcore-release (project rules for Claude Code)

## Purpose
This project builds the public distribution of SentinelCore: a production website, a clean Linux release ZIP,
a guided installer, and a central email relay. It is SEPARATE from the live SentinelCore project.

## Paths
- SOURCE_DIR = ../SentinelCore  (READ-ONLY reference. Adjust if different.)
- RELEASE_DIR = this folder

## Hard rules
1. NEVER write, edit, delete, move, chmod, format or run `git` write commands (commit, push, checkout, stash, config, remote) inside SOURCE_DIR.
   Read-only commands are fine (cat, ls, grep, `git log`, `git ls-files`).
2. To build a release, COPY needed files from SOURCE_DIR into a temp build dir (`build/work/`) and work on the copy.
   Any change the release needs (bootstrap scripts, compose overrides, config templates) is added as an OVERLAY in RELEASE_DIR, not by editing source.
3. NEVER open or print the contents of any `.env`, key, token or credential file. Read only variable NAMES (e.g. `grep -o '^[A-Z_]*=' .env`).
4. Real secrets must never appear in: the release ZIP, website, relay repo, logs, docs, test fixtures or git history.
5. Do not push anywhere. Do not create a public repo. Git here is local/private only.
6. Target OS for v1: Ubuntu 22.04 / 24.04 (Debian-family) on x86_64. Linux only. No Windows/macOS.
7. Everything runs locally on the user's PC. The only outbound dependency is the SentinelCore email relay (HTTPS).
8. Prefer simple, auditable Bash + Docker Compose. Run `shellcheck` on all scripts.
9. After every phase: summarise what was created, list files, list open questions. Wait for review.

## Target layout
```
sentinelcore-release/
├── CLAUDE.md
├── design/              # user's design sample (Foundations + Components)
├── docs-internal/       # analysis reports (not shipped)
├── build/               # build-release.sh, allowlist, overlay files
├── installer/           # install.sh, uninstall.sh, lib/, templates/
├── relay/               # email relay service
├── website/             # production site
├── tests/               # audits & VM test scripts
└── dist/                # build output (gitignored)
```

## Release ZIP layout (what customers get)
```
sentinelcore-<version>/
├── install.sh  uninstall.sh  README.md  VERSION  SHA256SUMS
├── lib/  templates/ (.env.template, docker-compose.release.yml)
├── images/ (docker image tarballs)   # no source repo, no .git, no tests, no dev files
└── docs/
```

## Style
- Match the user's team preference: bullet-point, medium-length explanations; exact copy-paste commands.
