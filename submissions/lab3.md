# Lab 3 — CI/CD

**Chosen path: GitHub Actions.**

---

## Pipeline design

`on: push` to `main` and every `pull_request` targeting `main`. Top-level `permissions: contents: read`. Five jobs:

- `changes` — a path-filter job (`dorny/paths-filter`) that decides whether `app/**` or the workflow itself changed.
- `vet` — `go vet ./...` in `app/`, on a `1.23` + `1.24` matrix, `fail-fast: false`.
- `test` — `go test -race -count=1 ./...` in `app/`, same matrix.
- `lint` — `golangci-lint run` in `app/`, linter pinned to `v2.5.0`.
- `ci-ok` — aggregation gate (`if: always()`, `needs: [changes, vet, test, lint]`); **the only required check** in branch protection.

`vet`/`test`/`lint` are gated on `needs.changes.outputs.app == 'true'`, so a docs-only PR skips the heavy work but `ci-ok` still reports (see §2.3 for why this matters).

---

## Task 1

### 1.2 Design questions

**a) Why pin `ubuntu-24.04` instead of `ubuntu-latest`?**
`ubuntu-latest` is a moving alias that GitHub repoints to the next LTS on their schedule (it has walked 20.04 → 22.04 → 24.04 and will move to 26.04). When it moves, the preinstalled tool versions, default packages, and kernel change overnight, so a pipeline that was green yesterday can break today with no change to my code. Pinning `ubuntu-24.04` turns the runner into an explicit dependency that only changes when I bump it in a commit — a reviewable diff I can test in a PR instead of a surprise. The trade-off is that I own upgrading it before GitHub retires the image, but that's a scheduled action rather than an outage.

**b) Why split vet + test + lint into separate units?**
Three reasons. *Parallelism* — they run on separate runners simultaneously, so wall-clock is the slowest one, not the sum. *Signal* — when the check list shows a red `test` next to a green `vet`/`lint`, I know exactly which dimension broke without opening logs. *Isolation* — a `go vet` failure doesn't stop the tests from also telling me whether there's a logic regression, so I get the whole picture in one run. One combined job would run them serially, the first failure would mask everything after it, and I'd lose the parallelism.

**c) What real attack does SHA pinning prevent? (incident from Lecture 3)**
The **tj-actions/changed-files supply-chain compromise of March 2025** (~March 14). An attacker gained write access and force-updated the action's existing version tags to point at a malicious commit that dumped CI runner memory — including secrets like `GITHUB_TOKEN` — into the publicly readable build logs. Every workflow referencing the action by a *tag* (`@v45`) silently ran the malicious code on its next run, because a tag is just a movable pointer. A 40-char commit SHA is immutable — it names one exact commit — so a moved or re-pushed tag can't change what my workflow executes.

**d) What is `permissions:` and what's the principle?**
`permissions:` sets the scopes granted to the automatic `GITHUB_TOKEN` for the run (contents, packages, pull-requests, id-token, …). The principle is **least privilege**: a job holds only the permissions it actually needs. Declaring `contents: read` at the top makes every job read-only, so a compromised step or action can't push commits, cut releases, publish packages, or open PRs with my token. When Lab 10 needs to push an image to GHCR I'll grant `packages: write` to *just that job*, not the whole workflow.

**e) GitLab: stage vs job, and what `dependencies:` does that `stages:` doesn't?**
A **stage** is an ordered phase (`build → test → deploy`); stages run sequentially with an implicit barrier — every job in `test` must finish before any `deploy` job starts. A **job** is a unit of work inside a stage; jobs in the same stage run in parallel. `stages:` only controls *ordering*. `dependencies:` controls *artifact flow* — it lists which earlier jobs' artifacts a job downloads, and `dependencies: []` means "fetch nothing", which speeds up a job that doesn't need prior outputs. So stages answer "when does this run", `dependencies:` answers "what data does it receive". (`needs:` goes further, building a DAG so a job can start the moment its own dependencies finish, ignoring the stage barrier — the analogue of GH Actions `needs:`.)

### 1.3–1.4 Iterate to green

Link to a **green** CI run: <https://github.com/Dekart-hub/DevOps-Intro/actions/runs/27647293084>

### 1.5 Prove the gate blocks a failure

