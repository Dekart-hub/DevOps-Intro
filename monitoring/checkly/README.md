# QuickNotes synthetic monitoring (Checkly) - Lab 8 bonus

A robot probe that polls QuickNotes from **two regions** (Frankfurt +
Singapore) every minute and alerts if the response is not `200` or is slower
than `2s`. This is the *outside* view, to compare against what Prometheus sees
from *inside* the Compose network.

This is monitoring-as-code: the check lives in `quicknotes.check.ts` and is
deployed with the Checkly CLI. The public URL is read from `QUICKNOTES_URL` so
the (ephemeral) tunnel address is never committed.

## Prerequisites

- The Compose stack is up (`docker compose up -d`) so QuickNotes is on
  `localhost:8080`.
- A free Checkly account (<https://www.checklyhq.com/>).
- `cloudflared` for the public tunnel (`brew install cloudflared`).

## Run it

1. **Expose QuickNotes publicly.** In one terminal:

   ```bash
   cloudflared tunnel --url http://localhost:8080
   ```

   Copy the `https://<random>.trycloudflare.com` URL it prints.

2. **Point the check at it and install the CLI.** In another terminal:

   ```bash
   cd monitoring/checkly
   npm install
   export QUICKNOTES_URL=https://<random>.trycloudflare.com
   ```

3. **Log in and smoke-test from the two regions.**

   ```bash
   npx checkly login
   npx checkly test --record
   ```

4. **Deploy so it runs every minute, then let it run >= 30 minutes.**

   ```bash
   npx checkly deploy
   ```

   Watch results in the Checkly dashboard (Frankfurt + Singapore columns).

5. **Fill the comparison table** in `submissions/lab8.md` with the p50 / p95 /
   errors Checkly reports over the window.

6. **Tear down** when done:

   ```bash
   npx checkly destroy
   ```

## What to compare

Over the same 30-minute window, line up the two viewpoints:

| | Prometheus (inside the Compose net) | Checkly (Frankfurt + Singapore) |
|--|--|--|
| Avg latency p50 | sub-millisecond scrape of an in-process counter | fill from Checkly |
| Avg latency p95 | (no request-duration histogram exposed) | fill from Checkly |
| Errors observed | from `quicknotes_http_responses_by_code_total` | fill from Checkly |

Checkly measures the **full public path** (DNS, TLS, Cloudflare edge, tunnel,
app), so its latency is tens to hundreds of ms even when the app is fast.
Prometheus only measures the app from inside the network, so it never sees a DNS
outage, an expired certificate, or a dead tunnel - but it sees per-endpoint
detail Checkly cannot.
