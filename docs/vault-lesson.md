# Reading `docker/vault/` — a lesson plan

Seven lessons over the lab's secret store and certificate authority. Each names
what to read, the ideas inside it, something to run, and a **You understand this
when** you can answer without looking.

Work with the file open beside this. Line numbers move; the `# --- section ---`
banners do not, so those are what get cited.

```
docker/vault/
  docker-compose.yml        73    how the container is run
  config/vault.hcl          38    how Vault is configured
  vault-installer.sh       325    nothing -> running, unsealed, configured
  scripts/
    vault-unseal.sh        153    what you run when it is sealed
    vault-ensure-cloudstack.sh  330   a worked example of secrets
  certs/                          runtime, gitignored: tls.crt/key, bundle, ca
  data/                           raft storage. Encrypted at rest
  logs/                           the audit device writes here
  secrets/vault-init.json         the unseal key. One copy. No second one
```

---

## Lesson 1 · The container

**Read:** `docker-compose.yml` end to end. It is 73 lines and about 40 are comments.

**The four ideas:**

**Pinned by digest, not tag.** Line 25 carries both `2.0.4` and
`@sha256:5be497…`. The tag is for you; Docker verifies the digest and ignores it.
A tag is a mutable pointer — `2.0.4` can mean different bytes next week, which
breaks "runnable on a fresh VM" in the way hardest to notice. The cost is stated
in the comment: a pin freezes you on today's CVEs, and only works if something
tells you when to bump.

**`user: "65100:65100"`.** Not the image's own `100:1000`. Ubuntu hands uid 100
to whichever package claims it first, so on the host it means a different daemon
on every machine — and that daemon could read Vault's key. 65100 belongs to
nobody. Pinning a user also skips the entrypoint's `chown` and `setcap`, which is
why `disable_mlock = true` appears in `vault.hcl`.

**`extra_hosts: vault.lab.test:127.0.0.1`.** The CLI *inside* the container must
dial the name the certificate carries or TLS fails on a name mismatch. This keeps
that traffic on loopback while the name still matches.

**No healthcheck, deliberately.** Read the comment at the top: `docker ps` looks
identical for a sealed Vault, an unreachable one and a working one. A green
healthcheck would be a lie.

**Run:**
```sh
sudo docker inspect vault --format '{{.Config.User}} {{.Config.Image}}'
sudo docker compose -f docker/vault/docker-compose.yml config | head -30
```

**You understand this when** you can say what breaks if `user:` is removed, and
why a healthcheck would be worse than none.

---

## Lesson 2 · The configuration

**Read:** `config/vault.hcl`, all 38 lines.

**Bind versus advertise.** Two pairs that look like one setting each:

| | |
|---|---|
| `listener.address` `0.0.0.0:8200` | where Vault **binds**, inside the container's namespace |
| `api_addr` `https://vault.lab.test:8200` | what Vault **advertises** to clients |

Get the second wrong and Vault works while telling clients to go somewhere they
cannot reach. Raft requires both.

**`tls_cert_file` is `bundle.crt`, not `tls.crt`.** The bundle is leaf + chain —
what a server is supposed to send. A bare leaf works in a browser that already
cached the issuer and fails in `curl` on a clean machine, which is the worst kind
of bug: it works where you test it.

**Storage is raft on a bind mount.** `/vault/data` is `./data` on the host,
encrypted at rest — with the key that decrypts it living in
`secrets/vault-init.json`. Which is why committing `data/` would be committing
every secret the lab has, one leak of that file later.

**Nothing secret is in this file**, and the comment says why: a value that needs
protecting does not belong in a config file at all. That is the argument Vault
exists to make.

**You understand this when** you can explain why `api_addr` is a name and
`address` is `0.0.0.0`.

---

## Lesson 3 · Getting it running

**Read:** `vault-installer.sh` from the top to `# --- initialise ---`. Three
sections.

**`# --- a certificate to start with ---`.** The chicken-and-egg: Vault needs a
certificate to start, and Vault is what issues certificates. Broken in two
passes — a self-signed certificate brings the listener up, and once the PKI
exists Vault issues itself a real one (Lesson 5). TLS is on from the first start
either way; it is just self-signed for the first few minutes.

Notice the guard is `[[ -s "${TLS_CRT}" && -s "${TLS_KEY}" ]]`. Without it, a
re-run would replace a Vault-issued certificate with a self-signed one.

