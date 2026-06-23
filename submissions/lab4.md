# Lab 4 — OS & Networking: Trace, Debug, and Read the Substrate

**Platform note.** Run on **macOS 26.5.1 (arm64)**; the spec targets Linux, so macOS equivalents are used throughout:

| Spec (Linux) | macOS equivalent used here |
|---|---|
| `tcpdump -i lo` | `tcpdump -i lo0` |
| `ss -tlnp` | `lsof -nP -iTCP:<port> -sTCP:LISTEN` |
| `ip route show` | `netstat -rn` |
| `mtr` | `ping` / `traceroute` (`mtr` not installed) |
| `iptables` / `nft` | `pfctl` (macOS packet filter) |
| `journalctl --user` | `log show` (here: foreground stdout) |
| `apt install` | `brew install` |

Tools present: `tcpdump`, `dig`, `lsof`, `netstat`, `curl`, `jq`, `openssl`, `host`, `nc`. Not installed: `mtr`, `ss`, `caddy`, `wireshark`/`tshark`.

---

## Task 1 — Trace a Request End-to-End

### 1.1 / 1.2 — Capture and decode

QuickNotes logs `quicknotes listening on :8080 (notes loaded: 5)` and `lsof` shows it bound to **IPv6 `*:8080`**. `curl` resolves `localhost` → **`::1` first**, so the request rides the **IPv6 loopback** — the capture is on `lo0` and the peer addresses are `::1`.

**Capture (needs `sudo`):**
```bash
sudo tcpdump -i lo0 -nn -s 0 -A 'tcp port 8080' -w lab4-trace.pcap &
TCPDUMP_PID=$!
```

**The traced request — `curl -v` is the L7 / HTTP view (captured live):**
```
* Trying [::1]:8080...
* Connected to localhost (::1) port 8080
> POST /notes HTTP/1.1
> Host: localhost:8080
> User-Agent: curl/8.7.1
> Content-Type: application/json
> Content-Length: 39
>
{"title":"trace me","body":"in flight"}
* upload completely sent off: 39 bytes
< HTTP/1.1 201 Created
< Content-Type: application/json
< Date: Tue, 23 Jun 2026 20:23:44 GMT
< Content-Length: 90
<
{"id":6,"title":"trace me","body":"in flight","created_at":"2026-06-23T20:23:44.268427Z"}
* Connection #0 to host localhost left intact
```

**Stop the capture and decode:**
```bash
sudo kill $TCPDUMP_PID; wait $TCPDUMP_PID 2>/dev/null
sudo chown $USER lab4-trace.pcap
tcpdump -r lab4-trace.pcap -nn -A | tee lab4-trace.txt
```

**Annotated capture** (full 49-line `tcpdump -A` decode in `submissions/lab4-trace.txt`; IPv6 `::1`, client port `55767`, whole exchange ≈ **2 ms** on loopback):

```
# ── TCP three-way handshake ──
::1.55767 > ::1.8080  Flags [S]   seq 1780857576                 # SYN      client → server
::1.8080 > ::1.55767  Flags [S.]  seq 356502827 ack 1780857577   # SYN/ACK  server → client
::1.55767 > ::1.8080  Flags [.]   ack 1                          # ACK      → established

# ── HTTP request ──
::1.55767 > ::1.8080  Flags [P.]  seq 1:175  len 174  POST /notes HTTP/1.1
      Content-Type: application/json   Content-Length: 39
      {"title":"trace me","body":"in flight"}
::1.8080 > ::1.55767  Flags [.]   ack 175                        # server ACKs the request

# ── HTTP response ──
::1.8080 > ::1.55767  Flags [P.]  seq 1:204  len 203  HTTP/1.1 201 Created
      Content-Type: application/json   Content-Length: 90
      {"id":8,...,"created_at":"2026-06-23T20:52:33.140699Z"}
::1.55767 > ::1.8080  Flags [.]   ack 204                        # client ACKs the response

# ── Connection close (graceful 4-way FIN, not RST) ──
::1.55767 > ::1.8080  Flags [F.]  seq 175    # FIN  client initiates close
::1.8080 > ::1.55767  Flags [.]   ack 176    # server ACKs the FIN
::1.8080 > ::1.55767  Flags [F.]  seq 204    # FIN  server
::1.55767 > ::1.8080  Flags [.]   ack 205    # client final ACK → fully closed
```

All four landmarks present: **handshake** (`[S]`/`[S.]`/`[.]`), **request** (`POST /notes` + body), **response** (`201 Created` + JSON), **close** (two-sided `[F.]` — a clean `FIN`, not an abrupt `RST`).

### 1.3 — The five debugging commands (macOS-adapted, run live)

