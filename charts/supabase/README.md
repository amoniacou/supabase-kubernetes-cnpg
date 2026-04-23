# Supabase for Kubernetes with Helm (CNPG variant)

This directory contains the configurations and scripts required to run Supabase inside a Kubernetes cluster.

This is an **opinionated fork** of [supabase-community/supabase-kubernetes](https://github.com/supabase-community/supabase-kubernetes): the single-pod Postgres StatefulSet from the upstream chart is replaced with a [CloudNativePG](https://cloudnative-pg.io/) (CNPG) `Cluster`. The StatefulSet path, the external-DB init Job, and the community `db.*` values are not supported and have been removed from this chart. If you need one of those, use the upstream chart.

## Prerequisites

- A Kubernetes cluster with the **CloudNativePG operator pre-installed**, **version ≥ 1.28.2** — earlier versions are missing CRD fields the chart relies on. This chart only ships the `Cluster` and `Database` CRs, not the operator.
- The `supabase/postgres` image matching `Chart.yaml` `appVersion` (currently `17.6.1.108`). The CNPG cluster pulls it automatically; override via `cnpg.image.tag` if needed.

For production: run more than one CNPG instance (`cnpg.instances: 3`) and wire up a backup `ObjectStore` (Barman-cloud plugin).

## Usage example

> For this section we're using Minikube and Docker to create a Kubernetes cluster


1. Create a cluster with Minikube:

    ```bash
    minikube start --driver=docker
    minikube addons enable ingress
    echo "$(minikube ip)     supabase.local" | sudo tee -a /etc/hosts > /dev/null
    ```

2. Install the CloudNativePG operator (one-time, cluster-wide; version **≥ 1.28.2**):

    ```bash
    kubectl apply --server-side -f \
      https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.28.2.yaml
    ```

3. Install Supabase from this chart:

    ```bash
    helm install demo ./charts/supabase
    ```

4. The first deployment takes a few minutes (CNPG bootstrap, jwt-generator Job, service pulls). You can view the status of the pods using:

    ```bash
    kubectl get pod -l app.kubernetes.io/instance=demo

    NAME                                      READY   STATUS    RESTARTS      AGE
    demo-supabase-analytics-xxxxxxxxxx-xxxxx  1/1     Running   0             47s
    demo-supabase-auth-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-functions-xxxxxxxxxx-xxxxx  1/1     Running   0             47s
    demo-supabase-imgproxy-xxxxxxxxxx-xxxxx   1/1     Running   0             47s
    demo-supabase-kong-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-meta-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-realtime-xxxxxxxxxx-xxxxx   1/1     Running   0             47s
    demo-supabase-rest-xxxxxxxxxx-xxxxx       1/1     Running   0             47s
    demo-supabase-storage-xxxxxxxxxx-xxxxx    1/1     Running   0             47s
    demo-supabase-studio-xxxxxxxxxx-xxxxx     1/1     Running   0             47s
    demo-supabase-vector-xxxxxxxxxx-xxxxx     1/1     Running   0             47s
    ```

   The Postgres pods are managed by CNPG and carry `cnpg.io/cluster=<cnpg.clusterName>` labels instead:

    ```bash
    kubectl get pod -l cnpg.io/cluster=supabase-db

    NAME            READY   STATUS    RESTARTS   AGE
    supabase-db-1   1/1     Running   0          47s
    ```

5. Open Supabase Studio in your browser: http://supabase.local

   Use the **default credentials** below (for local development only):
   - **Username:** `supabase`
   - **Password:** `this_password_is_insecure_and_should_be_updated`

6. Uninstall Supabase example:

    ```bash
    helm uninstall demo
    minikube delete
    sudo sed -i '/[[:space:]]supabase\.local$/d' /etc/hosts
    ```

## Customize

You should consider to adjust the following values in `values.yaml`:

- `RELEASE_NAME`: Name used for helm release
- `STUDIO.EXAMPLE.COM` URL to Studio

If you want to use mail, consider to adjust the following values in `values.yaml`:

- `SMTP_ADMIN_MAIL`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_SENDER_NAME`

### JWT Secret

A **pre-install Job** (`jwt-generator`) mints the full set of JWT material on first install and writes it to a single Secret `<release>-supabase-jwt`:

- HS256 legacy — `secret`, `anonKey`, `serviceKey`
- ES256 asymmetric — `anonKeyAsymmetric`, `serviceKeyAsymmetric`, `jwtKeys`, `jwtJwks`
- Opaque sb_* keys — `publishableKey`, `secretKey`

This mirrors upstream Supabase's [`generate-keys.sh`](https://supabase.com/docs/guides/self-hosting/docker#generate-and-configure-api-keys) + [`add-new-auth-keys.sh`](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys) in one step. The Job is idempotent — the Secret is populated only on the first install; subsequent upgrades reuse the existing values so keys never rotate implicitly.

To bring your own pre-populated Secret (recommended for production, e.g. from an external secret manager):

```yaml
secret:
  jwt:
    existingSecret: my-supabase-jwt
    # Optional: map to actual key names inside the referenced Secret
    # existingSecretKey:
    #   anonKey: anonKey
    #   serviceKey: serviceKey
    #   secret: secret
```

When `existingSecret` is set, the generator Job is skipped entirely. The referenced Secret must contain all nine keys above. See the [self-hosted auth keys docs](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys) for how to produce them.

### SMTP Secret

Connection credentials for the SMTP mail server will also be provided via Kubernetes secret referenced in `values.yaml`:

```yaml
secret:
  smtp:
    username: <your-smtp-username>
    password: <your-smtp-password>
```

### DB Secrets (per-role)

Unlike the upstream chart, this fork does **not** use a single `postgres` password. A pre-install Job (`db-generator`) mints one random password per Postgres role and stores each one in its own `kubernetes.io/basic-auth` Secret named `<release>-db-<role-with-dashes>`. CNPG consumes those directly (`superuserSecret` + `managed.roles[*].passwordSecret`) and the Supabase services each read the password of the role they authenticate as.

Roles provisioned:

```
postgres
supabase_admin
authenticator
pgbouncer
supabase_auth_admin
supabase_storage_admin
supabase_functions_admin
```

To bring your own credentials for any role, pre-create a basic-auth Secret with keys `username` (= role name) and `password`, then reference it:

```yaml
secret:
  db:
    database: postgres
    existingSecrets:
      postgres: my-postgres-secret
      authenticator: my-authenticator-secret
      # Unlisted roles are still generated by the Job.
```

Passwords never rotate once generated — missing Secrets are filled in on the next upgrade, existing ones are left untouched.

### Dashboard secret

By default, a username and password is required to access the Supabase Studio dashboard. Simply change them at:

```yaml
secret:
  dashboard:
    username: supabase
    password: this_password_is_insecure_and_should_be_updated
```

### Analytics secret

A new logflare secret API key is required for securing communication between all of the Supabase services. To set the secret, generate a new 32 characters long secret similar to the step [above](#jwt-secret).

```yaml
secret:
  analytics:
    publicAccessToken: "your-super-secret-and-long-logflare-key-public"
    privateAccessToken: "your-super-secret-and-long-logflare-key-private"
```

### BigQuery secret

When using BigQuery as the Logflare analytics backend, provide a GCP service account JSON key via secret values:

```yaml
bigQuery:
  enabled: true
  projectId: my-gcp-project
  projectNumber: "123456789"

secret:
  bigquery:
    gcloudJson: '{"type":"service_account", ...}'
```

You can also reference an existing Kubernetes Secret:

```yaml
secret:
  bigquery:
    existingSecret: my-bigquery-secret
    existingSecretKey:
      gcloudJson: gcloud.json
```

### S3 secret

Supabase storage supports the use of S3 object-storage. To enable S3 for Supabase storage:

1. Set S3 key ID and access key:
  ```yaml
   secret:
    s3:
      keyId: your-s3-key-id
      accessKey: your-s3-access-key
  ```
2. Set storage S3 environment variables:
  ```yaml
  storage:
    environment:
      # Set S3 endpoint if using external object-storage
      # GLOBAL_S3_ENDPOINT: http://minio:9000
      STORAGE_BACKEND: s3
      GLOBAL_S3_PROTOCOL: http
      GLOBAL_S3_FORCE_PATH_STYLE: true
      AWS_DEFAULT_REGION: stub
  ```
3. (Optional) Enable internal minio deployment
  ```yaml
  minio:
    enabled: true
  ```

## How to use in Production

Important points to consider:

- Run `cnpg.instances: 3` (primary + 2 standbys) for HA.
- Configure a backup `ObjectStore` (barman-cloud plugin) — this chart does not ship one.
- Add SSL to the Postgres cluster via CNPG's [TLS configuration](https://cloudnative-pg.io/documentation/current/certificates/).
- Add SSL to the Ingress endpoint via `cert-manager` or a LoadBalancer provider.
- Change the domain in `host:` to your real one.
- JWT material is generated automatically on first install; for production prefer to bring your own via `secret.jwt.existingSecret` from an external secret manager.
- Override `secret.*` with `existingSecret` for every block containing credentials — do not leave the inline defaults in production.

## Database bootstrap

CNPG runs `initdb` itself, so the `supabase/postgres` image's `docker-entrypoint-initdb.d/` scripts never execute — the baseline schemas, roles, and dbmate migrations that the image would normally apply are missing. The chart replays them via CNPG `bootstrap.initdb.postInitSQLRefs`.

The SQL is vendored under `files/db/`:

| File | Source | Loaded as |
|------|--------|-----------|
| `init.sql` | `supabase/postgres/migrations/db/init-scripts/*.sql` | ConfigMap key `00-init.sql` |
| `migrations.sql` | `supabase/postgres/migrations/db/migrations/*.sql` | ConfigMap key `01-migrations.sql` |

Both files are regenerated by `scripts/fetch-db-init.sh` (repo root, not inside the chart):

```bash
# Fetch for the current Chart.yaml appVersion
./scripts/fetch-db-init.sh

# Or pin a specific supabase/postgres release tag
./scripts/fetch-db-init.sh 17.6.1.108
```

**Rerun after every `Chart.yaml` `appVersion` bump** and commit the regenerated files.

### Skipped migrations

Some upstream migrations assume state the chart does not ship and are skipped (see `SKIP_MIGRATIONS` in `fetch-db-init.sh`):

- `10000000000000_demote-postgres` — strips SUPERUSER/BYPASSRLS from the `postgres` role; CNPG uses that role as the app superuser and can no longer reconcile `managed.roles` after it runs.
- `*_pgbouncer*` (three files) — reference a `pgbouncer` schema the base image pre-creates out-of-band. We do not ship that setup.

## Gateway API (alpha)

As an alternative to the Ingress resource, the chart can emit a Gateway API `HTTPRoute` pointing at Kong. This is **alpha** — CRDs must be pre-installed and a `Gateway` must exist in the cluster:

```yaml
ingress:
  enabled: false
gateway:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
      sectionName: https
```

`host:` at the top level is used for both the Ingress rule and the HTTPRoute `hostnames`.

## Troubleshooting

### Ingress Controller and Ingress Class

The default `ingress.className: ""` delegates to the cluster's default IngressClass. Set `className` explicitly for nginx / AGIC / Traefik, and add any controller-specific annotations:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
```

Kong's `/auth/v1/*` endpoints return 401 on unauthenticated health probes. For AGIC, this must be allow-listed so the backend is marked healthy:

```yaml
ingress:
  className: azure-application-gateway
  annotations:
    appgw.ingress.kubernetes.io/health-probe-status-codes: "200-499"
```

### Testing suite

Before creating a merge request, you can test the charts locally by using [helm/chart-testing](https://github.com/helm/chart-testing). If you have Docker and a Kubernetes environment to test with, simply run:

```shell
# Run chart-testing (lint)
docker run -it \
  --workdir=/data \
  --volume $(pwd)/charts/supabase:/data \
  quay.io/helmpack/chart-testing:v3.7.1 \
  ct lint --validate-maintainers=false --chart-dirs . --charts .
# Run chart-testing (install)
docker run -it \
  --network host \
  --workdir=/data \
  --volume ~/.kube/config:/root/.kube/config:ro \
  --volume $(pwd)/charts/supabase:/data \
  quay.io/helmpack/chart-testing:v3.7.1 \
  ct install --chart-dirs . --charts .
```

### CNPG cluster not bootstrapping

If the `supabase-db-1` pod stays in `Pending` or the CNPG `Cluster` CR never becomes `Ready`, check:

- The CNPG operator is installed and healthy (`kubectl get pods -n cnpg-system`).
- `files/db/init.sql` and `files/db/migrations.sql` exist and match `Chart.yaml` `appVersion`. Rerun `./scripts/fetch-db-init.sh` if needed.
- The pre-install `db-generator` Job has completed (`kubectl get jobs -l app.kubernetes.io/component=db-generator`). Without it, `managed.roles[*].passwordSecret` references point to missing Secrets.
