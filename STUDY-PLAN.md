# Study Plan — learning SingleClusterIaCLab deeply enough to pass the exam

**What this is.** A way of working through `PLAN-enterprise.md` (and any later lab) so that, at
the end, you can **explain** every tool and concept, **write** every script and file from a blank
page, and **diagnose** faults, with little or no help from Claude. It generalises and tightens the
learning loop adopted in `senior_jqr/issue_197/LESSON_PLAN.md` ("How every step runs") and
`issue_197/LEARNING_LOG.md`.

**Why it is built this way.** Every rule below comes from research on learning, cited in
[§9 References](#9-references). Where the evidence is weak or mixed, the plan says so.

**Set these values first** (everything else is scheduled from them):

| Setting | Your value | Default if unset |
|---|---|---|
| Build window | start `____-__-__` | **hard 3 weeks**, Mon 2026-11-09 → Sun 2026-11-29 |
| Exam date | `____-__-__` | **2026-11-30**, the day after the window |
| Daily hours | `__` h | **6 h of sessions + 20 min cards, Mon–Sat; Sun 2 h review** (§6.1 shows whether your value fits) |
| Exam format (hands-on? oral board? docs/internet allowed? time limit?) | `________` | assume hands-on build + oral questioning, man pages and `--help` allowed, no AI, no internet |

The format decides what "write it from a blank page" means in §2 (level W4). Find out and fill it in.

**Scope in three weeks.** Every step of PLAN §17.4 is scheduled: 90 steps, all required.
Exam-critical steps run the full loop; plumbing runs on the fast track (§3.8). The first six
steps of §3.8's cut order are already on the fast track, which leaves about 4.6 h of slack
(§6.1); read the rest of the cut order before week 1.

---

## Contents

1. [Principles (the evidence, in one table)](#1-principles)
2. [Mastery: what "I can explain it / write it / debug it" means](#2-mastery-definition)
3. [The session loop](#3-the-session-loop)
4. [Mapping PLAN-enterprise.md onto study units](#4-mapping-plan-enterprisemd-onto-study-units)
5. [Spaced repetition system](#5-spaced-repetition-system)
6. [Weekly and pre-exam cadence](#6-weekly-and-pre-exam-cadence)
7. [Artifacts (templates)](#7-artifacts)
8. [Using Claude well](#8-using-claude-well)
9. [References](#9-references)

---

## 1. Principles

Strength key: **Strong** = many experiments + meta-analyses, holds across materials;
**Moderate** = solid but narrower or with known boundary conditions; **Weak/mixed** = few studies,
mostly correlational, or contested.

| Technique | What the evidence says | Strength | How this plan uses it |
|---|---|---|---|
| **Retrieval practice** (self-testing) | Testing yourself beats rereading for long-term retention; classroom meta-analyses find about half a standard deviation gain. Dunlosky et al. rate it **high utility** [1][2][3][4][5]. | Strong | Every session starts and ends with recall from memory. Rereading and highlighting are not study methods here. |
| **Retrieval with complex material** | Some argue the benefit shrinks for very complex, high-interaction material [6]; others answer that it holds when retrieval is spaced and well designed [7]. | Mixed | Study a worked example first for brand-new material, *then* retrieve. Retrieve whole procedures (rebuild a file), not just isolated facts. |
| **Spaced practice** | Spreading reviews out beats massing them. Rated **high utility**. The best gap grows with how long you must remember: roughly 10–20% of the time to the test for weeks-to-months delays, falling to about 5% at a year [1][8][9]. | Strong | Expanding intervals per card (§5), capped so every card gets 2–3 more reviews before the exam. Rebuild drills come back days later, not the same day. |
| **Interleaving** | Mixing problem types beats blocking when types look alike and are easy to confuse; meta-analysis finds a moderate effect overall, but blocking can win for some material (e.g. word lists, expository text) [10][11]. | Moderate | Learn a new step *blocked*. Review *interleaved*: mixed cards across phases, mixed fault drills across layers, contrast cards for confusable pairs (timeout vs refused, 403 vs permission denied). |
| **Worked examples → completion problems → fading** | For novices, studying worked examples beats solving from scratch; fading the worked-out steps one at a time eases the move to independent solving [12][13][14]. | Strong | Every key file climbs a fading ladder S0→S4 (§3.3): worked example, template with holes (the issue_197 templates), skeleton, blank page with docs, blank page under exam conditions. |
| **Expertise reversal** | Guidance that helps novices *hurts* learners who already know the material: it becomes redundant load [15]. | Moderate–strong | Drop to the next fading stage as soon as you pass the current one. Templates are a starting point, not the way you keep working. |
| **Generation effect** | Producing an answer yourself beats reading it (meta-analysis, about 0.4 SD) [16]. | Strong (for simple material) | You write predictions, log entries, card answers and code. Claude never writes them for you by default. |
| **Pretesting / errorful attempts, hypercorrection** | Trying to answer *before* being taught helps, even when the try fails [17]. Errors you were confident about get corrected best once you see the feedback [18]. | Moderate | A 3–5 min "cold attempt" before study; predictions before every run; a confidence rating on every prediction, so confident misses get flagged and carded. |
| **Productive failure** (try to solve first, then get taught) | Helps conceptual understanding and transfer; little or no advantage for procedural skill [19][20]. | Moderate | Use it for *design* questions ("how would you let fe-1 reach the api with no route between tiers?"), not for syntax. Cap at 10 min. |
| **Self-explanation / elaborative interrogation** | Explaining *why* each step works helps (meta-analysis g ≈ 0.55). Dunlosky rates both **moderate** [1][21][22]. | Moderate–strong | "Why" cards; annotate each line of a worked example in your own words; examiner drills ask "why this and not that?" (§15 of the plan). |
| **Feynman technique / teaching** | No direct trials of the "Feynman technique" by name; it is folklore built on real effects: self-explanation [21], learning by preparing to teach and teaching (meta-analysis g ≈ 0.35–0.56) [23], and the illusion of explanatory depth: people overrate how well they understand mechanisms until they try to explain them [24]. | Indirect | The closed-book "explain it to the examiner" drill: it serves as both a learning technique and an honest test. |
| **Deliberate practice** | Targeted practice on weaknesses with immediate feedback matters, but explains much less of the variance in performance than once claimed (about 26% in games, 4% in education, under 1% in professions) [25][26]. | Moderate, contested | Practise your *weak* items (failed cards, slow rebuilds, missed faults) rather than repeating what already works; do not expect raw hours to stand in for that. |
| **Programming: read and trace before you write** | Tracing and explaining code correlate with writing it [27][28]. PRIMM (Predict–Run–Investigate–Modify–Make) helped school learners [29]. Parsons problems teach about as well as writing code, in less time [30]. | Moderate (mostly correlational / school-age) | Predict → run → investigate → modify → make is the order of the loop and of the fading ladder. Parsons cards for config blocks and code. |
| **Debugging is a skill you teach and practise** | Explicitly teaching a systematic debugging process improved learners' debugging [31]. In the 2026 AI-and-coding trial, debugging was where AI users lost the most [32]. | Moderate | Weekly fault-injection drills with a fixed diagnosis protocol (§4.6). |
| **Metacognition / calibration** | How well you *feel* you know something predicts badly; overconfidence leads to under-studying [33][24]. | Strong | Levels change only on a test result, never on feeling. Predict your score before every test and log the gap. |
| **Sleep** | Sleep consolidates memory [34]. Sleep quality and consistency over the weeks before a test went with better grades; sleep on the one night before did not [35]. | Moderate (the grades study is correlational) | Regular sleep is part of the plan. No all-nighters. Hard sessions not right before bed if they keep you awake. |
| **AI assistance** | Unguarded AI use raises practice performance but lowers performance once the AI is taken away; a hint-only tutor avoided that harm [36]. Junior developers learning a new library with AI scored 17 points lower on a quiz, worst on debugging; those who asked conceptual questions or wrote code first and then sought explanations kept their learning [32]. Well-designed tutors can beat active-learning classes [37]. | Moderate and growing | Claude is a tutor, not an author (§8): it asks, hints and checks; you generate. |

**Not used, because the evidence is poor:** rereading, highlighting, summarising as the main method
(rated **low utility** [1]), learning styles, and "I've seen it, so I know it."

---

## 2. Mastery definition

### 2.1 Three skills, scored 0–4

Every **concept** gets an **E** (explain) score. Every **file or script** gets **W** (write) and
**D** (debug) scores. Score only from a test done that day, written down in the tracker (§7.6).

| Level | **E — Explain** (closed book, out loud or written) | **W — Write** (a file or script) | **D — Debug** (a fault in that area) |
|---|---|---|---|
| 0 | Can't say what it is | Can't start | Can't tell where to look |
| 1 | Recognises it; explains with notes open | Completes a template with holes (stage S1), ≤ 3 hints | Fixes it with hints that name the layer |
| 2 | From memory: *what* it is and *how* it works; gaps on *why* or failure modes | Writes from a skeleton (S2), docs allowed, ≤ 2 hints | Names the right layer alone; needs a hint for the cause |
| 3 | From memory in ≤ 3 min: purpose, mechanism, **why this choice** (vs the §15 alternative), **two failure modes and their symptoms** | **Blank page (S3)**: official docs allowed, no Claude, ≤ 1 hint, passes the check (dry run / the step's Exit) | Diagnoses an injected fault from the symptom alone in ≤ 15 min; names the command that proved it |
| 4 | E3, plus answers 3 unseen examiner follow-ups and draws the diagram from memory, **≥ 7 days after last study** | **Exam conditions (S4)**: blank page, only what the exam allows (`man`, `--help`, `kubectl explain`, `terraform providers schema`), within the time budget, check passes by the 2nd run, **≥ 7 days after last touching it** | Mixed faults across layers, ≤ 10 min each; explains why the symptom showed up *where* it did |

**Hints count.** One rung on the hint ladder (§3.4) = one hint. Claude filling in code (the
"fill it in" escape hatch) caps that attempt at W1.

**Time budget for W4.** Your first unaided S3 time × 0.75, or the exam's per-task time if you
know it. Write the budget down *before* you start.

### 2.2 How much of each to aim for (tiers)

Everything in the lab is in scope, but not everything needs the same depth. The tier sets the
**target level** and the **order of practice**; it does not exclude anything. In three weeks the
tier follows the session mode (§3.8): guided steps make Tier A, fast-track steps Tier B.

| Tier | What | Target in the window | Examples from PLAN-enterprise.md |
|---|---|---|---|
| **A — write from blank** | Files from guided steps: they carry R1–R3, R5's GitOps and the security properties an examiner probes | E3 · W3 · D3 (level 4 needs ≥ 7 days since last study: only if the exam is a week or more after the window) | Vault config + init/unseal (2.4a–2.4b); PKI roots and roles, Vault's certificate, policies (2.5a, 2.5b, 2.5d, 2.5f); Terraform VPC/tiers/ACLs (5.2); Rego policy and the gated apply (5.3a–5.3b); `base` nftables (6.1b); the hub's forward policy (6.2b); the Flux tree and its gates (8.1b); Vault Kubernetes auth (8.2a); the k3s RBAC split, `k3s-creds` and break-glass (8.2c); istiod CA, Istio HelmReleases, STRICT (8.3a–8.3c); CNPG `Cluster` with its `pg_hba`, VSO objects (8.4a–8.4b); `api` policy and role (8.5); the api's Transit client and endpoints (8.7b–8.7c); the mutual-TLS gateway, the client certificate, default deny (8.7d, 8.7g, 8.7h); backup, restore, the scratch-Vault DR, shred (9.1a–9.3a, 9.4) |
| **B — explain what Claude wrote** | Fast-track files (§3.8) | E3 · W1 · D2 | `bootstrap.sh` shim and `lib/` (0); host nftables (2.2); KV/Transit and the bootstrap AppRole (2.5c, 2.5e); Terraform compute (5.4a); WireGuard keys and tunnels (6.2a); the k3s API audit policy (8.2d); postgres's AuthorizationPolicy (8.4c); the DR canary decrypt (9.3b); Corefile (2.3a); Traefik, MinIO, Gitea, runner (2.6–2.10); CloudStack provisioning (3); the console logins (3.5c); Packer (4); Ansible `base`, `k3s`, `frontend` roles; chart mirror (8.1c); images (8.6); kube-prometheus-stack values, dashboards, the `ops` gateway (8.8a–8.8c); `pr.yml`, `deliver.yml`, `schedules.yml` (10); `verify` (12); `teardown`, `destroy` and the revert check (13); the runbook (14.4) |
| **C — explain its role** | Third-party and generated files; what was not built | E2 | the CloudStack packages' own setup scripts (`cloudstack-setup-databases`, `cloudstack-setup-management`); Flux's `gotk-components.yaml`; `config/versions.toml` pins; PLAN §15's not-built rows (directory login, Loki and alerting, CNPG native backups, schema migrations, longevity and hardening) |

Move a file up a tier if your exam format turns out to need it.

### 2.3 Done means

- **A step is done** when its Exit passes, its handoff is written (registry keys, bead closed;
  PLAN §17.3) *and* you have scored its concepts and files (most will be E2/W1–W2 on day one;
  that is normal).
- **A phase is mastered** when every Tier A file in it is W3+, every concept E3+, its fault set
  D3+, each **confirmed on two separate days at least 3 days apart** (7 if the exam date allows).
- **Exam-ready** is the checklist in §6.4.

### 2.4 Catching calibration errors (test, never feel)

- **Predict before every test.** Before a card batch, rebuild or drill, write the level or score
  you expect. After it, write what happened. A gap of 1 level or more = **miscalibrated**; that
  item gets an extra review within 3 days.
- **Confident misses are gold.** A prediction you rated 4–5/5 that turned out wrong goes into the
  log and becomes a card the same day (hypercorrection [18]).
- **Stale scores decay.** A score not re-tested for 30 days shows as `stale` and counts one level
  lower until it is re-tested.
- **Grade yourself first.** You grade against the answer key; then Claude grades. Disagreements
  are logged: they are the calibration errors.
- **Never score "it looked familiar."** Recognition is not recall [1][24].

---

## 3. The session loop

The issue_197 loop (**explain → predict → build → debug → recall**) stays. This version adds a
cold attempt before study, a fading ladder for files, interleaved review, confidence ratings,
fault drills and a delayed rebuild, and puts a cost on "fill it in".

### 3.1 Phases and timings

| # | Phase | 60-min session | 105-min session | You do | Claude may | Claude may not |
|---|---|---|---|---|---|---|
| 1 | **Retrieve** | 5 | 10 | Answer due cards cold, **including ≥ 2 from other phases or issues** (interleaved). Grade yourself, then show Claude. | Ask the cards; grade *after* you grade; turn misses into lapses (§5.4) | Show answers before you answer; give clues |
| 2 | **Cold attempt** | 5 | 10 | Before reading anything, write what you think the step needs: the objects, the order, a sketch of the file, or an answer to one design question. Wrong is fine. | Pose the design question; stay silent while you attempt | Correct the attempt before phase 3 |
| 3 | **Study** | 10 | 15 | Read the step, the linked docs, and a worked example (S0) or the template (S1). Annotate each block in your own words: *what* and *why*. | Explain briefly, tied to the file; point to the source (doc page, `kubectl explain`, an existing file); answer your questions | Recite long explanations you could read yourself; write the file |
| 4 | **Predict** | (in 3) | 5 | 2–3 predictions in the log, each with a confidence 1–5: "applying this gives …"; "if X were wrong, the error would be … at step …". | Give prediction prompts | Answer them, hint at them, or react to them before the run |
| 5 | **Build + check** | 25 | 40 | Write the file at your current fading stage (§3.3). Run the check yourself (dry run, `can-i`, `openssl`, `terraform validate`, the step's Exit). Read the error fully before asking. | Climb the hint ladder only on "next hint" (§3.4); review the file **after** your own check passed or failed | Write code; fix errors unasked; review before you ran your check |
| 6 | **Fault drill** | — | 10 | Diagnose one fault injected into what you just built (§4.6). | Inject one fault into a **scratch copy** and give you only the symptom | Name the fault; touch the real working tree |
| 7 | **Explain** (closed book) | 8 | 10 | Explain what you built as if to the examiner: purpose, mechanism, why this choice, two failure modes. Then compare with the plan. | Grade with the E rubric; ask 1–2 follow-ups; list gaps | Prompt you through it |
| 8 | **Log + cards** | 7 | 5 | Log entry (§7.1): expected / happened / **why**, in your words. Write ≤ 6 new cards (§5). Update the tracker. Schedule the **delayed rebuild** (§3.5). | Write the handoff (§3.2); suggest card *questions* for gaps it saw | Write the *Why* or card answers for you |

Sessions do not have to finish a step. If the build runs over, cut phase 6 first, never phases 1,
7 or 8.

### 3.2 Starting and ending

Every session starts cold, so the build's memory lives outside Claude, in `~/lab-tracker`
(PLAN §17): **beads** (`bd`) hold the step graph, work in progress and each step's closing note;
**`registry.md`** holds the facts later steps need (names, paths, decisions, gotchas), by key.

- **Start:** "Continue `<lab>`. Due cards first." Before phase 1, Claude runs `bd ready` and
  `bd show` on the step (in-progress first), reads that step in the plan, the registry keys its
  handoff **Recalls**, and the closing notes of its **Needs**; an `OPEN` decision stops the session
  until you decide. Then it reads the tracker and the log, asks the due cards, and poses the
  cold-attempt question.
- **End:** Five minutes before time, stop building and do phases 7–8, even if the file is
  unfinished. The closing recall matters more than the last 5 minutes of typing. In phase 8 the
  handoff comes first: step passed → registry keys written, bead closed with its closing note;
  not passed → the bead's WIP block replaced (where it stopped, next action, what you owe). You
  commit `~/lab-tracker`; the registry stays facts, never a diary (that is the log).

### 3.3 The fading ladder (per file)

Each key file climbs one stage per attempt. Attempts on the same file are **days apart**, not
minutes (spacing [8]).

| Stage | What you get | What you do | Pass to move up |
|---|---|---|---|
| **S0 worked example** | A finished file (from Claude, docs or the old `reference/` build) | Trace it: predict what each block does, run it, annotate every line in your words (PRIMM: predict, run, investigate) | You can explain every line (E2 on its concepts) |
| **S1 completion** | Template with the hard parts blanked (the issue_197 style) | Fill the holes; run the check | Check passes, ≤ 3 hints → W1 |
| **S2 skeleton** | Only headings, function signatures or resource names | Write the bodies | Check passes, ≤ 2 hints → W2 |
| **S3 blank page** | Nothing but the step's requirement text | Write it all; official docs allowed | Check passes, ≤ 1 hint → W3 |
| **S4 exam conditions** | The requirement, a timer, exam-allowed references only | Write it within the time budget | Check passes by the 2nd run → W4 |

Skip stages when you can: if your cold attempt (phase 2) already gets most of it right, start at
S2 or S3. Holding on to templates you no longer need slows learning (expertise reversal [15]).

### 3.4 Hint ladder (unchanged rungs, with a rung 0 and limits)

0. **You first:** say what you tried, what you saw, and your current hypothesis. Claude gives no
   hint until it has these.
1. A question that points at the problem ("which SA *makes* the token?").
2. Where to look (a file, a doc page, a `kubectl explain` path, a log).
3. The shape of the answer (field name, not value).
4. The answer, with why.

**Struggle window:** work at least **5 minutes** on a problem before rung 1, and no more than
**15 minutes stuck** without progress before asking (struggle beyond that stops being productive).
Every rung counts as one hint in the W score and in the log.

### 3.5 Delayed rebuild (new)

The day you finish a Tier A file, schedule its next rebuild at the next fading stage for **2–3 days
later**, then 1 week (then 2–4 weeks, if the exam is later than the window; §5.3). A rebuild is a 15–30 min blank-page drill (§7.3) in a
scratch directory, checked by the same Exit. This is what turns "I filled in a template once"
into "I can write it."

### 3.6 The "fill it in" escape hatch (kept, with a cost)

You can always say "fill it in." Before Claude writes it:

1. **Predict:** you write what the code will contain and do (2–3 lines).
2. Claude writes it. You **annotate every line** in your own words.
3. That file's W score for this attempt is capped at **W1**, and a **blank-page rebuild is
   scheduled within 48 hours**.
4. Log it as `FILLED` in the tracker. More than 2 `FILLED` per phase means the steps are too big:
   split them (next letter, new bead; PLAN §9).

In the 3-week plan the fast track (§3.8) uses this hatch by default for plumbing steps.

### 3.7 What changed from the issue_197 loop, and why

| Change | Why |
|---|---|
| **Cold attempt before study** | Pretesting and failed attempts improve what you learn next [17]; for design questions, productive failure helps understanding [19]. |
| **Fading ladder S0–S4 instead of "always from the template"** | Templates are completion problems: great early, harmful once you know the material [13][15]. The exam needs blank-page writing, so the ladder must end there. |
| **Delayed rebuild drills** | The issue_197 loop tested concepts on a spaced schedule but never re-tested *writing*. Spacing and generation apply to procedures too [8][16]. |
| **Interleaved warm-up and weekly mixed review** | The old warm-up only asked the current step's cards (blocked). Mixed review trains choosing *which* idea applies [10][11]. |
| **Confidence ratings + "grade yourself first"** | Feelings of knowing are unreliable [33]; confident errors are the most fixable [18]. |
| **Fault-injection drills** | Debugging is the skill AI use erodes most [32] and a skill that can be taught directly [31]; the lab's own `docs/failure-log.md` says faults show up one layer above their cause. |
| **Per-card lapses, not per-group** | The old rule sent a whole group back to 1 day on any miss: costly, and it grows the daily load until reviews get skipped. |
| **Exam-date-capped intervals** | Fixed 1/3/7/14/30 ignores when the test is; the best gap depends on the delay to the test [9]. |
| **"Fill it in" costs a prediction, annotation, W1 cap and a 48-h rebuild** | Keeps the escape hatch while making sure generation still happens later [36]. |
| **Claude never writes the *Why*** | Earlier log entries were reconstructed by Claude. Generating it yourself is the learning [16]; rewrite those entries in your own words when you next review them. |
| **Closing recall shortened from 15 to 8–10 min, plus next-day retrieval** | Recall straight after study is mostly short-term memory; the delayed retrieval in the next session's warm-up is the real test [1][8]. |
| **Fast track for plumbing (§3.8)** | 90 full loops (143.25 h) do not fit three weeks. Generation is spent where the exam probes; prediction and annotation keep the rest from becoming passive reading [32][36]. |

### 3.8 Fast track (the 3-week default for plumbing)

The full loop runs only on exam-critical steps. Every other required step is **fast-track**:
§3.6's "fill it in" by default.

| Mode | Required steps (PLAN §17.4) | Session | Tier |
|---|---|---|---|
| **Guided** (§3.1), 29 steps | Vault and the three roots 2.4a–2.4b, 2.5a, 2.5b, 2.5d, 2.5f · VPC/VPN 5.2, 5.3a–5.3b, 6.1b, 6.2b · GitOps 8.1b · Vault for the cluster 8.2a · k3s API least privilege 8.2c · mesh 8.3a–8.3c · database (CNPG, VSO) and encryption 8.4a–8.4b, 8.5, 8.7b–8.7c · end-to-end mTLS and default deny 8.7d, 8.7g, 8.7h · backup, restore, DR, crypto-shredding 9.1a–9.3a, 9.4 | S 60 · M 105 min | A |
| **Fast track**, 62 steps | scaffolding and preflight (0–1); host plumbing (2.1a–2.3b, 2.6–2.10); moved from guided by the cut order below: 2.5c, 2.5e, 5.4a, 6.2a, 8.4c, 9.3b; the CloudStack install and the consoles (3); the golden image (4); 5.1, 5.4b, 6.1a; k3s, its API audit log, chart mirror and images (8.1, 8.2d, 8.1c, 8.6a–8.6b); api plumbing, frontend, edge TLS (8.7a, 8.7e–8.7f); monitoring and the Grafana console (8.8a–8.8c); CI wiring (10); `verify` (12); `teardown` and `destroy` (13); the runbook (14.4) | S 35 · M 60 min | B |

A fast-track M session: retrieve (5) → read the step and write what the code will contain and do
(10) → Claude writes it; you annotate every line and run the Exit yourself (35; installs and
pipeline runs overlap with annotating and cards) → explain closed book (5) → log, ≤ 2 cards,
handoff (5). An S session cuts the build phase to 15 min. Unlike §3.6: no 48-hour rebuild, and
`FILLED` does not count toward the split rule. W stays capped at W1; E is scored as usual.

**Behind schedule?** Move guided steps to the fast track in this order (each M saves 45 min, each
S 25): 2.5c, 2.5e, 9.3b, 8.4c, 5.4a, 6.2a, 8.2a, 9.3a, 2.4a, 5.3b, 2.5b, 9.1a. **The first six
are already applied** (3.2 h): adding 8.2c and 8.2d (PLAN, the k3s API split and audit log)
cost 2.3 h and used up the old 2.3 h of slack. The six left save 4.2 h more. Keep 2.5a, 2.5d,
2.5f, 5.3a, 6.2b, 8.1b, 8.2c, 8.3a–8.3c, 8.4a–8.4b, 8.5, 8.7b–8.7d, 8.7g–8.7h, 9.2 and 9.4
guided: they carry the checks an examiner asks about (P2, P5, T3, N2/N6, Z1/Z2, K1, S4,
E1–E3, S3, G4, B1/B2).

---

## 4. Mapping PLAN-enterprise.md onto study units

### 4.1 One study unit per step

For every step of the plan's step index (PLAN §17.4: 90 steps; one step is one session, sized S
or M; e.g. `2.4b`, `5.3a`, `8.5`) build a study unit. A guided step gets all
five parts below (about 15 minutes, done by you at the start of the step, from the plan text); a
fast-track step (§3.8) only the concept list, ≤ 2 cards and the examiner line (5 minutes).
The step's handoff line (`⤷`) feeds the unit: its **Recalls** keys are the first retrieval
questions (facts from earlier phases, so interleaving comes for free), and its **Check** is the
check for the rebuild drill.

| Part | Source in the plan | What to produce | Size |
|---|---|---|---|
| **Concept list** | The step's text, §16 Glossary, §6 Secrets, §10 Rules | Every noun you could not explain cold. Each gets an E score. | 3–8 concepts |
| **Cards** | Concepts, the step's gotchas, its Exit | Cards of the types in §5.1 | ≤ 6 new cards |
| **Rebuild drill** | Each Tier A/B file the step creates | Requirement text (one paragraph, from the plan), the check that proves it, the time budget | 1 per key file |
| **Fault drills** | §10 Rules, §11 Risks, `docs/failure-log.md`, the step's own warnings ("otherwise…", "never…") | 2–4 faults: break → symptom → evidence command → fix | 2–4 per step |
| **Examiner drill** | §12 IDs proved by this step, §13 evidence, §15 alternatives | The 2-min explanation + 3 likely follow-ups | 1 per §12 ID |

### 4.2 Where the earlier issues fit

The lab is the culmination of the JQR issues. Each "Demonstrate/Implement" issue is a hands-on
skill inside a phase; each "Describe" issue is an oral question best answered **with this lab as
the example**. Make 1–3 explain cards per Describe issue, and answer them using the lab.

| Phase | Hands-on issues it re-uses | "Describe" issues to answer with it |
|---|---|---|
| 1–2 Host, control plane | 148/149 (POSIX vs bash, scripts), 152/153 (DNS), 125 (encryption), 115 (version control) | 152 DNS, 157 enterprise layouts, 165/166 OS attacks and mitigations |
| 3–4 CloudStack, golden image | 155 (nested virtualization), 188 (cloud API via CLI) | 145 virtualization, 146 containers and image layers, 185 cloud service models, 187 cloud API protocols |
| 5 Terraform VPC | 178 (IaC), 191 (VPC), 195 (CloudStack provider) | 192 security groups and least privilege, 189 requirements → diagrams |
| 6 Base config + tunnel | 176 (config management), 158 (VPNs, SSH pivots) | 175 config management, 154 overlay networks, 151 routing, 167/168 channel threats |
| 8 Application | 197 (database + encryption), 163 (distributed DB, CRUD), 180 (orchestration), 126/128 (client/server, Python), 169/173 (scanning), 184 (monitoring: 8.8a–8.8c) | 179 orchestration, 159–162/164 distributed systems and databases, 172 security integration, 183/184 monitoring (Prometheus, Grafana, plus the logs: Vault audit, Squid, `lab-hub-drop`, ztunnel denials) |
| 9 Backup/DR | 163, 197 | 161 distributed DB management |
| 10 Pipeline (and 8.1b GitOps) | 182 (CI/CD), 173 (scan in CI) | 181 CI/CD concepts (push pipeline vs Flux's pull), 115 version control |
| Not built (PLAN §15) | — | 165/166 identity side (AppRole, ServiceAccount identities, the directory row of §15); Loki and alerting as the next monitoring step |
| 12–14 Verify, teardown, docs | — | 113 acceptance, 119/120 project management and estimates, 122/136–140 engineering approaches |

### 4.3 Worked example 1 — Phase 2 (control plane): step 2.2 firewall and steps 2.4a–2.5e Vault

In three weeks 2.2, 2.5c and 2.5e are fast-track (§3.8): keep their cards and fault drills, skip
their rebuilds.

**Concepts (E targets):** nftables tables/chains/hooks/priority; `ct state` and `ct status dnat`;
why netavark's published ports are DNAT'd past the input chain into forward; why netavark's
ACCEPT-only FORWARD rules make the lab's table the only default deny, and so why
`lab-platform.service` (which runs `docker-compose up`) `Requires=lab-nftables.service`; Compose
networks: `internal: true`, `ip_range` and fixed `ipv4_address`; drop vs reject
(timeout vs refused); Vault seal/unseal and Shamir shares; Raft storage; audit devices (and why a
full audit disk is an outage); PKI mount TTL tuning; roles vs policies; AppRole
`role_id`/`secret_id`; why the root token is revoked; `lab-bootstrap` vs `lab-pipeline`.

**Sample cards (one of each type):**

| Type | Front | Back (short) |
|---|---|---|
| Concept | What does `fib saddr type local` match? | Packets whose source is one of the host's own addresses (the host talking to itself). |
| Why | Why is the lab's ruleset loaded by its own unit, never via `/etc/nftables.conf`? | That file starts with `flush ruleset`, which would wipe netavark's iptables-nft rules (its NAT and published-port DNAT). |
| Failure mode | Symptom: a host from outside every §5 range gets *connection refused* on 443. What is wrong? | Something is rejecting instead of dropping (or a different listener answered); the plan's rule says drop → timeout. |
| Command | Show whether Vault is sealed, and its storage type. | `vault status` |
| Parsons | Order the forward-chain rules: (a) VMNET source → drop, (b) established/related → accept, (c) everything else dropped by the policy, (d) `ct status dnat` matched by original port and source, (e) Vault's fixed address → be-1 6443 and Gitea's → public 443 accepted | b, d, a, e, c |
| Diagram | Draw from memory: who holds the unseal key, the root token (until when), the `lab-bootstrap` AppRole and the `lab-pipeline` identity, and what each can read. | Compare with §6 of the plan. |

**Rebuild drills:** (1) `nftables-lab.nft` from the plan's 2.2 bullet list, checked by the
network-namespace tests in 2.2's Exit (budget at S4: 30 min). (2) The Vault PKI setup (2.5a) as a
Python function using `lib/vault.py`: mount, tune, CA, roles (then the same for `pki_mesh` and `pki_app`, 2.5f). Check: 2.5a's role refusals,
then 2.5b's `openssl s_client` showing `lab.test CA` (budget: 25 min). (3) The two policy files (2.5d), from the bullet lists. Check: a `lab-pipeline`
token is denied `pki/issue/host-svc`.

**Fault drills:**

| Inject | Symptom you are given | Evidence command |
|---|---|---|
| Load the ruleset through `/etc/nftables.conf`, then `systemctl restart nftables` | Containers lose outbound access and published ports stop answering until they restart | `nft list ruleset \| grep -c NETAVARK` |
| Leave `DNSStubListener` on | CoreDNS container restarts: bind on :53 fails | `ss -lunp 'sport = :53'` |
| Generate the CA before tuning `max_lease_ttl` | Certificates expire after about 32 days | `vault read pki/cert/ca` → check the `NotAfter`, `vault read sys/mounts/pki/tune` |
| `systemctl enable podman-restart.service`, set a service to `restart: always`, break the ruleset file, reboot | That container runs with no firewall table (Traefik's 443 open to the LAN) | `systemctl status lab-nftables lab-platform`, `podman ps` |
| Make the audit log directory read-only | Vault stops answering every request | `vault audit list`, container logs |

**Examiner drill:** P3 ("Vault speaks only TLS"): show `http://` failing and `https://` passing;
explain the trust bootstrap (§6) and why the root token no longer exists. Follow-ups: "Why 1
unseal share?" (lab vs production 5/3 or KMS); "What happens after a reboot?"; "Why not OpenBao?" (§15).

### 4.4 Worked example 2 — Phase 5 (Terraform: VPC, tiers, VMs)

**Concepts:** providers and the lock file; remote state, locking, why S3-compatible backends need
the `skip_*` flags; `plan -json`; CloudStack VPC, tiers, ACL lists (ordered, ingress + egress);
default deny both ways; ConfigDrive and why the default NIC must be the tier (rule 7); the
`ansible_host` inventory resources (rule 8); Conftest/Rego; why apply must be unreachable when
policy fails; least-privilege `iac` account.

**Sample cards:**

| Type | Front | Back (short) |
|---|---|---|
| Why | Why do 5.2 and 5.3a–5.3b merge in one PR? | So no network is ever applied without the policy gate; `setup` applies only once `policy/` exists. |
| Failure mode | `terraform init` against MinIO fails trying to reach AWS STS. Missing what? | `skip_credentials_validation` / `skip_requesting_account_id` (and the other non-AWS flags). |
| Contrast | Ingress vs egress ACL rule for fe-1 → tun-1 UDP 51820: which list holds which? | Egress on tier-frontend's list, ingress on tier-tunnel's list; both are needed. |
| Code completion | `resource "cloudstack_network_acl_rule" "fe" { acl_id = … ; rule { action = "allow"; cidr_list = [____]; protocol = "udp"; ports = [____]; traffic_type = "____" } }` | `["10.0.2.10/32"]`, `["51820"]`, `"egress"` |
| Command | Produce the plan JSON that Conftest reads. | `terraform plan -out=tf.plan && terraform show -json tf.plan > plan.json` |

**Rebuild drills:** `vpc.tf` + `acls.tf` from §5 and 5.2's bullets (S4 budget: 40 min; check:
`terraform validate` and the real plan passes the policy); `policy/*.rego` from 5.3a's bullet list
(S4 budget: 30 min; check: the two fixture plans are rejected, the real plan passes).

**Fault drills:** drop the matching ingress rule (symptom: WireGuard handshake never completes;
evidence: `wg show` latest handshake, ACL list); put the mgmt NIC as the default NIC (symptom: VM
boots without userdata; evidence: `lsblk` shows no `config-2`); a Rego rule that checks the wrong
JSON path (symptom: the `0.0.0.0/0:22` fixture *passes*; evidence: `conftest test --trace`).

**Examiner drill:** N1 and N5 and G1. Follow-ups: "Why not CloudStack's built-in site-to-site
VPN?" (§15); "Where is the state, who can read it, and what stops two applies at once?"

### 4.5 Worked example 3 — Phase 8 (application, database, encryption service)

**Concepts:** k3s flags (`--secrets-encryption`, `--disable=traefik`); GitOps with Flux
(GitRepository, Kustomization `dependsOn`, HelmRelease, pruning, gates for run-time Secrets, why
no Secret is ever in git); Vault Kubernetes auth and TokenReview; token audiences; Istio ambient,
ztunnel, HBONE on 15008, SPIFFE IDs; PeerAuthentication STRICT (required: why every pod hop is
mTLS) and its port-level exception for CNPG's status port; AuthorizationPolicy principals and the
mesh-wide `allow-nothing`; mutual TLS at the gateway (`pki_app`, client vs server auth, why a
separate root); CNPG (`Cluster`, `initdb`, `postInitApplicationSQL`, managed roles); VSO
(`VaultAuth`, `VaultStaticSecret`); Pod Security Admission `restricted`; Transit (`aes256-gcm96`,
key versions, rewrap, `min_decryption_version`); envelope vs field-level encryption;
least-privilege DB role; Kubernetes RBAC (Role vs ClusterRole, `resourceNames` and why `create`
ignores them, `view`), ServiceAccount tokens from TokenRequest and Vault's Kubernetes secrets
engine, break-glass, why `kubectl exec`/`port-forward` bypass the mesh (rule 25), the API
audit policy levels (`None`, `Metadata`, `Request`), CNPG's `pg_hba` order.

The issue_197 `LEARNING_LOG.md` decks A–E already cover much of this; import only what this lab
builds (no cert-manager), don't rewrite.

**Sample cards:**

| Type | Front | Back (short) |
|---|---|---|
| Concept | What does a Transit ciphertext `vault:v2:…` tell you? | Encrypted by Vault's Transit, key version 2; the app never held the key. |
| Why | Why does the api read `kv/app/db` once, but log in to Vault again near its 1-hour expiry? | The DB password is static; the Vault token is short-lived (TTL 1h) and expires. |
| Failure mode | api logs `permission denied` at Vault login. Three things the role checks? | SA name, namespace, audience (and Vault must be allowed to do TokenReviews). |
| Contrast | Z1 vs Z2: which policy object proves each? | Z1: postgres's AuthorizationPolicy and `allow-nothing` (identity). Z2: PeerAuthentication STRICT (no plaintext from outside the mesh). |
| Why | Why does `istiod` never start with its own self-signed root, though Flux installs it? | Kustomization `mesh` `dependsOn` `gate-mesh`, which health-checks Secret `cacerts`; the `mesh` job writes it first. |
| Why | A port-forward to `postgres-1:5432` never meets the postgres `AuthorizationPolicy`. Why, and what stops it instead? | The kubelet dials `localhost` inside the pod's netns, so ztunnel never sees it. RBAC (no one but break-glass may port-forward in `db`), `pg_hba` (no `trust`, `postgres` rejected), and the audit log. |
| Contrast | WireGuard vs the frontend's mTLS: what does tun-1 see under each? | WireGuard alone: tun-1's kernel decrypts it, so plaintext HTTP between the tunnels. With mTLS inside: TLS records only (T3). |
| Parsons | Order: insert row · Transit encrypt · read `kv/app/db` · log in with SA token · return `**** 4242` · decrypt on read | log in → read kv → encrypt → insert → decrypt → mask |
| Diagram | Draw a POST from the LAN browser to Postgres: every hop, who terminates TLS, where the frontend's mTLS starts and ends, which hop is WireGuard, which is HBONE, where plaintext exists (fe-1's loopback, the gateway pod), which identity is checked where. | Compare with PLAN §4, §6 and 8.7d–8.7h. |

**Rebuild drills:** the api's Vault client functions (8.7b: login, encrypt, decrypt, re-login on
403) in Python with `urllib` only (S4 budget: 35 min; check: E1 on a scratch row); the Postgres
`Cluster` (with `postInitApplicationSQL` and managed role) + the VSO objects + the
AuthorizationPolicy (S4 budget: 35 min; check: `kubectl apply --dry-run=server`, then the 8.4a–8.4c
Exits); the Vault `api` policy + `auth/k3s/role/api` (S4 budget: 15 min; check: 8.5's Exit,
including the two denials); the Flux `kustomizations.yaml` with its gates (S4 budget: 20 min;
check: `flux get kustomizations` order on a fresh cluster); the backend gateway's mutual-TLS
listener (S4 budget: 20 min; check: P5).

**Fault drills:** audience mismatch in the role; the api's `VAULT_CACERT` pointing at the wrong CA
(login fails: unknown authority); namespace not
labelled ambient (Z2 passes a plaintext client); AuthorizationPolicy principal missing
`cluster.local/`; the gate missing from `mesh`'s `dependsOn` (istiod creates `istio-ca-secret`: P2
fails); `gitea-auth` with the wrong `ca.crt` (GitRepository: unknown authority); the CNPG status
port left STRICT (the `Cluster` never turns healthy); the VSO role bound to the wrong ServiceAccount
(`app-db` never appears, the `app` role cannot log in); the gateway Secret without `ca.crt`
(any client is accepted: P5 fails); `no_proxy` missing `.svc` (pods send cluster traffic to
Squid); `min_decryption_version` raised before taking a backup (B1 fails after restore); a `lab-ci`
Role missing `cacerts` in its `resourceNames` (the `mesh` job gets 403 on the write: the
audit log names the user and verb); the issuer Role naming the wrong ServiceAccount (Vault's
`k3s-creds/creds/lab-ci` fails with a TokenRequest 403).

**Examiner drill:** T3, P5, E1–E3, S3, T1, T2, Z1 and Z2 (§12) back to back in 5 minutes.
Follow-ups: "Why static DB credentials and not the Vault database engine?" (§15); "Why does the
api read Vault directly but CNPG gets a synced Secret?"; "Pull (Flux) or push (CI `kubectl
apply`): what does each give you?"; "What exactly do you need to restore the data, and what is
safe to lose?" (Phase 9: snapshot + unseal key); "Your mesh is default-deny. Can an operator
with a kubeconfig still read the database?" (rule 25, K1, S4, A1).

### 4.6 Fault-drill protocol (use it every time)

1. **Symptom only.** Claude breaks a scratch copy (git worktree, a throwaway VM or namespace) and
   tells you only what a user would see.
2. **Predict the layer** (and your confidence) before touching anything: DNS, firewall, routing,
   TLS/trust, identity/auth, policy, config, process/health.
3. **Gather evidence** from the bottom up, one command per hypothesis. Write each command and what
   it showed.
4. **Fix, then prove it** with the step's own check.
5. **Explain the propagation:** why the fault surfaced where it did. (The failure log's lesson: a
   fault in one layer looks like a bug in every layer above it.)
6. Log it with §7.4. Any fault that took > 15 min becomes a failure-mode card.

---

## 5. Spaced repetition system

### 5.1 Card types

| Type | Tests | Good for | Example |
|---|---|---|---|
| **Concept** | What is it, in one or two lines | Glossary terms | "What is HBONE?" |
| **Why** | Reason for a design choice | §2 Principles, §15 Decisions | "Why two roots and not one?" |
| **Failure mode** | Symptom → cause, or cause → symptom | §10 Rules, the failure log | "Timeout vs refused: what does each tell you?" |
| **Contrast** | Two confusable things side by side | Interleaving [11] | "PeerAuthentication vs AuthorizationPolicy: what does each decide?" |
| **Command** | Write the exact command | Exam-time recall | "Save a Raft snapshot." |
| **Code completion / Parsons** | Fill blanks, or order shuffled lines | Config blocks, code [30] | §4.3–4.5 |
| **Diagram** | Draw from memory, then compare | Architecture, trust, request paths | "Draw the trust chain from a workload cert to `lab.test CA`." |

**Rules for good cards:** one idea per card; answer in ≤ 2 lines (or one diagram); your words, not
copied text; a `why` or failure-mode card for every *what* card that matters; cards are made from
**your misses**, not from everything you read.

### 5.2 How many

- **≤ 4 new cards per guided step, ≤ 2 per fast-track step, ≤ 12 new cards per day.** 29 guided and
  62 fast-track steps allow about 116 + 124 ≈ 240 cards, but the daily cap holds 18 build days to
  about 215: write cards from misses first. Plus the issue_197 decks (import only what Phases 8–9
  need). By week 3 that is about 35–45 reviews a day (20 min).
- **Daily review cap: 20 minutes.** If you are over it for 3 days, stop adding cards until you
  are back under. A deck you can't keep up with gets abandoned.

### 5.3 Schedule (tied to the exam date)

**Without software (Markdown, like `LEARNING_LOG.md`):** intervals are **per card**:
`1 → 3 → 7 → 14 days` (30 and 60 only if the exam is months away).

- **Exam cap:** a card's next interval is never longer than **(days to exam) ÷ 3**, so every card
  gets at least 2–3 more reviews before the exam: in a 21-day window, a day-1 card comes back
  about days 2, 5 and 12, then in the final pass. This follows the finding that the best gap is
  a fraction of the time to the test [9].
- **Final pass:** every card is reviewed at least once in the **last 5 days** before the exam.
- Keep cards in one file per lab: `study/CARDS.md`, with a `due:` date and `box:` on each card.
  Sort by `due` at the start of each session.

**With Anki (optional: a ~200-card Markdown deck is manageable in three weeks):** turn on **FSRS** (Anki ≥ 23.10;
it is opt-in, not the default) with desired retention **0.90**, new cards/day 10, maximum
reviews/day 150. FSRS models each card's memory and schedules it to hit the target retention with
fewer reviews than the older SM-2 default [38]. Code and diagram cards still work: put the code
in the back, and for diagrams draw on paper first, then flip.

**Rebuild drills follow the same ladder** but slower, Tier A only: 2–3 days → 1 week (→ 2–4 weeks
if the exam is later), under the same exam cap.

### 5.4 Missed cards

| Situation | Action |
|---|---|
| Missed once | That **card** (not its group) goes back to 1 day. Read the answer, then explain it out loud once. |
| Missed with confidence 4–5 | Same, plus a log line: what you believed and why it was wrong. |
| Missed 3 times ("leech") | The card is bad or the concept is not understood. Rewrite it smaller, add a *why* card, or go back to the source for 10 min. |
| Right 3 times in a row at ≥ 30 days | Retire it to a **monthly sample** pool (10 random retired cards per month). |

---

## 6. Weekly and pre-exam cadence

### 6.1 A normal week

| Day | Session |
|---|---|
| Mon–Sat | About **6 h of sessions**: the next steps `bd ready` offers, guided or fast-track (§3.8), e.g. two guided and two fast-track M sessions, 10-min breaks between them |
| Sun | **Interleaved review** (2 h): 20 min mixed cards from all phases and issues; 1 blank-page rebuild (S3) of a Tier A file from the week; 2 fault drills from *different* layers; 3 random §12 IDs explained to the examiner (2 min each). No build |
| Daily | Due cards ≤ 20 min, at a different time from the build sessions |

**What the build costs** (PLAN §17.4, at the §3.8 session lengths):

| Mode | Steps | Sessions | Hours |
|---|---|---|---|
| Guided | 29 | 26 M + 3 S | 48.5 |
| Fast track | 62 | 45 M + 17 S | 54.9 |
| **All steps** | **91** | **91** | **103.4** |

At the default 6 h × 6 days, three weeks hold 108 h of sessions: the build fits with **4.6 h of
slack** (it was 15 h before GitOps, CNPG/VSO, end-to-end mTLS, monitoring and the consoles were
added, and 2.3 h before the k3s API split and audit log, 8.2c–8.2d, which cost 2.3 h; the first
six §3.8 cuts, already applied, bought back 3.2 h; the netavark spike and the host telemetry
stores, 2.1c and 2.7b, cost 1.6 h; removing the unit tests and `demo`, 0.2c, 12.2 and 12.3,
gave back 3.0 h on 2026-11-10). Mocks 1 and 2 take about 1.5 h of it, so
CloudStack, image or pipeline waits a session cannot absorb have about 3.1 h of buffer. The rest
of the §3.8 cut order gives back 4.2 h more. It does **not** fit at 4 h/day: fast-track
everything (91 sessions ≈ 83 h ≈ 4.6 h/day, still over).

### 6.2 Rebuild blocks

No monthly rebuild day fits in three weeks. The two Sunday reviews and the D19 drill block (§6.3)
rebuild that week's Tier A files from a blank page, timed, and run their Exits: week 1 the PKI
roots, roles and policies (2.5a, 2.5f, 2.5d); week 2 the ACLs and Rego (5.2, 5.3a), the hub's
forward chain (6.2b) and the Flux `kustomizations.yaml` with its gates (8.1b); D21 the Phase 8–9
files (the CNPG `Cluster`, the gateway's mTLS listener, the api's Vault client). Anything below W3
goes back into the next block.

### 6.3 The three weeks

| Days | Build (PLAN §17.4) | Hours | Review and mocks |
|---|---|---|---|
| **Week 1**, D1–D6 | Phases 0–3: scaffolding, preflight, the control plane (Vault and the three roots guided), CloudStack, the consoles, the hand-off to `deliver` | 35.7 | D7: Sunday review; rebuild 2.5a/2.5f and 2.5d at S3 |
| **Week 2**, D8–D13 | Phases 4–6 and 8.1–8.6b: image, VPC and policy gate, base and tunnel, k3s, Flux and the chart mirror, the k3s API split and audit log (8.2c guided, 8.2d fast), mesh (STRICT mTLS), CNPG and VSO, Vault for the api, images | 36.4 | D14: Sunday review; rebuild 5.2/5.3a, 6.2b and 8.1b at S3; **Mock 0**: N1–N3 and N6 (§12) explained from memory, with the command that proves each |
| **Week 3**, D15–D19 | 8.7a–8.8c, Phases 9, 10 and 12: the app end to end with mutual TLS and default deny, monitoring and Grafana, backup/DR/shred, pipeline gates, `verify` (12.1a–12.1f); on D19 also 14.4 (`docs/runbook.md`, linking one green `deliver.yml` run and one `up` local-stage output) | 28.3 | daily: 2 mixed fault drills from different layers (inside the session time); D19 end: **Mock 1**, the evidence from memory (13 min): each check of a green `verify` job by §12 ID, then the DR drill in `up`'s local stage (B3, B2); then 20 min of examiner questions from §12 and §15 |
| D20 | 13.1a–13.2: the final `destroy` (teardown rows, host restore, reboot), then `destroy` again for the revert checks V1–V5 (R4) | 3.0 | before the `destroy`, **Mock 2 with faults**: Claude breaks 3 things in the built lab; you find and fix them while you explain the evidence. Card final pass |
| D21 | review, or the exam | — | 2 h: rebuild the Phase 8–9 Tier A files at S3; every "Describe" issue in 2 min each; 30 min of cards; nothing new, early night. If the exam needs the lab live, start `up` after D20's second `destroy` (the revert check): it runs unattended for hours |

Week 1 ends 0.3 h early, so 4.1a starts on D6 and week 2's 36.4 h about fits its 36 h. D15–D19
hold 28.3 h of build in 30 h, so D20 holds only its own 3.0 h of build plus Mock 2;
with Mock 1 that leaves about 3.1 h to spare in the whole window. Behind by more than half a day at the end of
a week: apply the §3.8 cut order before touching the reviews. A **Mock 3** under full
exam conditions (time limit, allowed references only, no Claude) only if the exam is after D21.

### 6.4 Readiness checklist (all must pass, measured, within the last 7 days)

| Area | Pass threshold |
|---|---|
| Cards | ≥ 90% correct on a **cold mixed sample of 40** cards across all phases and issues |
| Writing | Every Tier A file **W3** at least once, the last time ≥ 2 days after you built it; every Tier B file E3 (each annotated line explained) |
| Debugging | ≥ 8 of 10 random mixed fault drills in guided areas diagnosed in ≤ 15 min each, with the evidence named |
| Explaining | Every R1–R7 §12 check ID explained at E3+ (incl. T3, P5, S3, S4, K1, A1, G4, O1–O3, C1); every §16 glossary term in one sentence, no misses |
| Evidence | §13 explained twice in ≤ 15 min with no notes: a green `deliver.yml` run's `verify` checks by §12 ID and the DR drill in `up`'s local stage; ≥ 10 of 12 unseen follow-up questions answered at E3 |
| GitOps and mTLS | From a blank page: the Flux Kustomization chain with its gates, and the gateway's mutual-TLS listener; explain why tun-1 sees only ciphertext and why istiod cannot start before `cacerts` |
| Describe issues | Every "Describe" JQR item answered in ≤ 2 min at E3, using this lab as the example |
| Calibration | Mean gap between predicted and actual level ≤ 0.5 over the last 15 tests |
| From the build | Every step closed in beads; each of the five consoles logged in to once from the host (runbook); `up` with its local-stage DR drill → `destroy` → `destroy` again after the reboot (the revert check) run once, with every phase, local-stage check and teardown row explained as it ran |

If an area fails, the D19–D21 review time targets only that area.

---

## 7. Artifacts

Suggested home: a `study/` directory in the lab (`study/LEARNING_LOG.md`, `study/CARDS.md`,
`study/TRACKER.md`, `study/drills/`). Keep each entry short; a log nobody writes is worse than a
short one. Build state is kept apart, in `~/lab-tracker` (beads and `registry.md`, PLAN §17): the
log is what *you* learned; the registry is what later *steps* need.

### 7.1 Learning-log entry

```
### YYYY-MM-DD — step X.Y — <topic> — 35|60|105 min
Cold attempt:  <what I thought the step needed, 1–3 lines>
Predicted:     1. … (conf 1–5)   2. … (conf)   3. … (conf)
Happened:      …
Why (my words): …
Hints used:    n (rungs: …)   FILLED: yes/no
Explain score: E_ (self) / E_ (Claude)   Gaps: …
New cards:     <ids>       Rebuild scheduled: <file> on YYYY-MM-DD at S_
Handoff:       bead closed | WIP noted    Registry keys: <keys written>
```

### 7.2 Recall card (Markdown version)

```
**P8-07** (why) — box 2 — due 2026-11-09 — misses 0
Why does the api re-login on a 403, not only near expiry?
<details><summary>answer</summary>A token can be revoked or its policy changed before its TTL ends;
a 403 is the first sign, so re-login once, then fail loudly.</details>
```

### 7.3 Blank-page rebuild drill record

```
### Rebuild — <file> — YYYY-MM-DD — stage S3|S4
Requirement (from the plan, not the old file): …
Allowed references: …        Budget: __ min      Predicted result: pass/fail, __ min
Actual: __ min    Check: <command> → pass/fail (run #__)    Hints: __
Diff vs reference — what I missed or got wrong:
  - …
Score: W_   Next rebuild: YYYY-MM-DD at S_
```

### 7.4 Fault-injection drill record

```
### Fault — <area> — YYYY-MM-DD
Symptom given: …
Predicted layer: … (conf 1–5)
Evidence (command → what it showed):
  1. … → …
  2. … → …
Root cause: …          Fix: …          Proved by: …
Why it surfaced there: …
Time: __ min   Hints: __   Score: D_   New card: yes/no
```

### 7.5 Phase mastery checklist

```
## Phase N — <name>                         confirmed day 1: ____  day 2 (≥7 days later): ____
Concepts (target E3+):   [ ] c1 E_  [ ] c2 E_  [ ] c3 E_ …
Tier A files (W3+/W4):   [ ] file1 W_  [ ] file2 W_ …
Tier B files (W3):       [ ] file3 W_ …
Fault set (D3+):         [ ] f1 D_  [ ] f2 D_  [ ] f3 D_ …
§12 IDs explained (E3+): [ ] ID1  [ ] ID2 …
Related Describe issues answered: [ ] #___  [ ] #___
```

### 7.6 Progress tracker

```
| Item (concept/file) | Phase | Tier | E | W | D | Stage | Last tested | Next due | Pred→Act | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| nftables-lab.nft | 2.2 | A | 3 | 2 | 2 | S3 | 2026-11-10 | 2026-11-17 | 3→2 | missed ct status dnat |
| Vault Transit    | 8.5 | A | 2 | 1 | – | S1 | 2026-11-12 | 2026-11-14 | 2→2 | FILLED once |
```

`Pred→Act` holds the last predicted vs actual level; a gap of 1 or more marks it for review within
3 days (§2.4).

---

## 8. Using Claude well

### 8.1 What the research says, briefly

- **Unguarded help harms unaided performance.** In a field experiment with about 1,000 students,
  plain GPT-4 access raised practice scores but lowered exam scores by 17% once access was removed;
  a tutor version that gave only incremental hints did not cause that harm [36].
- **Coding specifically:** in a 2026 randomized trial, developers learning a new library with AI
  scored 50% vs 67% on a follow-up quiz, with the biggest gap on debugging. The speed gain was not
  significant. Users who asked **conceptual questions**, or **generated code and then asked for
  explanations**, kept their learning; those who delegated or let the AI debug for them did worst
  [32]. Small sample (52) and short horizon.
- **Novices and metacognition:** students already weak at monitoring their own understanding got
  *worse* with AI help ("the widening gap"), partly through a false sense of progress [39].
  Learners may offload monitoring itself to the tool ("metacognitive laziness") [40]. Knowledge
  workers who trusted the AI more thought less critically; those confident in their own skill
  thought more [41].
- **It can also help.** A carefully designed AI tutor doubled learning gains compared with an
  active-learning class [37]; novices with an AI code generator in a structured course did not lose
  retention a week later [42]. The design of the use decides the outcome.
- **Weak evidence, don't over-read:** EEG studies of "cognitive debt" from essay writing with
  ChatGPT are small preprints [43].

The rule that follows: **you generate, Claude checks and asks.** Use Claude for questions, hints,
review after your own check, quizzing and fault injection; avoid it as the author of your code.

### 8.2 Rules for the learner

1. Attempt first, always: cold attempt, prediction, your own check, rung 0 of the hint ladder.
2. Ask for the *next hint*, not the answer. Count every hint.
3. Ask "why" and "what would break if…", not "write this."
4. Grade yourself before Claude grades you.
5. After any "fill it in", annotate every line and rebuild from blank within 48 hours.
6. Once a week, do a whole session with **no Claude at all** (the Sunday review works well).
7. If you notice you are pasting errors in without reading them, stop and read for 2 minutes first.

### 8.3 Rules for Claude (paste into the lab's session start, or a CLAUDE.md, if you want them enforced)

- Default to **tutor mode**: explain briefly, point to the source, ask questions. Do not write
  code, config, log entries, card answers or *Why* lines unless the learner says "fill it in."
- **Never** answer, hint at or react to a prediction before the learner has run the check.
- Hints only on "next hint", one rung at a time; ask for rung 0 (tried / saw / hypothesis) first.
- Review a file only **after** the learner's own check, and point at the line or area, not the fix.
- On "fill it in": first ask for the learner's prediction; afterwards ask them to annotate; record
  `FILLED` and schedule the 48-hour rebuild.
- Grade with the E/W/D rubric in §2 and say which criterion was missed. Never inflate a score.
- Fault injection: only in a scratch copy (worktree, scratch VM or namespace); give the symptom
  only; never edit the real working tree; never commit; confirm before deleting anything.
- Keep the session clock: call time for phases 7–8 five minutes before the end.
- **Session start:** before teaching, run `bd ready` / `bd show`, read the step in the plan, the
  registry keys its handoff Recalls and the closing notes of its Needs (PLAN §17.3). Read nothing
  older; a missing key is found through the step that Records it. An `OPEN` decision: stop and ask.
- **Session end:** write the handoff before the log: Records keys (overwrite, never append),
  then close the bead with its closing note (≤ 5 lines), or replace its WIP block (≤ 6 lines).
  Facts only: no narrative, no secret values. Never commit `~/lab-tracker`; the learner does.
- **Fast-track steps (STUDY-PLAN §3.8):** once the learner has written the prediction, write the
  step's code without waiting for "fill it in"; then ask for line annotations and record `FILLED`.
  Still never the *Why* lines or card answers.
- The learner can opt out of tutor mode for a single task by saying so; respect it.

### 8.4 Prompt cheat sheet

| You want | Say |
|---|---|
| Start a session | "Continue `<lab>`. `bd ready`, the step's recalls, due cards, then a cold-attempt question." |
| End a session | "Close out: handoff (registry keys, closing note or WIP block), then log and cards." |
| Be quizzed | "Quiz me on Phase 8: 10 mixed cards, one at a time, grade after I self-grade." |
| An interleaved quiz | "Mixed quiz: 2 cards each from phases 2, 5, 6, 8 and one Describe issue." |
| A design problem first | "Give me the design question for this step; don't comment until I've answered." |
| Prediction prompts | "Give me 3 prediction prompts for this file. Don't answer them." |
| A hint | "Next hint." (after rung 0: "I tried …, I saw …, I think …") |
| A review | "My dry run passed/failed with: … Review the file now; point at problems, don't fix them." |
| Code written for you | "Fill it in — I predict it will … " |
| A fault drill | "Break one thing in a scratch copy of `<file or area>`; give me the symptom only." |
| An examiner | "Be the examiner for §12 IDs E1–E3. Ask follow-ups from §15. Grade with E-levels." |
| A rebuild drill | "Rebuild drill: give me only the requirement for `<file>` from the plan, start a 30-min timer, stay silent." |
| Check your explanation | "I'll explain HBONE in 2 minutes. Afterwards list what I missed against the E3 criteria." |
| Turn gaps into cards | "From today's gaps, suggest card questions only. I'll write the answers." |

---

## 9. References

Learning techniques (general)

1. Dunlosky, J., Rawson, K. A., Marsh, E. J., Nathan, M. J., & Willingham, D. T. (2013). Improving students' learning with effective learning techniques. *Psychological Science in the Public Interest*, 14(1), 4–58. https://doi.org/10.1177/1529100612453266
2. Roediger, H. L., & Karpicke, J. D. (2006). Test-enhanced learning: Taking memory tests improves long-term retention. *Psychological Science*, 17(3), 249–255. https://doi.org/10.1111/j.1467-9280.2006.01693.x
3. Karpicke, J. D., & Roediger, H. L. (2008). The critical importance of retrieval for learning. *Science*, 319(5865), 966–968. https://doi.org/10.1126/science.1152408
4. Adesope, O. O., Trevisan, D. A., & Sundararajan, N. (2017). Rethinking the use of tests: A meta-analysis of practice testing. *Review of Educational Research*, 87(3), 659–701. https://doi.org/10.3102/0034654316689306
5. Yang, C., Luo, L., Vadillo, M. A., Yu, R., & Shanks, D. R. (2021). Testing (quizzing) boosts classroom learning: A systematic and meta-analytic review. *Psychological Bulletin*, 147(4), 399–435. https://doi.org/10.1037/bul0000309
6. van Gog, T., & Sweller, J. (2015). Not new, but nearly forgotten: The testing effect decreases or even disappears as the complexity of learning materials increases. *Educational Psychology Review*, 27, 247–264. https://repub.eur.nl/pub/92178
7. Karpicke, J. D., & Aue, W. R. (2015). The testing effect is alive and well with complex materials. *Educational Psychology Review*, 27, 317–326. https://doi.org/10.1007/s10648-015-9309-3
8. Cepeda, N. J., Pashler, H., Vul, E., Wixted, J. T., & Rohrer, D. (2006). Distributed practice in verbal recall tasks: A review and quantitative synthesis. *Psychological Bulletin*, 132(3), 354–380. https://doi.org/10.1037/0033-2909.132.3.354
9. Cepeda, N. J., Vul, E., Rohrer, D., Wixted, J. T., & Pashler, H. (2008). Spacing effects in learning: A temporal ridgeline of optimal retention. *Psychological Science*, 19(11), 1095–1102. https://pubmed.ncbi.nlm.nih.gov/19076480/ (full text: https://www.evullab.org/pdf/CepedaVulRohrerWixtedPashler-PS-2008.pdf)
10. Rohrer, D., & Taylor, K. (2007). The shuffling of mathematics problems improves learning. *Instructional Science*, 35, 481–498. https://doi.org/10.1007/s11251-007-9015-8
11. Brunmair, M., & Richter, T. (2019). Similarity matters: A meta-analysis of interleaved learning and its moderators. *Psychological Bulletin*, 145(11), 1029–1052. https://doi.org/10.1037/bul0000209 (preprint: https://www.psychologie.uni-wuerzburg.de/fileadmin/06020400/2019/Brunmair_Richter_in_press__2019_META-ANALYSIS_OF_INTERLEAVED_LEARNING.pdf)
12. Sweller, J., & Cooper, G. A. (1985). The use of worked examples as a substitute for problem solving in learning algebra. *Cognition and Instruction*, 2(1), 59–89. https://doi.org/10.1207/s1532690xci0201_3
13. Renkl, A., & Atkinson, R. K. (2003). Structuring the transition from example study to problem solving in cognitive skill acquisition: A cognitive load perspective. *Educational Psychologist*, 38(1), 15–22. https://doi.org/10.1207/S15326985EP3801_3
14. Kirschner, P. A., Sweller, J., & Clark, R. E. (2006). Why minimal guidance during instruction does not work. *Educational Psychologist*, 41(2), 75–86. https://doi.org/10.1207/s15326985ep4102_1
15. Kalyuga, S., Ayres, P., Chandler, P., & Sweller, J. (2003). The expertise reversal effect. *Educational Psychologist*, 38(1), 23–31. https://doi.org/10.1207/S15326985EP3801_4 (repository: https://ro.uow.edu.au/edupapers/136)
16. Bertsch, S., Pesta, B. J., Wiscott, R., & McDaniel, M. A. (2007). The generation effect: A meta-analytic review. *Memory & Cognition*, 35(2), 201–210. https://doi.org/10.3758/BF03193441
17. Kornell, N., Hays, M. J., & Bjork, R. A. (2009). Unsuccessful retrieval attempts enhance subsequent learning. *JEP: Learning, Memory, and Cognition*, 35(4), 989–998. https://doi.org/10.1037/a0015729
18. Metcalfe, J. (2017). Learning from errors. *Annual Review of Psychology*, 68, 465–489. https://doi.org/10.1146/annurev-psych-010416-044022 ; see also Butterfield, B., & Metcalfe, J. (2001). Errors committed with high confidence are hypercorrected. *JEP: LMC*, 27(6), 1491–1494. https://doi.org/10.1037/0278-7393.27.6.1491
19. Sinha, T., & Kapur, M. (2021). When problem solving followed by instruction works: Evidence for productive failure. *Review of Educational Research*, 91(5), 761–798. https://doi.org/10.3102/00346543211019105
20. Kapur, M. (2008). Productive failure. *Cognition and Instruction*, 26(3), 379–424. https://doi.org/10.1080/07370000802212669
21. Bisra, K., Liu, Q., Nesbit, J. C., Salimi, F., & Winne, P. H. (2018). Inducing self-explanation: A meta-analysis. *Educational Psychology Review*, 30, 703–725. https://doi.org/10.1007/s10648-018-9434-x
22. Chi, M. T. H., de Leeuw, N., Chiu, M.-H., & LaVancher, C. (1994). Eliciting self-explanations improves understanding. *Cognitive Science*, 18(3), 439–477. https://doi.org/10.1207/s15516709cog1803_3
23. Kobayashi, K. (2019). Learning by preparing-to-teach and teaching: A meta-analysis. *Japanese Psychological Research*, 61(3), 192–203. https://doi.org/10.1111/jpr.12221
24. Rozenblit, L., & Keil, F. (2002). The misunderstood limits of folk science: An illusion of explanatory depth. *Cognitive Science*, 26(5), 521–562. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3062901/
25. Ericsson, K. A., Krampe, R. T., & Tesch-Römer, C. (1993). The role of deliberate practice in the acquisition of expert performance. *Psychological Review*, 100(3), 363–406. https://doi.org/10.1037/0033-295X.100.3.363
26. Macnamara, B. N., Hambrick, D. Z., & Oswald, F. L. (2014). Deliberate practice and performance in music, games, sports, education, and professions: A meta-analysis. *Psychological Science*, 25(8), 1608–1618. https://doi.org/10.1177/0956797614535810
44. Bjork, E. L., & Bjork, R. A. (2011). Making things hard on yourself, but in a good way: Creating desirable difficulties to enhance learning. In *Psychology and the Real World* (pp. 56–64). Worth. https://bjorklab.psych.ucla.edu/wp-content/uploads/sites/13/2016/04/EBjork_RBjork_2011.pdf (background to the "desirable difficulties" behind §3)
45. Pashler, H., et al. (2007). *Organizing Instruction and Study to Improve Student Learning* (IES Practice Guide NCER 2007-2004). https://ies.ed.gov/ncee/WWC/Docs/PracticeGuide/20072004.pdf (spacing, quizzing, worked examples, deep questions)

Learning to program

27. Lister, R., et al. (2004). A multi-national study of reading and tracing skills in novice programmers. *ACM SIGCSE Bulletin*, 36(4), 119–150. https://opus.lib.uts.edu.au/handle/10453/4126
28. Lopez, M., Whalley, J., Robbins, P., & Lister, R. (2008). Relationships between reading, tracing and writing skills in introductory programming. *ICER '08*, 101–112. https://opus.lib.uts.edu.au/handle/10453/10806
29. Sentance, S., Waite, J., & Kallia, M. (2019). Teaching computer programming with PRIMM: A sociocultural perspective. *Computer Science Education*, 29(2–3), 136–176. https://doi.org/10.1080/08993408.2019.1608781
30. Ericson, B. J., Margulieux, L. E., & Rick, J. (2017). Solving Parsons problems versus fixing and writing code. *Koli Calling '17*, 20–29. (Summary of findings: https://hg.gatech.edu/node/603172)
31. Michaeli, T., & Romeike, R. (2019). Improving debugging skills in the classroom: The effects of teaching a systematic debugging process. *WiPSCE '19*. https://computingeducation.de/pub/2019_Michaeli-Romeike_WIPSCE19.pdf

AI assistants and learning

32. Shen, J. H., & Tamkin, A. (2026). How AI impacts skill formation. arXiv:2601.20245. https://arxiv.org/abs/2601.20245 ; summary: https://www.anthropic.com/research/AI-assistance-coding-skills
36. Bastani, H., Bastani, O., Sungu, A., Ge, H., Kabakcı, Ö., & Mariman, R. (2025). Generative AI without guardrails can harm learning: Evidence from high school mathematics. *PNAS*, 122(26), e2422633122. https://doi.org/10.1073/pnas.2422633122
37. Kestin, G., Miller, K., Klales, A., Milbourne, T., & Ponti, G. (2025). AI tutoring outperforms in-class active learning: An RCT introducing a novel research-based design in an authentic educational setting. *Scientific Reports*, 15, 17458. https://pmc.ncbi.nlm.nih.gov/articles/PMC12179260/
39. Prather, J., et al. (2024). The widening gap: The benefits and harms of generative AI for novice programmers. *ICER '24*. https://arxiv.org/abs/2405.17739
40. Fan, Y., et al. (2024). Beware of metacognitive laziness: Effects of generative artificial intelligence on learning motivation, processes, and performance. *British Journal of Educational Technology*, 56(2), 489–530. https://arxiv.org/abs/2412.09315
41. Lee, H.-P., Sarkar, A., Tankelevitch, L., Drosos, I., Rintel, S., Banks, R., & Wilson, N. (2025). The impact of generative AI on critical thinking. *CHI '25*. https://doi.org/10.1145/3706598.3713778
42. Kazemitabaar, M., et al. (2023). Studying the effect of AI code generators on supporting novice learners in introductory programming. *CHI '23*. https://arxiv.org/abs/2302.07427
43. Kosmyna, N., et al. (2025). Your brain on ChatGPT: Accumulation of cognitive debt when using an AI assistant for essay writing task. arXiv:2506.08872 (preprint). https://arxiv.org/abs/2506.08872
46. Koedinger, K. R., & Aleven, V. (2007). Exploring the assistance dilemma in experiments with cognitive tutors. *Educational Psychology Review*, 19, 239–264. https://doi.org/10.1007/s10648-007-9049-0 (how much help to give vs withhold: the basis for the hint ladder and struggle window)

Spacing software, metacognition, sleep

38. Ye, J., Su, J., & Cao, Y. (2022). A stochastic shortest path algorithm for optimizing spaced repetition scheduling. *KDD '22*, 4381–4390. https://doi.org/10.1145/3534678.3539081 ; FSRS project: https://github.com/open-spaced-repetition/fsrs4anki/wiki/abc-of-fsrs
33. Dunlosky, J., & Rawson, K. A. (2012). Overconfidence produces underachievement: Inaccurate self evaluations undermine students' learning and retention. *Learning and Instruction*, 22(4), 271–280. https://doi.org/10.1016/j.learninstruc.2011.08.003
34. Diekelmann, S., & Born, J. (2010). The memory function of sleep. *Nature Reviews Neuroscience*, 11, 114–126. https://doi.org/10.1038/nrn2762
35. Okano, K., Kaczmarzyk, J. R., Dave, N., Gabrieli, J. D. E., & Grossman, J. C. (2019). Sleep quality, duration, and consistency are associated with better academic performance in college students. *npj Science of Learning*, 4, 16. https://pmc.ncbi.nlm.nih.gov/articles/PMC6773696/

*Reference numbers are stable IDs used in the text, not a reading order. Every DOI above was
checked to resolve (2026-11-02); several papers are paywalled, so their effect sizes come from
abstracts and reviews rather than the full text. The 2026 AI-coding trial [32] and the Kosmyna
preprint [43] are recent and not yet (or not fully) peer reviewed. The Parsons-problem paper [30]
is cited through a summary because its DOI could not be confirmed.*
