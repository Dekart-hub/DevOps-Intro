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

Link to a **green** CI run: `<https://github.com/Dekart-hub/DevOps-Intro/actions/runs/27647293084>`

### 1.5 Prove the gate blocks a failure

I broke a test on purpose — flipped the expected note count in `app/handlers_test.go` (`TestHealth_ReportsCount`, `!= 1` → `!= 2`), pushed, confirmed the `test` cells went red and `ci-ok` failed so the PR could not merge, then reverted with a follow-up commit and confirmed green again.

> **TODO:** paste the failing-run log excerpt (or link) and the fix-commit SHA.
> - Failed run: `<link or log>`
> - Fix commit: `<sha>`

### 1.6 Branch protection

On **my fork** (`Dekart-hub/DevOps-Intro`), `main` requires status checks to pass and branches to be up to date before merging; the single required check is **`ci-ok`** (the aggregation job — see §2.2 for why I require only it). This sits on top of the Lab 1 ruleset (signed commits, PR-before-merge, linear history).

> **TODO:** branch-protection / ruleset screenshot.

---

## Task 2 — Make It Fast and Smart

### 2.1 Caching

`actions/setup-go` caches the Go module cache and build cache. QuickNotes has **no `go.sum`** (zero third-party deps — see `app/go.mod`, no `require` block), so I key the cache on `app/go.mod` via `cache-dependency-path: app/go.mod`; without an explicit path `setup-go` errors with "unable to cache dependencies" when it can't find a `go.sum`.

### 2.2 Matrix

`vet` and `test` run on a `['1.23', '1.24']` matrix with `fail-fast: false` so one bad cell doesn't cancel the others. I require only the `ci-ok` aggregation job in branch protection (not the individual cells), so the matrix can change without ever leaving a stale required check stuck at "Expected — waiting for status". `ci-ok` uses `if: always()` so it still runs when an upstream job fails or is skipped, and it blocks only on `failure`/`cancelled` (a `skipped` job is allowed — that's the docs-only case).

> **Honest note on the matrix:** `app/go.mod` declares `go 1.24`, so Go 1.23 cannot build the module. `actions/setup-go` exports `GOTOOLCHAIN=local` to keep each cell on exactly the version it installed — which makes the `1.23` cell fail hard with `go: go.mod requires go >= 1.24 (running go 1.23.12; GOTOOLCHAIN=local)`. I override that with `GOTOOLCHAIN=auto` on the `vet`/`test` commands so the `1.23` cell auto-fetches the 1.24 toolchain to satisfy the floor. Net effect: the `1.23` cell really runs 1.24, so the matrix proves "passes from two `setup-go` entry points" rather than genuinely exercising 1.23 — true 1.23 coverage is impossible here without lowering the `go` directive in the provided app. I kept `1.23`/`1.24` as the lab specifies and flag this so a green `1.23` cell isn't mistaken for real 1.23 coverage.

### 2.3 Skip docs-only changes

I do path filtering at the **job level** (`dorny/paths-filter` in the `changes` job), *not* via `on.pull_request.paths`. A top-level path filter skips the whole workflow on a docs-only PR, which leaves the required `ci-ok` check stuck at "Expected — waiting for status" forever — the PR could never merge. With job-level filtering the workflow always reports: on a docs-only PR the `vet`/`test`/`lint` jobs skip (their `if:` is false) and `ci-ok` passes on the skips, so the README PR costs ~one cheap `changes` job instead of a full matrix.

> **TODO:** link to a docs-only PR showing `vet`/`test`/`lint` skipped and `ci-ok` green.

### 2.4 Measure

Median of 3–5 runs per scenario (runners vary). To get a clean baseline I temporarily disabled each optimization with a commit, captured the run time, then restored it.

| Scenario | Wall-clock |
|----------|-----------|
| Baseline (no cache, single Go version, no path filter) | `<XX s>` |
| With cache | `<XX s>` |
| With cache + matrix | `<XX s>` |

> **Expected finding (not a failure):** the cache rows barely move. QuickNotes has zero third-party deps, so the module cache has nothing to store; most of the ~60–80 s is runner provisioning, checkout, and the Go toolchain download — none of which the module cache touches. The build cache and the linter's analysis cache are the only caches that help here. Compare per-step durations (`setup-go`, `go test`, `golangci-lint`) rather than job totals to see where caching *would* pay on a dependency-heavy project.

### 2.5 Design questions

