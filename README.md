# gr-helm

The public Helm chart for **grdb** — the BYOC (Bring Your Own Cloud)
distribution of the grdb-v2 database control plane. Installs the console,
its Postgres-backed identity/intent store, and the RBAC it needs to
provision managed Postgres, Redis, Dragonfly, MongoDB, ClickHouse, and
Elasticsearch Instances via their upstream operators — into a
**customer-owned** Kubernetes cluster.

This repository contains only the chart, its default values, and this
documentation. It carries **no grdb-v2 source code** — the platform image
is published separately and pulled from the public registry
(`ghcr.io/grdev-io/grdb`, no `imagePullSecrets` required).

## Installing

### Option A — Helm repository (GitHub Pages)

This is the primary distribution channel: a classic Helm chart repository
served from this repo's `gh-pages` branch via GitHub Pages, indexed with
`helm repo index` (the `.github/workflows/release.yml` in this repo uses
[`helm/chart-releaser-action`](https://github.com/helm/chart-releaser-action)
to publish a new chart version automatically on every push to `main` that
bumps `Chart.yaml`'s `version`).

```sh
helm repo add gr-helm https://grdev-io.github.io/gr-helm
helm repo update

helm install grdb gr-helm/grdb \
  --namespace grdb-platform --create-namespace \
  --set image.tag=<grdb-v2 release tag> \
  --set database.url="postgres://..." \
  --set redis.url="redis://..."
```

### Option B — OCI registry

Helm charts can also be pushed to any OCI-compliant registry (this
project would push to `oci://ghcr.io/grdev-io/charts/grdb` alongside the
image itself). If that is set up for this repo, install with:

```sh
helm install grdb oci://ghcr.io/grdev-io/charts/grdb --version <chart version> \
  --namespace grdb-platform --create-namespace \
  --set image.tag=<grdb-v2 release tag> \
  --set database.url="postgres://..." \
  --set redis.url="redis://..."
```

Pages is the simpler of the two to stand up and is this project's primary
channel; the OCI path is documented for anyone who prefers it or whose
org policy requires OCI-only chart distribution.

### Why `grdb-platform`?

Install into a namespace literally named **`grdb-platform`**. The
platform's cluster write-gate (`ClusterGuard`, compiled into the grdb-v2
binary) looks for a marker `ConfigMap` in a namespace with that exact
name — both are Go constants, not something this chart, or any env var,
can redirect. This chart creates that marker `ConfigMap` for you in
whatever namespace you install into; installing anywhere else leaves
every write (creating a Tenant, an Instance, ...) refused even though the
Deployment itself comes up healthy. `helm template`/`helm install` print
a loud warning (see `templates/NOTES.txt`) if you deviate.

## Configuring

Every `config/config.go` environment variable in grdb-v2 has a
documented default in [`values.yaml`](values.yaml), grouped exactly like
that file's own `Config` struct: `database`, `redis`,
`bootstrapSuperadmin`, `smtp`, `oauth`, `aws`, `operatorChartVersions`,
and — for the BYOC licensing plan — `licensing`. Read the comments in
`values.yaml` before overriding; each one explains what the key is for
and what happens when it is left at its default.

A few notable ones:

- **`database.url` / `redis.url`** — required; no default works outside
  local testing.
- **`licensing.licenseActivationKey`** or **`licensing.licenseFile`** —
  the plane starts **Frozen** (every read still works; create/scale
  mutations are refused) until one activates a signed license.
  `licensing.licensingEndpoint` defaults to the vendor's own production
  `gr-licensing` service.
- **`existingSecret`** — bring your own `Secret` (sealed-secrets,
  External Secrets Operator, a plain `kubectl create secret generic`)
  instead of letting this chart template one from `values.yaml`. See
  `templates/secret.yaml` for the exact key list it must carry.
- **`ingress.enabled`** — off by default. This chart never assumes a
  specific ingress controller or cloud load balancer; set
  `ingress.className` and `ingress.annotations` for whatever your
  cluster runs.
- **`rbac.argocdIntegration.enabled` / `rbac.karpenterIntegration.enabled`**
  — the platform's "install an operator" and "Compute Profile" features
  optionally drive ArgoCD and Karpenter; each toggle is off/on
  independently since neither add-on is guaranteed to exist on an
  arbitrary BYOC cluster (a `Role`/`RoleBinding` targeting a namespace
  that doesn't exist fails the install, so `argocdIntegration` defaults
  off and `karpenterIntegration`, targeting the always-present
  `kube-system`, defaults on).
- **Image architecture** — the published image is built `linux/arm64` by
  default; the Go binary itself is plain `CGO_ENABLED=0`, so
  `linux/amd64` works fine too if you build/push that arch yourself.
  This chart never hardcodes an architecture.

Migrations run as a `db-migrate` initContainer on the Deployment, against
the same published image and tag as the main container — the image
bakes in both the `atlas` CLI and `migrations/` (grdb-v2's own
Dockerfile), so there is no second image or ConfigMap for this chart to
keep in sync with the working tree. Migrating is implicit in every
rollout; there is no separate step to remember or a `migrations.enabled`
toggle to check.

**Concurrency and `replicaCount`.** `atlas migrate apply` (`--lock-
timeout 60s` in this chart) takes a Postgres advisory lock (default
name `atlas_migrate_execute`) before applying and waits for a concurrent
holder rather than racing it, so two pods' `db-migrate` initContainers —
during a rolling update (the default `maxSurge` briefly runs two pods
even at `replicaCount: 1`), or at any `replicaCount` you set above 1 —
serialize: one applies every pending migration, the other reports "No
migration files to execute" and starts its own server container right
after. This is verified, not assumed: three `atlas migrate apply`
invocations launched simultaneously against one fresh, unmigrated
Postgres database applied cleanly against grdb-v2's own published image
(atlas 1.3.0) — exactly one performed every statement, the revisions
table held exactly one row per migration version afterward, no
duplicates or corruption. This depends specifically on the target
supporting Postgres's advisory-lock functions — true for real Postgres
and most managed Postgres (Neon, RDS, Cloud SQL), but not universal
across every Postgres-wire-compatible service (Atlas's own docs name
Aurora DSQL as one that does not support them). If `database.url` points
at something other than real Postgres, verify this before raising
`replicaCount` above 1.

## Verifying a render

```sh
helm lint charts/grdb
helm template charts/grdb --set image.tag=v0.1.0 > /tmp/rendered.yaml
kubectl apply --dry-run=client -f /tmp/rendered.yaml   # optional, needs a reachable cluster/schema
```

## Issues

Install and chart problems get **this repository's own public issue
tracker** — separate from grdb-v2's internal tracker, since this repo (and
its issues) are public.

## License

See the chart's own licensing note: this chart is free to use; the
`grdb` image it deploys requires an activated BYOC license from
`gr-licensing` to accept mutations once installed.