**`# --- ownership, before the container ---`.** Every `install -d -o 65100` runs
*before* `compose up`. Docker creates a missing bind-mount source **as root**, so
doing this afterwards is a repair, not a prevention — and a race.

`logs/` matters more than `data/`: **Vault stops serving requests if it cannot
write its audit log.** Get that mount wrong and enabling the audit device takes
Vault down.

**`# --- wait for it to listen ---`.** `compose up -d` returns when the process
*starts*, not when it *listens*. The loop treats any HTTP status as success and
only `000` — curl's "no connection at all" — as not-yet. That is deliberate: 501
(uninitialised) and 503 (sealed) are states the next sections need to find.

**Run:**
```sh
sudo ls -ln docker/vault/           # every dir 65100, secrets/ root 0700
curl -s -o /dev/null -w '%{http_code}\n' https://vault.lab.test:8200/v1/sys/health
```

**You understand this when** you can say why the readiness loop must not use
`--fail`.

---

## Lesson 4 · Initialise and unseal

**Read:** `# --- initialise ---` in the installer, then all of
`scripts/vault-unseal.sh`.

**This is the most important idea in the directory.**

`vault operator init` mints the **storage encryption key** — once, ever. It is
split into Shamir shares (here 1-of-1, the degenerate case) and returned exactly
once, to stdout, into `secrets/vault-init.json`. **It cannot live in Vault**,
because it is what decrypts Vault.

**Seal is not stop.** A restarted Vault is running, listening, and answering
everything `503`. `restart: unless-stopped` brings the container back **sealed** —
which is why unsealing is a separate script that must work after a reboot, in a
drill, with nothing else present.

**Four states, cross-checked against disk**, not three. Read the two guards:

| health | `vault-init.json` | meaning |
|---|---|---|
| 501 | absent | fresh. Initialise |
| 501 | **present** | storage was wiped under a Vault that existed. **Refuse** |
| not 501 | absent | works now; comes back sealed with nothing to open it. **Refuse** |
| not 501 | present | normal. Leave alone |

Both refusals name the recovery command. Neither tries to fix it, because both
fixes destroy something.

**In `vault-unseal.sh`, two details worth the time:**

The key travels in the request **body** via `--data @-`, never in `argv` where
`ps` shows it to every user on the host. The comment explains why this is the
API and not `vault operator unseal`: the CLI refuses a pipe outright, and its
only non-interactive form puts the key in argv.

And the final check exists because **`operator unseal` exits 0 when it accepted a
share without meeting the threshold**. A clean loop and a sealed Vault are
compatible, so the script asks `seal-status` rather than trusting exit codes.

**Run:**
```sh
sudo docker compose -f docker/vault/docker-compose.yml restart vault
curl -s https://vault.lab.test:8200/v1/sys/health | jq '{sealed, initialized}'
sudo ./docker/vault/scripts/vault-unseal.sh
```

**You understand this when** you can say what is lost if `vault-init.json` is
deleted, and why the script refuses rather than re-initialising.

---

## Lesson 5 · The CA

**Read:** `# --- PKI ---` through `# --- issue Vault its real certificate ---`.
Then `docs/decisions.md` entry **3.4-5**.

**One self-signed CA, issuing leaves directly.** `pki/root/generate/internal`
creates a key and a self-signed certificate *inside* Vault. The private key never
leaves it — there is no file on disk to protect, which is the whole point.

This replaced a three-certificate arrangement: an openssl root that signed both an
intermediate and Vault's issuing CA. `3.4-5` records why one tier is the honest
answer here — **a two-tier PKI exists so the root can be offline**, and both tiers
in the same Vault is the shape without the property.

**Roles are the interesting part.** A role is server-side policy:

```
allowed_domains="lab.test"   allow_subdomains=true
allow_bare_domains=false     allow_localhost=false     allow_ip_sans=false
ttl=720h                     max_ttl=720h
```

A caller asks for a name and a lifetime; **the role decides whether it may have
them**. Compare the CA this replaced, where the equivalent rules sat in a config
file and were enforced only because the client chose to pass them. That is the
difference between a client restraining itself and a server refusing.

**Two roles, because one TTL does not fit both.** `lab-server` is 720h for the
proxy's certificates. `lab-vault` is 8760h for Vault's own — renewal automation
does not exist yet, and a 30-day certificate on the thing everything else
authenticates to would expire unattended.