I broke a test on purpose — flipped the expected note count in `app/handlers_test.go` (`TestHealth_ReportsCount`, `!= 1` → `!= 2`) and pushed it to PR #3. Both `test` cells (`1.23` and `1.24`) went red, so the `ci-ok` aggregation gate failed and PR #3's merge state flipped to **BLOCKED** — "Required statuses must pass before merging" (`lab3_gate_blocked.png`). I then reverted the break with a follow-up commit and the pipeline returned to green, merge state back to **CLEAN**.

> Note: the PR's `mergeable` flag stayed `MERGEABLE` the whole time — that flag only tracks merge *conflicts*. It was `mergeStateStatus = BLOCKED`, driven by the failing required `ci-ok` check, that actually stopped the merge.

- **Failed run:** <https://github.com/Dekart-hub/DevOps-Intro/actions/runs/28046026697> — `test (1.23)` + `test (1.24)` → failure ⇒ `ci-ok` → failure.
- **Break commit:** `9aac3da`.
- **Fix (revert) commit:** `64266d9` — green run <https://github.com/Dekart-hub/DevOps-Intro/actions/runs/28047672107>, PR back to `CLEAN`.
- **Screenshot:** `submissions/lab3_gate_blocked.png` (PR #3 merge blocked by the red `ci-ok`).

### 1.6 Branch protection

On **my fork** (`Dekart-hub/DevOps-Intro`), `main` requires status checks to pass and branches to be up to date before merging; the single required check is **`ci-ok`** (the aggregation job — see §2.2 for why I require only it). I added this as a dedicated ruleset (`Lab_3_1_5`: require status checks + "require branches up to date"), which stacks additively on top of the Lab 1 ruleset (`Bonus_lab1`: signed commits, PR-before-merge, linear history) — both target `main`, so the merge gate is the union of the two.

> Screenshot: `submissions/lab3_required_check.png` (ruleset requiring `ci-ok`).

---

## Task 2 — Make It Fast and Smart

### 2.1 Caching

`actions/setup-go` caches the Go module cache and build cache. QuickNotes has **no `go.sum`** (zero third-party deps — see `app/go.mod`, no `require` block), so I key the cache on `app/go.mod` via `cache-dependency-path: app/go.mod`; without an explicit path `setup-go` errors with "unable to cache dependencies" when it can't find a `go.sum`.

### 2.2 Matrix

`vet` and `test` run on a `['1.23', '1.24']` matrix with `fail-fast: false` so one bad cell doesn't cancel the others. I require only the `ci-ok` aggregation job in branch protection (not the individual cells), so the matrix can change without ever leaving a stale required check stuck at "Expected — waiting for status". `ci-ok` uses `if: always()` so it still runs when an upstream job fails or is skipped, and it blocks only on `failure`/`cancelled` (a `skipped` job is allowed — that's the docs-only case).

> **Honest note on the matrix:** `app/go.mod` declares `go 1.24`, so Go 1.23 cannot build the module. `actions/setup-go` exports `GOTOOLCHAIN=local` to keep each cell on exactly the version it installed — which makes the `1.23` cell fail hard with `go: go.mod requires go >= 1.24 (running go 1.23.12; GOTOOLCHAIN=local)`. I override that with `GOTOOLCHAIN=auto` on the `vet`/`test` commands so the `1.23` cell auto-fetches the 1.24 toolchain to satisfy the floor. Net effect: the `1.23` cell really runs 1.24, so the matrix proves "passes from two `setup-go` entry points" rather than genuinely exercising 1.23 — true 1.23 coverage is impossible here without lowering the `go` directive in the provided app. I kept `1.23`/`1.24` as the lab specifies and flag this so a green `1.23` cell isn't mistaken for real 1.23 coverage.

### 2.3 Skip docs-only changes

I do path filtering at the **job level** (`dorny/paths-filter` in the `changes` job), *not* via `on.pull_request.paths`. A top-level path filter skips the whole workflow on a docs-only PR, which leaves the required `ci-ok` check stuck at "Expected — waiting for status" forever — the PR could never merge. With job-level filtering the workflow always reports: on a docs-only PR the `vet`/`test`/`lint` jobs skip (their `if:` is false) and `ci-ok` passes on the skips, so the README PR costs ~one cheap `changes` job instead of a full matrix.

