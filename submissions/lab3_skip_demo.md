# CI path-filter skip demo

This PR changes only documentation (no `app/**`, no workflow file), so the `changes` job sets `app=false`, the `vet`/`test`/`lint` jobs skip, and `ci-ok` still reports green. Demonstrates section 2.3 (job-level path filtering).
