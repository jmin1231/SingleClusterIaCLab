# Decisions

Append-only. Each entry: what was decided, what was rejected, and why. Six weeks
from now the *why* is the only part that still matters.

Format: newest at the bottom, so the file reads as a history.

---

## 0.2-1 · Repository layout is organised by tool

**Decided:** top-level directories per tool — `host/`, `docker/`, `packer/`,
`terraform/`, `ansible/`, `clusters/`, `app/`, `tests/`.

**Rejected:** organising by environment (`environments/dev/{terraform,ansible}`),
which makes promotion obvious but fragments each tool's config and fights
Terraform's module conventions.

**Why:** matches the reference lab, so its structure is directly readable while
learning. Accepted cost: one environment's definition is spread across
`terraform/`, `ansible/` and `clusters/overlays/`. Revisit at Phase 10.2 when
dev/prod overlays make the cost concrete.

---

## 0.2-2 · Shell dialect — UNRESOLVED

**Current state:** `Makefile` sets `SHELL := /bin/sh` (dash on Ubuntu), while
`.githooks/pre-commit` uses `#!/usr/bin/env bash` with `set -euo pipefail`.

**Why it matters:** `pipefail` is a bashism dash does not have, as are `[[ ]]`,
arrays, and some forms of `local`. Two dialects in one repo means a recipe that
works in your terminal can fail in make for no visible reason.

**Still to decide:** bash everywhere (matches the reference's scripts, and the
`.shellcheckrc` already disables SC2199, a bash array idiom — so bash is half
assumed already), or POSIX sh everywhere (more portable, forces discipline).

Resolve before writing the first real script in Phase 0.3.

---

## 0.2-3 · pre-commit lints the working tree, not the staged content

**Decided:** `make lint` reads `git ls-files --cached --others --exclude-standard`
— everything in the working tree that git does not ignore.

**Rejected:** linting the staged content only, via `git stash --keep-index` or a
temporary checkout of the index. Correct, but a stash accident inside a hook can
destroy uncommitted work.

**Why:** simple and catches essentially everything in practice. Two known gaps,
accepted deliberately:

- *False block* — an unstaged broken file refuses a commit that did not include it.
- *False pass* — a broken file staged, then fixed in the working tree without
  re-staging, lints clean while the broken version is committed.

The second is closed in CI at Phase 4.5, which runs against what was actually
pushed and cannot be bypassed with `--no-verify`.

---

## 0.2-4 · A missing linter warns; a missing `make` warns

**Decided:** absent tooling degrades gracefully. `make lint` skips a linter that
is not installed and prints `skip: <tool> not installed`. The pre-commit hook
does the same for `make` itself, then exits 0.

**Rejected:** blocking. It would make the guard pointless — an unguarded
`make lint` fails identically — and would prevent any commit on a fresh host.

**Why:** `make`, `shellcheck`, `shfmt` and `yamllint` are none of them present on
a minimal Ubuntu 24.04; they arrive in Phase 0.3. Phase 0.2 runs before that, so
"no commits until the toolchain exists" is not a workable rule.

**How the gap is closed:** `STRICT=1` makes a missing tool fatal, and CI sets it
from Phase 4.5. Lenient locally, strict where it counts.

---

## 0.2-5 · The Makefile repeats its guard four times

**Decided:** four near-identical `if command -v … else skip` blocks, rather than
factoring them into a `define` or `$(call …)`.

**Why:** deliberate deferral, not oversight. At four instances the repetition is
still readable and the abstraction would obscure more than it saves. Revisit if
a fifth linter appears, or if the guard logic needs to change in more than one
place at once — that is the signal the abstraction has earned its cost.

---

## 0.2-6 · Filenames in this repo may not contain spaces

**Decided:** treat whitespace in filenames as unsupported.

**Why:** `make lint` pipes the file list through `xargs`, which splits on
whitespace. `find -print0 | xargs -0` is the usual fix, but it does not apply
here — make lists are space-separated by definition, so a filename with a space
is already two entries before `xargs` sees it.

**Consequence:** a file named `my script.sh` will be silently mis-linted rather
than reported. This is a constraint the tooling imposes, so it is written down
rather than left to be discovered.

---

## 0.2-7 · Phantom files are filtered with `$(wildcard)`

**Decided:** `SH := $(wildcard $(filter %.sh,$(FILES)))`.

**Why:** `git ls-files --cached` lists names in git's *index*, not files that
exist on disk. A file staged and then deleted appears in the list and crashes
the linter trying to open it. `$(wildcard)` drops anything not present on disk.

Found the hard way: `make lint` broke immediately after the hook's own test file
was deleted but left staged.