> **Evidence — PR #6** (<https://github.com/Dekart-hub/DevOps-Intro/pull/6>): a docs-only change (one Markdown file under `submissions/`). The run (<https://github.com/Dekart-hub/DevOps-Intro/actions/runs/28050478263>) reported:
>
> | check | conclusion |
> |-------|-----------|
> | `changes` | success |
> | `vet` | **skipped** |
> | `test` | **skipped** |
> | `lint` | **skipped** |
> | `ci-ok` | **success** |
>
> The PR stayed green and mergeable while paying only the cheap `changes` job — a top-level `paths:` filter would instead have left the required `ci-ok` stuck at "Expected" and blocked the merge forever.

### 2.4 Measure

Median of 3 runs per scenario (runners vary). I measured by pushing three faithful variant pipelines — separate `vet`/`test`/`lint` jobs plus an aggregator, differing *only* in the setup-go cache and the matrix (no `changes` path-filter job) — to a throwaway branch, and reading each run's wall-clock (`createdAt → updatedAt`) from the Actions API.

| Scenario | Wall-clock (median of 3) | runs |
|----------|--------------------------|------|
| Baseline (no cache, single Go version, no path filter) | **39 s** | 39 / 39 / 39 |
| With cache | **36 s** | 35 / 36 / 38 |
| With cache + matrix | **38 s** | 36 / 38 / 40 |

For reference, the **full production pipeline** (cache + matrix + path-filter + the Bonus optimizations) runs **~64 s** (median of 3: 50 / 64 / 66). The ~25 s gap over the baseline is almost entirely the `changes` path-filter job's serial hop — it runs first, *then* the matrix starts. That is the deliberate §2.3 trade: the path filter *adds* a serial step to every `app` PR in exchange for skipping the whole matrix on docs-only PRs.

> **What the cache actually does (the interesting part):** the cache barely moves the *pipeline* wall-clock (39 → 36 s), but it transforms the **lint job**. With the Go *build* cache warm, the `golangci-lint` step runs in ~7 s; with it cold (cache off) it takes ~17–20 s, because the linter must compile the code (and its analysis) from scratch. That ~13 s win is invisible at the pipeline level because `test` (`-race`, ~17–22 s, uncacheable) runs in parallel and gates the critical path. QuickNotes has zero third-party deps, so the *module* cache is inert — it is the *build* cache that pays, and only on lint. On a dependency-heavy project the module cache is where caching would matter.

### 2.5 Design questions

**f) Why cache `go.sum`-keyed inputs and not build outputs?**
Inputs are deterministic: `go.sum` pins every dependency to an exact version + hash, so a cache keyed on its hash is reproducible — the same key always maps to the same bytes, and changing a dependency changes the key and cleanly invalidates the old entry. Build outputs aren't deterministic in the same way: compiled artifacts vary with toolchain version, build flags, and `GOOS`/`GOARCH`, so restoring a stale or foreign output risks running code that doesn't match the source or masking a real build error — and there's no reliable key to know when an output is invalid. So you cache the deterministic inputs and let the build produce fresh outputs. (Here there's no `go.sum`, so I key on `go.mod`; the module cache is effectively empty.)

**g) What does `fail-fast: false` change, and when do you want `true`?**
With `fail-fast: false` every matrix cell runs to completion even if a sibling fails, so I get the full map — "1.23 failed, 1.24 passed" is exactly the toolchain-specific signal the matrix exists for. With `fail-fast: true` (the GH default) the first failing cell cancels the rest, so I'd see one red cell and not know whether the others would have passed. You want `true` when cells are expensive or redundant and any single failure dooms the whole run anyway — e.g. an expensive fan-out where stopping early saves real minutes/cost, or a smoke gate that should abort the moment anything fails.

**h) Risk of an attacker writing a cache that protected branches later read?**
A PR from an untrusted branch can run a job that *writes* a cache entry; if a later run on a protected branch *reads* it, it could pull in attacker-controlled content (a poisoned module/build cache) and execute it with more trust. GitHub mitigates this with **cache scoping by ref**: a cache is isolated to the branch that created it, and a run can only restore caches from its own branch, the base branch, or the default branch — a PR branch reads *down* from base/default but its writes don't leak *up* into them, so a fork/feature PR can't overwrite the cache that `main` reads. (GitHub docs: "Caching dependencies… — Restrictions for accessing a cache.") Keying on a trusted lockfile hash and never restoring across a trust boundary keeps the surface small.

---

## Bonus — Pipeline Performance Investigation

### B.1 Profile (per-step, from one representative run)

