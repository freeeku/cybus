# Security posture

Scope: this app ingests **public, low-stakes** open data (bus positions and schedules, CC BY 4.0) and stores **no user data** (no accounts, no favourites — see CONTEXT.md). So the posture is deliberately proportionate: the priority is not leaking secrets or trusting a single source blindly, but mostly **not crashing or being DoS'd by malformed input**.

## Trust boundary

CyNAP and motionbuscard are **untrusted external input**. Validation happens at the two pieces we control (see [data-pipeline.md](./data-pipeline.md)):

- the **scheduled job** validates and sanitises static GTFS before publishing;
- the **edge proxy** bounds and sanity-checks the realtime feed.

The app trusts only HTTPS-served, hash-verified artifacts, and still range-checks values before rendering.

## Mitigations

### Parsing safety (highest priority — protects against crashes/DoS regardless of source trust)

- **Zip-slip:** reject any zip entry whose path is absolute or contains `..`; extract only the expected GTFS `.txt` files.
- **Zip bombs:** cap total uncompressed size, entry count, and compression ratio; abort if exceeded.
- **Protobuf:** decode with official generated bindings; reject unparseable messages; cap response size (observed ~7.5 KB; refuse multi-MB responses).
- **CSV (GTFS):** parse defensively; drop malformed rows rather than fail the whole feed.

### Value validation (before anything reaches the UI)

- Clamp coordinates: `lat ∈ [-90, 90]`, `lon ∈ [-180, 180]` — bad coords can crash MapKit or fling the camera.
- Sanity-check timestamps (reject implausible far-future/past arrivals).
- Bound the length of displayed strings (stop names, headsigns).

### Validation gate (catch bad feeds before users see them)

- Run the MobilityData GTFS validator in the scheduled job.
- **Fail-closed:** if a feed is broken or hostile, fail the build and keep serving the last-good SQLite.

### Integrity & transport

- **Transport:** the proxy serves the app over **HTTPS**, even though upstream CyNAP realtime is plain HTTP (also the reason the proxy is mandatory — iOS ATS blocks the HTTP origin). See [ADR-0001](./adr/0001-free-tier-first-realtime-architecture.md).
- **SQLite integrity (decided):** **HTTPS + SHA-256 manifest.** The app fetches a small version manifest listing the expected SHA-256, downloads the DB, and verifies the hash before opening it. Catches corruption, partial downloads, and accidental bad publishes, with no key management. Cryptographic signing (Ed25519) was considered and rejected as overkill for public data — revisit only if the threat model changes (e.g. the static host becomes a target).

### Fetch-time controls (downloading from remote URLs)

Securing the moment the job/proxy pulls bytes from a remote URL — distinct from parsing them afterwards. The two sources have very different transport guarantees.

**HTTPS static zips (`motionbuscard.org.cy`):**
- **Never disable TLS verification** (no `curl -k` / `verify=False`); fail the download on any cert error. Standard CA validation only — cert pinning is a deliberate non-goal (overkill for public data, breaks on cert rotation).
- **Confirm it's actually a zip**, not an error page: check magic bytes (`PK\x03\x04`) / content-type and fail otherwise. (Observed during verification: a malformed request — missing the `&rel=True` param — returns a `200` HTML "page not found" instead of a zip, which would poison the parser if not caught. See [data-sources.md](./data-sources.md).)
- **Redirect policy:** cap redirects and do not follow redirects to a different host (a malformed request `302`s to an error page; an open redirect could otherwise point the fetcher at an attacker host).

**HTTP realtime feed (`http://20.19.98.194:8328`):**
- No transport security exists and CyNAP offers no HTTPS, so this download cannot be secured in transit. Treat the payload as fully untrusted and rely on downstream content validation (size cap, protobuf parse, value clamping). The proxy→app hop is HTTPS; the proxy→CyNAP hop is accepted as-is because the data is public and low-stakes.

**Both downloads (robustness / avoid self-DoS):**
- **Streaming size cap** — abort mid-download if the response exceeds a sane limit; don't wait until it finishes.
- **Connect + total timeouts** so a hanging/slow server can't wedge the job.
- **Download → temp → validate → atomic swap**; never publish a half-downloaded or error-page file. On any failure, keep serving last-good (fail-closed).

**Pipeline supply chain:** pin GitHub Action versions by commit SHA and pin parser/dependency versions, so the fetch tooling can't be swapped underneath us.

## Explicit non-goals

- No defence against a fully compromised static host serving a *validly-hashed* malicious DB (would require signing — see above).
- No secrets in the app binary (there are none to embed — the upstream feeds need no key).
- No PII handling (the app collects and stores none).
