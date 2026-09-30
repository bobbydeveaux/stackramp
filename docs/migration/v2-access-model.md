# Migrating to StackRamp v2 — the unified `access` model

**Status:** proposed breaking change · **Applies to:** apps deployed via
`bobbydeveaux/stackramp/.github/workflows/platform.yml`

> **Before you read on — pin the escape hatch.** v2 is a **major breaking
> change** and lands as the **`v2.0.0`** tag. The latest v1 release is
> `v1.1.0`, and `main` has moved past it (the mcp invoker fix) — so cut a
> final v1 tag at the current pre-v2 `main` and point every consumer that
> tracks `@main` at it until they migrate:
>
> ```bash
> # in bobbydeveaux/stackramp, on the pre-v2 main (the last v1 commit):
> git tag v1.2.0 && git push origin v1.2.0
> ```
> ```yaml
> # in each consuming repo's .github/workflows/deploy.yml:
> uses: bobbydeveaux/stackramp/.github/workflows/platform.yml@v1.2.0   # was @main
> ```
> Migrate to v2 one repo at a time, then move the pin to `@v2.0.0` (or back to
> `@main` once it's v2). Nothing below takes effect until a repo is on v2.

---

## TL;DR

`mcp` was never a *kind of service* — it was a `backend` with a different
**way of being reached and authenticated**. v2 makes that explicit:

- A backend gains one field, **`access`**: `iap | machine | public | internal`.
- An app may declare **more than one backend** (a `backends:` array).
- StackRamp **builds each unique `dir` once** and deploys every backend that
  references it — so *the same image can be exposed twice under two different
  `access` postures without building twice.*
- `frontend`, the singular `backend`, `sso: true`, and `mcp:` all still work —
  they're now **sugar** that expands to the model above. Existing configs keep
  deploying; the breaking parts are called out under [Breaking changes](#breaking-changes).

---

## Why

Auth in v1 is smeared across three overlapping booleans that each encode a
point on two orthogonal axes — **ingress** (who can reach it on the network)
and **authN** (how a caller proves who they are):

| v1 knob | ingress | authN |
|---|---|---|
| `backend.sso: true` (restrictive org) | `internal` (VPC-only) | Google IAP (human), via the SSO proxy |
| `backend.sso: true` (permissive org) | `all` | frontend-SA identity token (human, proxied) |
| `backend` (no sso) | `all` | `--allow-unauthenticated` (open; fragile under DomainRestrictedSharing) |
| `mcp.public: true` + `allowed_service_accounts` | `all` | `--no-invoker-iam-check` + in-app Google-ID-token allow-list |

Worse, `mcp` **conflates two different consumers** in one block: `public: true`
exists so *humans/Claude* can run MCP OAuth discovery, while
`allowed_service_accounts` exists so *machine agents* can present Google
service-account ID tokens. Those are two different access modes wearing one hat.

`_mcp.yml` is otherwise a near-copy of `_backend.yml` (same Cloud Run deploy,
same language Dockerfiles, same port/memory). The only durable difference is
the **access posture**. So access is the thing to name — not "MCP".

---

## The v2 model

### `access` — one posture per backend

| `access` | ingress | Cloud Run flags | authN enforced | replaces |
|---|---|---|---|---|
| **`iap`** | `internal` (restrictive) / `all` (permissive) | `--allow-unauthenticated --ingress=internal` *or* `--no-allow-unauthenticated --ingress=all` + frontend-SA invoker | Google IAP → SSO proxy injects `X-Stackramp-User-Email` | `backend.sso: true` |
| **`machine`** | `all` | `--ingress=all --no-invoker-iam-check` | in-app: verify Google-signed ID token (sig + `aud` = service URL + `exp`) and check `email ∈ allowed_service_accounts` | `mcp` + `allowed_service_accounts` |
| **`public`** | `all` | `--ingress=all --no-invoker-iam-check` | in-app: the app's own OAuth (e.g. MCP OAuth discovery) or none | `mcp.public: true` (discovery) / `backend` no-sso |
| **`internal`** | `internal` | `--no-allow-unauthenticated --ingress=internal` | Cloud Run invoker IAM (named service-to-service callers) | *(new — was implicit)* |

`machine` and `public` share the same deploy flags; they differ only in whether
the platform injects the allow-list env and what the app enforces. `--no-invoker-iam-check`
(not `--allow-unauthenticated`) keeps both reachable **without** an `allUsers`
IAM binding, so the DomainRestrictedSharing org policy is never tripped.

### `backends:` — more than one per app

```yaml
name: qbot
domain: qbot.stackramp.io

backends:
  - name: dashboard        # reads + serves the SPA API — humans
    language: go
    dir: backend           # ← same code as `ingest`
    access: iap

  - name: ingest           # telemetry from the trading bot — machines
    language: go
    dir: backend           # ← SAME dir ⇒ built once, deployed twice
    access: machine
    allowed_service_accounts:
      - qbot-ingest@bj-platform-dev.iam.gserviceaccount.com

frontend:
  framework: react
  dir: frontend

database: postgres
```

Because both backends declare `dir: backend`, StackRamp builds that image
**once** and deploys it to **two** Cloud Run services — `qbot-dashboard-<env>`
(IAP) and `qbot-ingest-<env>` (machine). No double build. See
[Build once, expose many](#build-once-expose-many).

### Env & header contract

- **`iap`** → the SSO proxy forwards the signed-in user as
  `X-Stackramp-User-Email` (+ `X-Stackramp-User-Id`). Unchanged from v1.
- **`machine`** → the platform injects the allow-list as
  **`STACKRAMP_SERVICE_ACCOUNTS`** (semicolon-joined). For back-compat it is
  **also** injected as `MCP_SERVICE_ACCOUNTS` (deprecated alias — remove in v3).
  The platform injects the service's own URL as **`SERVICE_URL`** so the app
  knows the expected token `aud`.
- Verify a `machine` caller with any Google ID-token library
  (`google.golang.org/api/idtoken`, `google-auth`, …): signature vs Google
  JWKS, `aud == SERVICE_URL`, `email ∈ STACKRAMP_SERVICE_ACCOUNTS`.

---

#### Per-backend scaling (additive, 2026-09-30)

A `backends[]` entry may also say:

```yaml
backends:
  - name: stream
    dir: hub
    access: public
    always_on: true      # CPU allocated between requests, one instance always up
    max_instances: 1     # state lives in memory: never fan out
    timeout: 3600        # Cloud Run's ceiling; WebSocket clients reconnect at it
```

`min_instances` was already accepted but not honoured on this path; it is now.
Defaults are unchanged for everyone who does not set these: scale to zero, ten
instances, five minutes, CPU throttled.


## Build once, expose many

The single most important v2 property, and the answer to *"do we build the same
image twice just to change the access method?"* — **no.**

- StackRamp **deduplicates builds by `dir`**. N backends sharing a `dir` produce
  **one** image (tag = git SHA); each backend is a separate `gcloud run deploy`
  of that same image ref with its own `access` flags, name, and URL.
- IAP/ingress is a per-*service* property on Cloud Run, so two access postures
  do require two services — but **not** two builds.
- Both deployments carry all routes; the app's own gates keep each door honest
  (a human hitting the `machine` service's read routes lacks
  `X-Stackramp-User-Email` → 401; a bot hitting the `iap` service's ingest
  routes isn't in the allow-list → 401). Exposure is enforced twice: at the
  front door (ingress/IAP) and in-app (route gates).

If two backends genuinely have **different code**, give them different `dir`s —
then they build independently, as you'd expect.

---

## Migration recipes

### 1. Plain SSO backend
```yaml
# v1
backend: { language: go, dir: backend, port: 8080, sso: true }
```
```yaml
# v2 — sugar retained (sso:true ⇒ access: iap); or be explicit:
backend: { language: go, dir: backend, port: 8080, access: iap }
```
`sso: true` still works and maps to `access: iap`. No change required, but
prefer `access: iap` going forward.

### 2. MCP server (SA-called agents)
```yaml
# v1
mcp:
  language: go
  public: true
  allowed_service_accounts: [ agentops@proj.iam.gserviceaccount.com ]
```
```yaml
# v2 — `mcp:` still works (sugar for a machine backend on dir `mcp`), OR:
backends:
  - name: mcp
    language: go
    dir: mcp
    access: machine
    allowed_service_accounts: [ agentops@proj.iam.gserviceaccount.com ]
```
> **Breaking:** if your MCP server relied on `--allow-unauthenticated` + open
> discovery for *human* Claude clients, that is now `access: public` (discovery,
> app does OAuth), separate from `access: machine` (SA allow-list). Pick the one
> your consumer actually uses; declare **two** backends if you need both.
> Also: `MCP_SERVICE_ACCOUNTS` is now `STACKRAMP_SERVICE_ACCOUNTS` (old name
> injected too, until v3).

### 3. A public-facing API (the case that forced `mcp` in v1)
```yaml
# v2 — first-class now, no MCP cosplay:
backend: { language: go, dir: backend, access: public }   # app does its own auth
# or, for machine-to-machine only:
backend: { language: go, dir: backend, access: machine,
           allowed_service_accounts: [ caller@proj.iam.gserviceaccount.com ] }
```

### 4. Reads-for-humans + ingest-for-machines, one codebase
The `qbot` example above. Two backends, same `dir`, one build.

---

## Breaking changes

1. **`access` is the source of truth.** `sso` and `mcp` remain as sugar but are
   deprecated; a future v3 removes them. `backend.public` (v1) is replaced by
   `access: public`.
2. **`mcp`'s two modes split.** `public` (discovery) and `machine` (SA
   allow-list) are now distinct `access` values. An MCP server that used both
   must declare both explicitly (two backends, or `access: public` +
   `allowed_service_accounts` handled in-app).
3. **Env rename.** `MCP_SERVICE_ACCOUNTS` → `STACKRAMP_SERVICE_ACCOUNTS`
   (old name still injected through v2 for a grace period).
4. **Schema.** `backends: []` is new; the singular `backend: {}` is retained and
   normalised to a one-element array internally.

Nothing changes until a consuming repo moves its `platform.yml` pin from
`@v1.0.0` to v2.

---

## Backward-compatibility summary

| v1 you wrote | v2 interpretation |
|---|---|
| `backend: { sso: true }` | one `iap` backend |
| `backend:` (no sso) | one `public` backend |
| `mcp: { public: true, allowed_service_accounts: [...] }` | one `machine` backend on dir `mcp` (+ `public` if human discovery is used) |
| `frontend: {...}` | unchanged |

Recommended end state: drop the sugar, say what you mean with `backends:` +
`access:`.
