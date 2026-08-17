#!/usr/bin/env bash
#
# common.sh — logging helpers shared by every script in this repo.
#
# SOURCE this file, never execute it — hence not +x. Definitions only, so
# sourcing twice is harmless. Sets no shell options: `set -euo pipefail` belongs
# in the calling script where it can be seen.
#
# log goes to stdout (a script's output), warn and die to stderr (diagnostics).
# die calls exit, which is what makes it work inside a function — and which will
# close your terminal if you source this interactively and call it.

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}
