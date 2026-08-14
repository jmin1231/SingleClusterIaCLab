# Task runner for this repo. Targets are jobs, not files.
#
#   make          show the targets
#   make setup    one-time per-clone: enable the git hooks
#   make lint     check formatting and syntax — never writes
#   make fmt      rewrite files into canonical format — the only target that writes
#
# lint and fmt are kept apart so the pre-commit hook can never modify a file:
# a check that rewrites makes the second run differ from the first.
#
# A missing linter warns locally and fails under STRICT=1, because a fresh host
# has none of the toolchain until host prep has run. CI sets STRICT=1.
#
# The file list comes from git, so .gitignore is respected for free and the
# linters never reach into secrets/ or data/ directories.

SHELL := /bin/bash

.DEFAULT_GOAL := help
.PHONY: help lint fmt setup

STRICT ?= 0

FILES := $(shell git ls-files --cached --others --exclude-standard)

# Upstream code we vendor but do not maintain. Excluded from lint AND fmt to keep
# it byte-comparable with upstream: reformatting turns a 260-line patch diff into
# a 4,000-line one, and fixing its shellcheck findings only widens the gap. This
# is per-file on purpose — the other scripts alongside it are ours and are linted.
VENDORED := cloudstack/cloudstack-install.sh

SH    := $(filter-out $(VENDORED),$(wildcard $(filter %.sh,$(FILES))))
YAML  := $(filter-out $(VENDORED),$(wildcard $(filter %.yml %.yaml,$(FILES))))

# ---------------------------------------------------------------------------

help: ## Show the available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-8s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Check formatting and syntax. Never modifies a file.
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "$(SH)" | xargs -r shellcheck; \
	else \
		echo "skip: shellcheck not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	fi
	@if command -v shfmt >/dev/null 2>&1; then \
		echo "$(SH)" | xargs -r shfmt -d; \
	else \
		echo "skip: shfmt not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	fi
	@if command -v yamllint >/dev/null 2>&1; then \
		echo "$(YAML)" | xargs -r yamllint -c .yamllint; \
	else \
		echo "skip: yamllint not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	fi
	@if command -v terraform >/dev/null 2>&1; then \
		terraform fmt -check -recursive; \
	else \
		echo "skip: terraform not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	fi

fmt: ## Rewrite files into canonical format. The only target that writes.
	@if command -v shfmt >/dev/null 2>&1; then \
		echo "$(SH)" | xargs -r shfmt -w; \
	else \
		echo "skip: shfmt not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	fi
	@if command -v terraform >/dev/null 2>&1; then \
		terraform fmt -recursive; \
	else \
		echo "skip: terraform not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	fi

setup: ## One-time per-clone setup: enable the git hooks
	chmod +x .githooks/pre-commit
	git config core.hooksPath .githooks
	@[ "$$(git rev-parse --git-path hooks)" = ".githooks" ] || { echo "hooksPath did not take"; exit 1; }