Per-step seconds from run [`28047672107`](https://github.com/Dekart-hub/DevOps-Intro/actions/runs/28047672107) (full matrix), pulled via `gh api .../actions/runs/<id>/jobs`. Representative cells: `vet (1.24)`, `test (1.24)`, `lint`.

| Step | vet | test | lint |
|------|----:|-----:|-----:|
| Runner start (`Set up job`) | 1 | ~1 | 1 |
| Dependency setup (`checkout` + `setup-go`) | 2 | 2 | 2 |
| Actual work (`go vet` / `go test -race` / `golangci-lint`) | 1 | **22** | 8 |
| Cleanup (`Post …` + `Complete job`) | 0 | 1 | 0 |
| **Job total (s)** | **7** | **27** | **14** |

On top of each job total sits ~2–12 s of GitHub runner-allocation latency (job wall-clock minus the sum of its steps), attributable to no single step. Headline: **`go test -race` (~17–22 s) is the most expensive operation in the pipeline by an order of magnitude** — far more than `go vet` (~1 s) or even the linter (~8 s).

### B.2 Optimizations applied (≥3 beyond Task 2's cache/matrix/path-filter)

1. **`concurrency` with `cancel-in-progress: true`** — a newer push to the same ref cancels the in-flight run, so iterating to green doesn't stack up redundant runs and burn minutes.
2. **`GOFLAGS=-buildvcs=false`** — skips git VCS stamping during build/test, removing a small per-invocation cost and dropping a git dependency from the build step (CI clones shallow).
3. **golangci-lint-action's built-in caching** (`install-mode: binary` + the Go build cache) — pulls the prebuilt linter binary instead of `go install`-compiling it, and reuses a warm build cache so the linter doesn't recompile the code it analyzes. Measured: the `golangci-lint` step drops from ~17–20 s (cold) to ~7 s (warm) — the single biggest *per-step* saver (see B.3), though it is masked at the pipeline level by the `test -race` critical path.

(Considered but not applicable: a smaller `golang:1.24-alpine` *container* image — this pipeline uses `setup-go` on the `ubuntu-24.04` runner, not a job container, so there's no base image to slim.)

### B.3 Before/after

Median of 3 runs. The lint-step rows are the `golangci-lint` step duration; the pipeline row is end-to-end wall-clock. Two of the three are honestly *not* single-run wall-clock wins — and that is itself the finding.

| Optimization | Before | After | Saving |
|--------------|-------:|------:|-------:|
| golangci-lint caching (cold vs warm build cache) | ~20 s *(lint step)* | ~7 s *(lint step)* | **−13 s** on lint |
| `-buildvcs=false` | within ±2 s noise | — | ~0 s\* |
| concurrency `cancel-in-progress` | no single-run effect | no single-run effect | 0 s/run\* |
| **Pipeline wall-clock** | **39 s** | **36 s** | **−3 s** |

\* `-buildvcs=false` removes git VCS stamping — sub-second here; its real value is dropping a git dependency so the step can't fail on CI's shallow clone. `concurrency` cancels *superseded* in-flight runs, so it saves whole redundant runs (and runner minutes) while iterating, not time within a single run. The only optimization that cuts real work is warming the build cache for `golangci-lint` (−13 s on the lint step) — but `test -race` gates the critical path, so the **pipeline** wall-clock only drops ~3 s.

### B.4 Bottleneck analysis

The full pipeline's measured wall-clock is **~50–66 s (median 64 s** over 3 successful runs), so it clears the **≤ 90 s** bar with room to spare — below this the pipeline isn't what anyone waits on; reviewer attention and merge latency dominate. The B.1 profile corrects the tempting guess that runner provisioning is the bottleneck: setup (runner + `checkout` + `setup-go`) is only ~3–8 s per job. The real cost is **`go test -race` at ~17–22 s**, stretched by the serial critical path `changes` (~14 s) → matrix → `ci-ok` (~13 s) plus ~2–12 s of per-job runner-allocation latency. None of this is cacheable here: there are no modules to cache (no `go.sum`), and `-race` re-instruments the test binary every run, so even a warm build cache barely moves the one step that matters. The only real levers left — dropping `-race`, dropping a matrix cell, or removing the `changes` serial hop — each trade away safety or coverage for a few seconds, which isn't worth it under 64 s, so I'd stop optimizing here.