**f) Why cache `go.sum`-keyed inputs and not build outputs?**
Inputs are deterministic: `go.sum` pins every dependency to an exact version + hash, so a cache keyed on its hash is reproducible — the same key always maps to the same bytes, and changing a dependency changes the key and cleanly invalidates the old entry. Build outputs aren't deterministic in the same way: compiled artifacts vary with toolchain version, build flags, and `GOOS`/`GOARCH`, so restoring a stale or foreign output risks running code that doesn't match the source or masking a real build error — and there's no reliable key to know when an output is invalid. So you cache the deterministic inputs and let the build produce fresh outputs. (Here there's no `go.sum`, so I key on `go.mod`; the module cache is effectively empty.)

**g) What does `fail-fast: false` change, and when do you want `true`?**
With `fail-fast: false` every matrix cell runs to completion even if a sibling fails, so I get the full map — "1.23 failed, 1.24 passed" is exactly the toolchain-specific signal the matrix exists for. With `fail-fast: true` (the GH default) the first failing cell cancels the rest, so I'd see one red cell and not know whether the others would have passed. You want `true` when cells are expensive or redundant and any single failure dooms the whole run anyway — e.g. an expensive fan-out where stopping early saves real minutes/cost, or a smoke gate that should abort the moment anything fails.

**h) Risk of an attacker writing a cache that protected branches later read?**
A PR from an untrusted branch can run a job that *writes* a cache entry; if a later run on a protected branch *reads* it, it could pull in attacker-controlled content (a poisoned module/build cache) and execute it with more trust. GitHub mitigates this with **cache scoping by ref**: a cache is isolated to the branch that created it, and a run can only restore caches from its own branch, the base branch, or the default branch — a PR branch reads *down* from base/default but its writes don't leak *up* into them, so a fork/feature PR can't overwrite the cache that `main` reads. (GitHub docs: "Caching dependencies… — Restrictions for accessing a cache.") Keying on a trusted lockfile hash and never restoring across a trust boundary keeps the surface small.

---

## Bonus — Pipeline Performance Investigation

### B.1 Profile (per-step, from the CI UI)

> **TODO:** fill from the per-step timing breakdown of one run.

| Step | vet | test | lint |
|------|----:|-----:|-----:|
| Runner start | `<s>` | `<s>` | `<s>` |
| Dependency setup (`setup-go` / install) | `<s>` | `<s>` | `<s>` |
| Actual work (vet / test / lint) | `<s>` | `<s>` | `<s>` |
| Cleanup | `<s>` | `<s>` | `<s>` |

### B.2 Optimizations applied (≥3 beyond Task 2's cache/matrix/path-filter)

1. **`concurrency` with `cancel-in-progress: true`** — a newer push to the same ref cancels the in-flight run, so iterating to green doesn't stack up redundant runs and burn minutes.
2. **`GOFLAGS=-buildvcs=false`** — skips git VCS stamping during build/test, removing a small per-invocation cost and dropping a git dependency from the build step (CI clones shallow).
3. **golangci-lint-action's built-in caching** (`install-mode: binary` + analysis cache) — reuses the linter binary and lint analysis cache between runs instead of `go install`-ing the linter and re-analyzing cold every time. On a zero-dep module this is the single biggest real saver, because the cold linter install + first analysis is the heaviest step.

(Considered but not applicable: a smaller `golang:1.24-alpine` *container* image — this pipeline uses `setup-go` on the `ubuntu-24.04` runner, not a job container, so there's no base image to slim.)

### B.3 Before/after

> **TODO:** measure each (median of 3–5 runs).

| Optimization | Before (s) | After (s) | Saving |
|--------------|-----------:|----------:|-------:|
| concurrency cancel-in-progress | `<XX>` | `<XX>` | `<-XX>` |
| `-buildvcs=false` | `<XX>` | `<XX>` | `<-XX>` |
| golangci-lint cache | `<XX>` | `<XX>` | `<-XX>` |
| **Total wall-clock** | **`<XX>`** | **`<XX>`** | **`<-XX>`** |

### B.4 Bottleneck analysis

The dominant remaining cost is runner provisioning plus the Go toolchain setup — spinning up the `ubuntu-24.04` VM, checking out, and `setup-go` installing/restoring the toolchain. The actual `go vet` / `go test` / `golangci-lint` work over a few hundred lines of zero-dependency Go is a second or two. Caching the module download can't help because there's nothing to download (no `go.sum`); only the Go build cache and the linter's analysis cache move the needle. To make the pipeline meaningfully shorter I'd have to change QuickNotes itself — and there's almost nothing to cut on the work side, so the real wins would be fewer matrix cells or a prebuilt image with Go + `golangci-lint` baked in (trading image maintenance for setup time). I'd stop optimizing once the full pipeline is reliably under ~90 s, because below that the pipeline is no longer what anyone waits on — reviewer attention and merge latency dominate, and further engineering would cost more than the seconds it saves.

> **TODO:** state whether you hit ≤ 90 s, or report the dominant cost if not.
