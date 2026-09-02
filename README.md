# The previous build

The first version of this lab: CloudStack, MinIO, and bash throughout, following
a sixteen-phase plan that ended in SSO and chaos drills. Roughly 3,800 lines of
working, heavily-commented shell — CoreDNS, a two-tier CA, Vault, Gitea with an
isolated runner, a reverse proxy — plus a 3,148-line decision log explaining it.

**Nothing here runs, and nothing in the new tree imports from it.** It is kept to
be read.

## How to read it

Attempt the step in [`../docs/build-plan.md`](../docs/build-plan.md) first, *then*
open the equivalent here to check yourself — never to find the answer before you
have tried. The plan rebuilds every service in this directory, and every step in
Phases 1–5 needs the absence of the thing it builds.

## Worth reading regardless of the step you are on

| | |
|---|---|
| `docker/gitea/runner/config.yaml` | Why a CI runner must not hold the host's Docker socket, and what `docker_host: "-"` closes |
| `ca/scripts/sign-vault-intermediate.sh` | `openssl ca` exits 0 when it *refuses* a CSR — the class of tooling landmine that motivated moving to Python |
| `docker/proxy/conf/default.conf.tmpl` | Why nginx needs an explicit default server, and what it answers for without one |
| `docker/vault/scripts/vault-unseal.sh` | 171 lines working around a CLI that refuses a pipe |

The full decision log is at `docs/decisions.md` in git history — it was removed
from this directory when the new one replaced it.
