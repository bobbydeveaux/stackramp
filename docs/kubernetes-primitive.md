# Kubernetes / Helm primitive

For apps that need a **real Kubernetes cluster** — they dispatch k8s Jobs, run
stateful controllers, or ship a Helm chart — rather than Cloud Run. Opt in with
`enable_gke = true` in the bootstrap; apps then declare a `kubernetes:` block in
`stackramp.yaml` and are Helm-installed into their own namespace on the shared
GKE cluster.

## What the bootstrap provisions (`enable_gke = true`)

- A **zonal** GKE Standard cluster (`stackramp-<env>`), VPC-native, Workload
  Identity enabled.
- A single `primary` node pool (`gke_node_count`, default 1 × `gke_machine_type`).
- **External Secrets Operator** (Helm) + a `ClusterSecretStore`
  (`gcp-secret-manager`) authenticating to Secret Manager as `eso-reader@` via
  Workload Identity. Apps ship `ExternalSecret` CRs referencing only the keys
  they need.

## App config (`kubernetes:` block)

```yaml
kubernetes:
  chart: deploy/helm/myapp        # default: deploy/helm/<app>
  namespace: myapp                # default: app name
  domain: myapp.stackramp.io      # optional — GKE ingress + managed cert
  images:                         # StackRamp builds+pushes these (tag = git SHA)
    - { name: myapp-api, dockerfile: Dockerfile.api, context: . }
  values: { ... }                 # inline Helm value overrides
```

Deploy job: `_kubernetes.yml` builds+pushes the listed images to Artifact
Registry, then `helm upgrade --install` into the namespace. Images not listed
(e.g. a cross-repo dependency) must be pre-published and pinned in the chart's
values.

---

## ⚠️ Known limitation: single-node, no horizontal scale (FIX BEFORE HIGH LOAD)

**The cluster is deliberately single-node (zonal, `gke_node_count = 1`).** The
reason is the shared-storage model: agentops-operator (the first consumer) mounts
a **`hostPath` volume (`/memory`)** shared between its API, worker Jobs, and
Cerebra. `hostPath` is **node-local**, so every pod must land on the same node
for it to work — which is only guaranteed with one node.

**Consequence — you cannot scale out.** Adding nodes (or using a regional
cluster) breaks the shared volume: a worker Job scheduled on node B cannot see
`/memory` written by the API on node A. Today you can only scale **up** (bigger
`gke_machine_type`), bounded by a single VM's CPU/RAM. On `e2-standard-8`
(8 vCPU / 32 GB) that caps concurrent worker Jobs; beyond it, dispatches queue.

**Do NOT switch the cluster to regional or raise `gke_node_count` to "fix"
capacity** — the validation on `gke_zone` blocks a region value precisely
because a multi-node cluster silently breaks shared `hostPath` and would corrupt
the agent memory/workspace model.

### The proper fix (when single-node capacity becomes the ceiling)

Replace the node-local `hostPath` with **shared ReadWriteMany (RWX) storage**,
then a multi-node pool becomes safe:

1. **GCP Filestore** (managed NFS) via the Filestore CSI driver — provision a
   Filestore instance in the bootstrap, expose an RWX `StorageClass`, and switch
   the agentops chart's `agentMemory.type` from `hostPath` to `pvc` (the chart
   already has this switch in `values.yaml`). Cost: Filestore has a chunky
   minimum tier (~£200+/mo), which is why it's not the default.
2. Then set `gke_node_count > 1` (and optionally node autoscaling) — worker Jobs
   spread across nodes and all mount the same RWX volume.
3. Alternatively, **re-architect the consuming app to not need shared local
   storage** (e.g. push transcripts to Cerebra over its API instead of a shared
   FS, and use per-pod ephemeral workspaces). This removes the RWX requirement
   entirely and is the cleaner long-term shape, but is app-side work.

Tracking: this note exists so the constraint is a deliberate, documented
trade-off — not a surprise under load. Revisit when a single `e2-standard-*`
node can no longer absorb peak concurrent dispatches.