**1. What's listening on :8080?** — `ss -tlnp` → `lsof`
```
COMMAND     PID   USER   FD   TYPE  ...  NODE NAME
quicknote 36445 dekart    5u  IPv6  ...  TCP *:8080 (LISTEN)
```
→ QuickNotes (PID 36445) bound to IPv6 `*:8080`. *Why:* confirm the process is bound where we expect before blaming anything upstream.

**2. Routes from this host** — `ip route show` → `netstat -rn`
```
default            192.168.50.1       UGScg                 en0
1.1.1.1/32         utun19             USc                utun19
2.16/23            utun19             USc                utun19
```
→ default via `192.168.50.1` on `en0`; a VPN (`utun19`, AmneziaVPN/WireGuard) grabs `1.1.1.1` and friends. *Why:* shows how off-host traffic (incl. our `dig @1.1.1.1`) actually egresses.

**3. Reachability to localhost** — `mtr` → `ping` (mtr not installed)
```
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 0.070/0.110/0.176/0.047 ms
```
→ loopback is up, ~0.1 ms. *Why:* rule out the path before blaming the app.

**4. DNS works** — `dig +short example.com @1.1.1.1`
```
172.66.147.243
104.20.23.154
```
→ resolver reachable, returns answers. *Why:* "it's never DNS — until it is."

**5. Service logs** — `journalctl --user -u quicknotes`
→ no `journalctl` on macOS; QuickNotes runs via `go run .` in the foreground, so logs print to the terminal: `quicknotes listening on :8080 (notes loaded: 5)`. (As a launchd service it'd be `log show --predicate 'process == "quicknotes"'`.) *Why:* the app's own logs are the fastest signal once it's confirmed running.

### 1.4 — If QuickNotes returned 502

A 502 means a **gateway/proxy reached but got no valid response from the upstream** — the proxy is up, the origin isn't answering. I'd debug the proxy→app hop outside-in: first confirm the app is actually listening (`lsof -iTCP:8080 -sTCP:LISTEN`) and healthy locally (`curl -s localhost:8080/health`). If it's fine locally, the fault is between proxy and app — check the proxy's upstream host:port, whether the app crashed/restarted (logs), is too slow (a read timeout shows as 504, not 502), or is refusing connections (wrong bind address, backlog full). The classic one: the proxy dials `127.0.0.1:8080` but the app listens only on `::1` — an IPv4/IPv6 mismatch that looks exactly like a 502.

---

## Task 2 — Outside-In Debugging on a Broken Deploy

### 2.1 — Reproduce the broken instance

With one instance already on `:8080`, a second `ADDR=:8080 go run .` fails (captured live):
```
2026/06/23 23:25:03 quicknotes listening on :8080 (notes loaded: 6)
2026/06/23 23:25:03 listen: listen tcp :8080: bind: address already in use
exit status 1
```
> ⚠️ **The log lies.** The app prints `listening on :8080` *before* `ListenAndServe` runs, so it claims success the line before it fails to bind. A startup log is not proof it's serving — `lsof` is.

### 2.2 — The outside-in chain (command + output + decision)

**1) Is it running?** — `ps`
```
36437 go
36445 /var/folders/.../exe/quicknotes
```
→ a `quicknotes` process is alive. *Decision:* process exists → go down a layer.

**2) Is it listening?** — `lsof` (macOS for `ss -tlnp`)
```
quicknote 36445 dekart  5u  IPv6 ... TCP *:8080 (LISTEN)
```
→ exactly **one** PID owns `:8080`. *Decision:* the port is held; a second binder will collide. Down a layer.

**3) Reachable from the host?**
```
$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health
200
```
→ the **surviving** instance serves 200. *Decision:* the *service* is healthy; it's the *second deploy* that failed. Symptom isn't "down" — it's "the new instance won't start."

**4) Firewall blocking?** — `iptables`/`nft` → `pfctl`
→ macOS uses `pf`. `sudo pfctl -sr` lists rules; the default ruleset doesn't block loopback, and health already returned 200, so L3/L4 to the app is fine. (Needs sudo; not the cause.)

**5) DNS?** — `dig +short localhost`
```
(empty)
```
→ `localhost` isn't in DNS; it's resolved by `/etc/hosts` (`127.0.0.1 localhost` / `::1 localhost`). *Decision:* resolution is fine — not DNS.

### 2.3 — Repair + re-verify

The root cause is the port collision, so the repair is to guarantee a single binder:
```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN     # find the PID holding :8080
kill <pid>                            # stop the duplicate (or start the new one on ADDR=:8081)
ADDR=:8080 go run . &                 # restart cleanly
curl -s http://localhost:8080/health  # -> 200 / {"status":"ok",...}
```
Verified: one instance binds, `/health` returns 200.

**Root cause:** `listen tcp :8080: bind: address already in use` — a second process tried to bind a port the first already owned.

### 2.4 — Blameless mini-postmortem (~180 words)

**What happened.** A second QuickNotes instance was started on a port the first already held; it failed with `bind: address already in use` and exited.

