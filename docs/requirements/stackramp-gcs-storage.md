# Requirement: GCS bucket support in `stackramp.yaml`

Status: proposed · Priority: high (blocks the AI Security Posture paid-download launch) · Owner: StackRamp platform team

## Problem

Apps need private object storage. The immediate driver: the AI Security Posture site (`aiposture`) must serve a paid PDF behind an authenticated, time-limited download, so the file must live in a **private** bucket that the backend can read and hand out **expiring signed URLs** for. There is no way to request this today - `storage:` effectively only supports `false`, and `database:` covers Postgres. Apps are blocked on provisioning + IAM-wiring a bucket by hand, outside the platform.

## Goal

Let an app declare one or more private GCS buckets in `stackramp.yaml`. On deploy the platform should: provision the bucket(s), grant the app's Cloud Run runtime service account the right access, inject the bucket name(s) to the backend as env vars, and - optionally - enable the SA to mint V4 signed URLs **without a downloaded key file**.

## Proposed schema

Extend `storage:` from a scalar to an optional block (keep the scalar forms working for back-compat):

```yaml
storage:
  buckets:
    - name: downloads        # logical name -> env var BUCKET_DOWNLOADS
      access: private        # private (default) | public
      signed_urls: true      # grant the SA signBlob so the app can mint V4 signed URLs
      lifecycle_days: 0      # optional object TTL in days (0 = no lifecycle rule)
```

Back-compat: `storage: false` and `storage: gcs` continue to behave as they do now.

## Platform behaviour

1. **Provision** a bucket per entry, e.g. `gs://{project}-{app}-{env}-{name}`, with uniform bucket-level access and public access prevention ON (when `access: private`).
2. **IAM**: grant the app's Cloud Run runtime SA `roles/storage.objectAdmin` (or `objectViewer` if you later add a read-only flag) scoped to that bucket only.
3. **Signed URLs** (`signed_urls: true`): grant the SA `roles/iam.serviceAccountTokenCreator` **on itself** so the backend can call `signBlob` and generate V4 signed URLs with no exported key file (the keyless signing pattern). Without this flag, skip it.
4. **Env injection**: expose each bucket name to the backend as `BUCKET_{NAME_UPPER}` (e.g. `BUCKET_DOWNLOADS`), the same way `platform_secrets` values are injected.
5. **Lifecycle**: if `lifecycle_days > 0`, add an age-based delete lifecycle rule.
6. **Teardown**: deleting the block removes the bucket (guard with the usual destroy protections; consider `prevent_destroy` / a confirm for non-empty buckets).

## Acceptance criteria

- A `stackramp.yaml` containing the `storage.buckets` block provisions the bucket(s) on the next deploy with no manual GCP steps.
- The Cloud Run SA can read/write objects in its bucket, and - when `signed_urls: true` - generate a working V4 signed URL **with no SA key file** (verify by issuing one and fetching it).
- `access: private` buckets reject anonymous access (public access prevention enforced).
- `BUCKET_<NAME>` env var is present in the running service.
- `storage: false` apps are unaffected.
- Documented in `docs/stackramp-yaml-reference.md` and `docs/INTEGRATION.md`.

## Out of scope (for now)

- Cross-app bucket sharing.
- Non-GCS providers (S3/Azure) - revisit when the provider abstraction is generalised.
- CDN / public-bucket fronting (only needed if `access: public` is used for assets).

## Consumer reference (what `aiposture` will do with it)

The backend will: store the playbook PDF/bundle in the private `downloads` bucket; on a verified, unexpired HMAC download token, mint a short-lived (e.g. 5 min) V4 signed URL and redirect the buyer to it. The 48-hour access window is enforced by the HMAC token; the signed URL is just the final, brief hop to the bytes. So the platform only needs: a private bucket + keyless signBlob. Nothing app-specific.
