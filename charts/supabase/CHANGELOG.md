# Changelog

All notable changes to this chart are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this chart adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0]

### Breaking

- **Rename `secret.<component>.secretRef` → `secret.<component>.existingSecret`**
  across `secret.jwt`, `secret.analytics`, `secret.bigquery`, `secret.smtp`,
  `secret.dashboard`, `secret.s3`, `secret.realtime`, `secret.meta`,
  `secret.minio`. Default changed from `""` to `null`.
- **Rename `secret.<component>.secretRefKey` → `secret.<component>.existingSecretKey`.**
  Previously commented-out example map is now a populated default
  (e.g. `{anonKey: anonKey, serviceKey: serviceKey, secret: secret}`), so
  referencing an external Secret with the canonical key names no longer
  requires touching this block.
- **ServiceAccount consolidation.** By default, all Supabase services now
  share a single ServiceAccount named `<fullname>` rendered from the new
  top-level `serviceAccount.{create,name,annotations}`. The 11 per-service
  blocks (`serviceAccount.auth`, `.rest`, `.studio`, `.meta`, `.storage`,
  `.kong`, `.minio`, `.realtime`, `.functions`, `.analytics`, `.imgproxy`)
  now default to `{}` and fall back to the shared SA. Set a service's
  `create: true` (or `name: <existing-sa>`) to opt into a dedicated SA —
  required for IRSA / Azure Workload Identity scenarios where a specific
  service needs its own cloud identity. `serviceAccount.vector` still
  defaults to `create: true` to keep its `pods/log` ClusterRoleBinding from
  leaking to unrelated pods.

### Added

- `cnpg.serviceAccountTemplate.{annotations,labels}` — annotations/labels
  applied to the ServiceAccount CNPG creates for the Postgres pods (IRSA /
  Workload Identity for the barman-cloud plugin).
- `OPENAI_API_KEY` in the Studio Deployment is now declared as
  `secretKeyRef.optional: true`, so bring-your-own `secret.dashboard.existingSecret`
  without an `openAiApiKey` entry no longer blocks Studio startup.
- `deployment.<svc>.extraEnv` on every service (analytics, auth, functions,
  imgproxy, kong, meta, minio, realtime, rest, storage, studio, vector) —
  a raw list of container env entries appended to the pod's `env:`. Intended
  for `valueFrom` injection (secret/configmap keys, field refs) so sensitive
  values stay out of `values.yaml`. Plain literals still belong in
  `environment.<svc>`. Primary use case: wiring GoTrue external OAuth
  providers (`GOTRUE_EXTERNAL_<PROVIDER>_CLIENT_ID` / `_SECRET`) via
  `secretKeyRef` without chart changes.

### Fixed

- Setting `secret.<component>.existingSecret` no longer fails template
  rendering with `nil pointer evaluating interface {}.<key>`. The previous
  default of a commented-out `secretRefKey` map meant any path that
  dereferenced it (e.g. `.existingSecretKey.anonKey | default "anonKey"`)
  panicked before the `| default` pipe could take effect.
- Studio pg-meta `CRYPTO_KEY` env var: add missing `| default "cryptoKey"`
  in `templates/meta/deployment.yaml` so a custom `existingSecretKey` that
  omits `cryptoKey` falls back to the canonical key name instead of
  rendering an empty `key:`.

### Changed

- `credentials-generator` no longer unconditionally writes an
  `openAiApiKey` entry to the generated dashboard Secret. The key is
  written only when `secret.dashboard.openAiApiKey` is non-empty. Combined
  with `optional: true` on Studio's envFrom, Pods start fine whether or not
  the key exists.
- The three credential-generator Jobs (`jwt-generator`, `db-generator`,
  `credentials-generator`) now share a single pre-install ServiceAccount +
  Role + RoleBinding (`<fullname>-generator`) instead of provisioning one
  set each. Net: 6 fewer RBAC resources per release.
- Kong, Vector and Edge Functions ConfigMap bodies moved out of the
  templates into `files/kong/{kong-entrypoint.sh,temp.yml}`,
  `files/vector/vector.yml` and `files/functions/index.ts`, loaded via
  `tpl (.Files.Get …) .`. Pure refactor — rendered ConfigMap data is
  byte-identical. Pattern mirrors upstream
  [supabase-community/supabase-kubernetes@f331cb4](https://github.com/supabase-community/supabase-kubernetes/commit/f331cb4f2fdab234f966fdc3e882f8565a81ab58).

### Migration

If you previously referenced an external Secret via `secretRef`:

```yaml
# before
secret:
  jwt:
    secretRef: my-supabase-jwt
    secretRefKey:
      anonKey: ANON_KEY   # custom mapping

# after
secret:
  jwt:
    existingSecret: my-supabase-jwt
    existingSecretKey:
      anonKey: ANON_KEY
```

If you previously customized a per-service ServiceAccount (annotations
for IRSA / Workload Identity):

```yaml
# before — implicit `create: true`
serviceAccount:
  storage:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123:role/storage

# after — must set `create: true` explicitly
serviceAccount:
  storage:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123:role/storage
```

## [0.6.0]

- Add support for backups via Barman Cloud (CNPG plugin).
- Initial CNPG-native release following the fork from supabase-community.