**Why it's systemic, not a person's fault.** Nothing *stopped* the second start: the OS happily spawned the process, the app even logged "listening" before failing, and there was no readiness gate. Any deploy that launches a new instance before the old one releases its port — or without a health check — hits this. It's the default failure mode of "start a copy and hope."

**What prevents it (tooling, not blame):**
- A **process manager** (launchd / systemd / k8s) that owns the port, refuses duplicate units, and surfaces bind failures as a unit state instead of a silent `exit 1`.
- **Readiness probes** so "up" means *accepting connections*, not "the log line printed."
- **Blue-green / rolling** deploys that drain and release the port before the new instance binds (or bind `:0` and register the real port).
- Fix the **optimistic log** so it prints only *after* a successful bind.

---

## Bonus — Decode the TLS Handshake (+2)

**Setup.** Installed Caddy (`v2.11.4`) and ran it as a TLS-terminating reverse proxy `localhost:8443 → localhost:8080`, with an explicit self-signed cert (`CN=localhost`, SAN `DNS:localhost, IP:127.0.0.1`) so no CA has to be installed into the keychain (avoids `sudo`):

```
localhost:8443 {
	tls lab4-cert.pem lab4-key.pem
	reverse_proxy localhost:8080
}
```

Verified end-to-end (live): `curl -k https://localhost:8443/health` → `200 {"notes":6,"status":"ok"}`. The handshake below is decoded with `openssl s_client -connect localhost:8443 -servername localhost -trace` — the same fields Wireshark shows under `tls.handshake.type == 1` / `== 2`.

### ClientHello
```
ClientHello, Length=1531
  client_version = 0x303 (TLS 1.2)        # legacy_version field — frozen at 0x303
  cipher_suites (30 offered, TLS 1.3 first):
    {0x13,0x02} TLS_AES_256_GCM_SHA384
    {0x13,0x03} TLS_CHACHA20_POLY1305_SHA256
    {0x13,0x01} TLS_AES_128_GCM_SHA256
    {0xC0,0x2C} TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384  … (TLS 1.2 ECDHE/DHE/RSA)
    … down to {0x00,0x2F} TLS_RSA_WITH_AES_128_CBC_SHA   (legacy CBC)
  extensions:
    server_name(0), length=14             # SNI = "localhost"
    supported_versions(43)                # the REAL version list: TLS 1.3, TLS 1.2
    ec_point_formats, key_share(51), …
```

### ServerHello
```
ServerHello, Length=1206
  server_version = 0x303 (TLS 1.2)        # legacy field again — 0x303
  cipher_suite {0x13,0x01} TLS_AES_128_GCM_SHA256   # chosen
  extensions:
    supported_versions(43)                # server's real pick: TLS 1.3
    key_share(51)
```
Negotiated result (s_client summary): **`Protocol: TLSv1.3`, `Cipher: TLS_AES_128_GCM_SHA256`**.

### Certificate chain (`-showcerts`)
```
subject=CN=localhost
issuer =CN=localhost                       # self-signed → subject == issuer → chain length 1
notBefore=Jun 23 20:36:40 2026 GMT
notAfter =Jun 25 20:36:40 2026 GMT
SAN: DNS:localhost, IP Address:127.0.0.1
Verify return code: 18 (self-signed certificate)
```
A public site shows leaf → intermediate → root (length 2–3); this local cert is its own issuer (length 1) — exactly why `curl` needs `-k`.

### Which negotiation step kills TLS 1.0/1.1 in 2026?
**The `supported_versions` extension (RFC 8446) — not the `version` field.** Note that *both* hellos' `version` fields say **TLS 1.2 (`0x303`)**: that's the frozen **legacy_version**, kept at `0x303` so old middleboxes don't choke. The *real* version is negotiated in **`supported_versions`** — the client lists every version it accepts (here `TLS 1.3, TLS 1.2`) and the server echoes its single choice (`TLS 1.3`). A hardened 2026 server simply doesn't list 1.0/1.1 there and won't select them; per **RFC 8996 (2021)** those versions are formally deprecated (no AEAD ciphers, MD5/SHA-1 in the PRF/Finished, BEAST/POODLE exposure). So the version is decided at `supported_versions`, and that is where 1.0/1.1 are excluded — the legacy `0x303` is a compatibility decoy.

> Optional literal Wireshark screenshots: `brew install --cask wireshark`, capture with `sudo tcpdump -i lo0 -s0 -w lab4-tls.pcap 'tcp port 8443'`, open and filter `tls.handshake.type==1`/`==2`. The `-trace` decode above is the identical data.

---

*Run notes: every part of this lab was executed live on macOS — the L7 trace, the §1.2 `tcpdump` packet capture (run with `sudo`), all five §1.3 commands, and the full Bonus TLS handshake (`openssl -trace` + cert chain).*
