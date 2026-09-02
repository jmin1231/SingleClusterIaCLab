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
#
# Verified against disk below: filter-out is a literal path match, so a moved or
# renamed file leaves an exclusion that quietly matches nothing and looks exactly
# like no exclusion at all.
VENDORED := cloudstack/scripts/cloudstack-install.sh

ifeq ($(wildcard $(VENDORED)),)
$(error VENDORED names a path that does not exist: $(VENDORED). It moved — update this)
endif

SH    := $(filter-out $(VENDORED),$(wildcard $(filter %.sh,$(FILES))))
YAML  := $(filter-out $(VENDORED),$(wildcard $(filter %.yml %.yaml,$(FILES))))

# From git like the rest, and that is the whole point. `terraform fmt -recursive`
# walks the FILESYSTEM instead, so on a host that has actually run bootstrap it
# descends into ca/intermediate, docker/vault/data and docker/vault/secrets —
# root-owned 0700 directories — and fails with "Cannot read directory". Those are
# all gitignored, so taking the list from git skips them for free, exactly as the
# header above claims for the linters. Verified: terraform fmt accepts file paths
# and multiple of them, exiting 3 when a file needs reformatting.
TF    := $(filter-out $(VENDORED),$(wildcard $(filter %.tf %.tfvars,$(FILES))))

# Every path a CA script writes a private key to. Asserted ignored by lint rather
# than trusted, for the same reason VENDORED is verified against disk above: an
# ignore rule and the path it protects can drift apart silently. They already did
# once — the pki/ -> ca/ rename carried the .gitignore entries and left the
# generated root key behind, un-ignored. Checked as file paths, not directories,
# so the assertion is "this key cannot be committed" whichever rule covers it.
# The third is Vault's bootstrap key (3.4-1) — the only leaf this lab issues
# from openssl, and the only unencrypted private key in the tree.
CA_KEYS := ca/root/root-ca.key.enc ca/intermediate/intermediate-ca.key.enc \
           docker/vault/certs/tls.key

# ---------------------------------------------------------------------------

help: ## Show the available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-8s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Check formatting and syntax. Never modifies a file.
	@for key in $(CA_KEYS); do \
		git check-ignore -q "$$key" || { \
			echo "FAIL: $$key is not gitignored — a CA private key is committable"; \
			exit 1; \
		}; \
	done
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
	@if ! command -v terraform >/dev/null 2>&1; then \
		echo "skip: terraform not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	elif [ -z "$(TF)" ]; then \
		echo "skip: no terraform files yet"; \
	else \
		terraform fmt -check $(TF); \
	fi

fmt: ## Rewrite files into canonical format. The only target that writes.
	@if command -v shfmt >/dev/null 2>&1; then \
		echo "$(SH)" | xargs -r shfmt -w; \
	else \
		echo "skip: shfmt not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	fi
	@if ! command -v terraform >/dev/null 2>&1; then \
		echo "skip: terraform not installed"; \
		[ "$(STRICT)" = "0" ] || exit 1; \
	elif [ -z "$(TF)" ]; then \
		echo "skip: no terraform files yet"; \
	else \
		terraform fmt $(TF); \
	fi

setup: ## One-time per-clone setup: enable the git hooks
	chmod +x .githooks/pre-commit
	git config core.hooksPath .githooks
	@[ "$$(git rev-parse --git-path hooks)" = ".githooks" ] || { echo "hooksPath did not take"; exit 1; }
