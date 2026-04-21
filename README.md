# Supabase Kubernetes (CNPG variant)

Opinionated fork of [supabase-community/supabase-kubernetes](https://github.com/supabase-community/supabase-kubernetes) that replaces the single-pod Postgres StatefulSet with a [CloudNativePG](https://cloudnative-pg.io/) (CNPG) `Cluster`.

CNPG is the only supported Postgres backend here — the upstream `StatefulSet` path, the external-DB init Job, and the community `db.*` values have been removed. If you need one of those, use the upstream chart.

## What's Supabase?

Supabase is an open source Firebase alternative — Postgres database, authentication, realtime subscriptions, storage, and edge functions.

## Prerequisites

- Kubernetes cluster with the **CloudNativePG operator installed**, version **≥ 1.28.2**.
- `helm` v3+, `kubectl`, `bash`, `curl`, `python3` (for `fetch-db-init.sh`).
- For the local dev flow under `scripts/`: `kind`, `docker`.

## Repository layout

```
charts/supabase/      # Helm chart (see charts/supabase/README.md for full docs)
scripts/              # Dev helpers
  cluster.sh            # Bootstrap a local kind cluster with CNPG + Traefik
  helm-deploy.sh        # Install/upgrade the chart against a kind cluster
  helm-undeploy.sh      # Uninstall (keeps PVCs by default)
  fetch-db-init.sh      # Regenerate files/db/*.sql from supabase/postgres upstream
values/               # (optional) per-environment values overrides
  supabase.yaml         # base override applied by helm-deploy.sh if present
  supabase.local.yaml   # dev-only override, gitignored in your workflow
```

## Quick start (local kind cluster)

```bash
# 1. Bootstrap a kind cluster with CNPG, cert-manager, Traefik
#    Add --workers 3 for a multi-node cluster (workers get round-robin
#    topology.kubernetes.io/zone=zone-{a,b,c} labels).
./scripts/cluster.sh create --name dev --mode ingress
./scripts/cluster.sh create --name dev --mode ingress --workers 3

# 2. Deploy Supabase (release name defaults to "supabase")
./scripts/helm-deploy.sh --cluster dev

# 3. Open http://supabase.local.gd once pods are Ready
kubectl --context kind-dev -n supabase get pods

# 4. Tear down (keeps CNPG PVC data)
./scripts/helm-undeploy.sh --cluster dev

# 5. Destroy the kind cluster entirely
./scripts/cluster.sh destroy --name dev
```

Gateway API mode (alpha): pass `--mode gateway` to `cluster.sh create`; `helm-deploy.sh` auto-detects the edge via installed GatewayClass/IngressClass and flips `ingress.enabled` / `gateway.enabled` accordingly. Override with `EDGE=gateway` or `EDGE=ingress`.

Multi-node: with `--workers N`, kind creates `N` worker nodes labeled round-robin with `topology.kubernetes.io/zone=zone-{a,b,c}` and `topology.kubernetes.io/region=local`. This lets you verify `topologySpreadConstraints` on `zone` and CNPG `instances: N` across "zones" locally. Minimum `N=3` recommended to actually exercise zone spread.

## Chart configuration

Full chart documentation is in [`charts/supabase/README.md`](./charts/supabase/README.md). Highlights:

- **Auto-generated credentials** — a pre-install Job mints `JWT_SECRET` + `ANON_KEY` + `SERVICE_ROLE_KEY` (HS256-signed JWTs) on first install, mirroring Supabase's [`generate-keys.sh`](https://supabase.com/docs/guides/self-hosting/docker#generate-and-configure-api-keys). Disable with `secret.jwt.generate=false` and bring your own.
- **Per-role DB secrets** — a second pre-install Job creates one `basic-auth` Secret per Postgres role (`postgres`, `authenticator`, `supabase_auth_admin`, …). CNPG and each service read only their own credential.
- **Kong entrypoint** aligned with the upstream `supabase/supabase` `docker/volumes/api/kong-entrypoint.sh` — honors both legacy `anon`/`service_role` keys and the new asymmetric `SUPABASE_PUBLISHABLE_KEY` / `SUPABASE_SECRET_KEY` pair.
- **PodDisruptionBudgets** — opt-in per stateless service via `deployment.<svc>.podDisruptionBudget.enabled`. CNPG manages the Postgres PDB itself.
- **Gateway API (alpha)** — toggle with `gateway.enabled=true` + `ingress.enabled=false`.

## Database bootstrap

CNPG's own `initdb` bypasses the `supabase/postgres` image's `docker-entrypoint-initdb.d/` scripts. The chart vendors those scripts into `charts/supabase/files/db/` and replays them via CNPG `bootstrap.initdb.postInitSQLRefs`. Regenerate after every `Chart.yaml` `appVersion` bump:

```bash
./scripts/fetch-db-init.sh                # reads Chart.yaml appVersion
./scripts/fetch-db-init.sh 17.6.1.108     # pin a specific release
```

See [charts/supabase/README.md#database-bootstrap](./charts/supabase/README.md#database-bootstrap) for details and the list of skipped migrations.

## Support

This is a community fork, not officially supported by Supabase. Please do not open issues against the official Supabase repositories — open them here instead.

## License

[Apache 2.0 License.](./LICENSE)