**The loop closes** in the last section: if Vault is still on its bootstrap
self-signed certificate, it issues itself a real one from its own PKI and
restarts. Guarded on the issuer CN so a re-run does not reissue every time.

**Run:**
```sh
VT=$(sudo jq -r .root_token docker/vault/secrets/vault-init.json)
V() { sudo docker exec -e VAULT_TOKEN="$VT" vault vault "$@"; }

V list pki/issuers                      # exactly one
V read -field=certificate pki/cert/ca | openssl x509 -noout -subject -issuer
V write -format=json pki/issue/lab-server common_name=probe.lab.test ttl=1h \
  | jq -r .data.certificate | openssl x509 -noout -text | grep -A1 'Alternative'

V write pki/issue/lab-server common_name=probe.example.com    # refused, by the ROLE
V write pki/issue/lab-server common_name=x.lab.test ttl=9000h # refused, by max_ttl
```

Those last two are the lesson. Read the errors.

**You understand this when** you can explain why the role's refusal is worth more
than the same rule in the client, and what a second issuer in that mount would
mean.

---

## Lesson 6 · Secrets

**Read:** `# --- KV v2 ---` in the installer, then all of
`scripts/vault-ensure-cloudstack.sh`.

**KV v2 has two paths for one secret**, and this catches everyone:

| | |
|---|---|
| `secret/cloudstack/admin` | what the CLI takes |
| `secret/data/cloudstack/admin` | what the **API** takes, and what a policy must name |

A policy written against the CLI path silently grants nothing.

**The three directions of a secret** — the reason this file is worth reading
carefully. It handles all three:

**1 · Captured.** CloudStack already has an API key; `getUserKeys` reads it back.
Vault stores a copy. The danger is in the comment on `register_cloudstack_api_keys`:
`registerUserKeys` is **not a read** — it mints new keys and invalidates the old
ones. So the code captures first and only registers when there is nothing to
capture. Calling it unconditionally would silently break every existing consumer
with a 401 that explains nothing.

**2 · Generated.** Gitea's database and admin passwords are created **in Vault
before Gitea exists** (see `docker/gitea/gitea-installer.sh`). Vault is the
origin, not a copy. Nobody ever chooses these passwords.

**3 · Minted once.** A Gitea API token is neither: the service mints it and
**will not show it again**, so the only moment it can be stored is the moment it
is created. There is nothing on the far side to compare against — so the guard is
whether the stored token still *works*. That is in `docker/gitea/gitea-repo-setup.sh`.

**The fourth state, and why it refuses.** Read `ensure_api_key`. When Vault's
stored key and CloudStack's live key disagree, the script **dies** rather than
rotating. It cannot tell a database redeploy from a key someone else is still
using, and fixing it by rotating would break the second case. So it names the
reseed command and stops.

**Run:**
```sh
V kv list secret/                       # cloudstack/ gitea/ demo/
V kv get secret/gitea/postgres          # generated in Vault, never chosen
V kv get -field=api_key secret/cloudstack/admin-api
V read sys/audit                        # every request above is in logs/audit.log
sudo tail -2 docker/vault/logs/audit.log | jq '.request.path'
```

Look at the audit log: values are HMAC'd, **paths are not**. That is why
`decisions.md` treats it as sensitive.

**You understand this when** you can say which of the three directions a new
secret belongs to before writing any code for it.

---

## Lesson 7 · Putting it together

No new reading. Answer these from the material:

1. Vault restarts at 3am. What state is it in, what still works, and what does
   not?
2. `secrets/vault-init.json` is deleted while Vault runs happily. What have you
   lost, and when do you find out?
3. Someone adds a second issuer to `pki/`. What breaks, and how would you notice?
4. A service needs a certificate for `db.lab.test` with a 60-day lifetime. What
   happens, and where is that decided?
5. `docker/vault/logs` is chowned to root. What is the symptom?
6. Why is `ca.crt` a separate file from `bundle.crt` when Vault serves the bundle?

Then the real test — **delete the container and bring it back**:

```sh
sudo docker compose -f docker/vault/docker-compose.yml down
sudo ./docker/vault/vault-installer.sh
```

Every step should report "already" and the lab should still serve. Anything that
does work the second time is either a bug or something worth understanding.

---

## Where this goes next

Vault becomes the issuing CA for the cluster at **5.3** (cert-manager) and the
source of application credentials at **6.3** (External Secrets Operator) — a pod
proves who it is to Vault and receives a credential nobody wrote down. Both build
directly on Lessons 5 and 6.
