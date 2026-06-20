# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **IAP user identity forwarding** (#33) — the SSO proxy now forwards the authenticated caller's identity to the backend via two re-keyed pass-through headers, `X-Stackramp-User-Email` and `X-Stackramp-User-Id`, sourced from IAP's `X-Goog-Authenticated-User-*` headers with the `accounts.google.com:` prefix stripped. Backends opt in to user-aware logic by reading the new headers; existing backends that ignore them are unaffected. Re-keying avoids the Cloud Run auth-layer collision that requires the proxy to strip the original IAP JWT headers.
- **GCS bucket support in `stackramp.yaml`** (#34) — the `storage:` key now accepts a block form, `storage.buckets`, that provisions one GCS bucket per entry and injects a `BUCKET_<NAME>` env var into the Cloud Run service (for example, a `downloads` bucket exposes `BUCKET_DOWNLOADS`). The runtime service account is granted `roles/storage.objectAdmin` on each provisioned bucket. The existing scalar forms `storage: false` and `storage: gcs` are unchanged and remain back-compatible; use the scalar form or the block form, not both in one file.

### Fixed
- **Bootstrap signed-URL IAM permission** (#35) — the platform CI/CD service account is now granted `roles/iam.serviceAccountAdmin` during bootstrap so the keyless V4 signed-URL IAM binding can be applied to buckets declared under `storage.buckets`. Resolves a bootstrap failure that occurred when a `storage.buckets` block was present.
