#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART="supabase"
CHART_PATH="$REPO_ROOT/charts/$CHART"
VALUES_DIR="$REPO_ROOT/values"

usage() {
  cat <<EOF
Usage: $0 --cluster <name> [--backup] [<release-name>]

Required:
  --cluster <name>   kind cluster name (context is kind-<name>)

Optional:
  --backup           Enable the Barman Cloud plugin, point backups at the
                     in-cluster MinIO, pre-create the backup bucket, apply a
                     one-shot Backup CR, and wait for it to complete. Used to
                     smoke-test the backup wiring end-to-end on a kind cluster.

Positional:
  <release-name>     Helm release + namespace (default: supabase)

Environment:
  DOMAIN             Default <release-name>.supabase.local
  EDGE               Force "ingress" or "gateway" (overrides auto-detection)
EOF
}

CLUSTER=""
BACKUP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --backup)  BACKUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) echo "Unknown flag: $1" >&2; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ -z "$CLUSTER" ]]; then
  usage
  exit 2
fi

RELEASE="${1:-supabase}"

CTX="kind-$CLUSTER"

[[ -f "$CHART_PATH/Chart.yaml" ]] || { echo "ERROR: no Chart.yaml at $CHART_PATH" >&2; exit 2; }

# Cluster reachability -----------------------------------------------------
kubectl --context "$CTX" cluster-info >/dev/null

# Domain / EDGE ------------------------------------------------------------
DOMAIN="${DOMAIN:-$RELEASE.supabase.local}"

if [[ -z "${EDGE:-}" ]]; then
  # Detect the mode cluster.sh configured Traefik for. cloud-provider-kind
  # registers a GatewayClass of its own unconditionally, so a generic
  # "any GatewayClass present" check misfires — look specifically for the
  # traefik-named class, matching cluster.sh cmd_validate.
  if kubectl --context "$CTX" get gatewayclass traefik >/dev/null 2>&1; then
    EDGE=gateway
  elif kubectl --context "$CTX" get ingressclass traefik >/dev/null 2>&1; then
    EDGE=ingress
  else
    echo "ERROR: neither GatewayClass nor IngressClass 'traefik' is present. Run cluster.sh create --mode ingress|gateway first, or set EDGE=..." >&2
    exit 3
  fi
fi

case "$EDGE" in
  ingress) INGRESS_ENABLED=true;  GATEWAY_ENABLED=false ;;
  gateway) INGRESS_ENABLED=false; GATEWAY_ENABLED=true  ;;
  *) echo "ERROR: EDGE must be 'ingress' or 'gateway' (got '$EDGE')" >&2; exit 2 ;;
esac

echo "Cluster  : $CLUSTER (context $CTX)"
echo "Release  : $RELEASE"
echo "Chart    : $CHART_PATH"
echo "Host     : $DOMAIN"
echo "Edge     : $EDGE"
$BACKUP && echo "Backup   : enabled (in-cluster MinIO)"

# Namespace ---------------------------------------------------------------
kubectl --context "$CTX" create namespace "$RELEASE" --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

# Values layering ---------------------------------------------------------
HELM_VALUES_ARGS=()
BASE_VALUES="$VALUES_DIR/$CHART.yaml"
LOCAL_VALUES="$VALUES_DIR/$CHART.local.yaml"
[[ -f "$BASE_VALUES"  ]] && HELM_VALUES_ARGS+=(-f "$BASE_VALUES")
[[ -f "$LOCAL_VALUES" ]] && HELM_VALUES_ARGS+=(-f "$LOCAL_VALUES")

# --- Name helpers (mirror helm's supabase.fullname / supabase.minio.fullname).
# For release names that already contain the chart name, helm collapses the
# fullname to the release name — so for release=supabase the dashboard secret
# is "supabase-dashboard", not "supabase-supabase-dashboard".
case "$RELEASE" in
  *supabase*) FULLNAME="$RELEASE" ;;
  *)          FULLNAME="${RELEASE}-supabase" ;;
esac
case "$RELEASE" in
  *supabase-minio*) MINIO_SVC="$RELEASE" ;;
  *)                MINIO_SVC="${RELEASE}-supabase-minio" ;;
esac
MINIO_SECRET="${FULLNAME}-minio"
CNPG_CLUSTER="supabase-db"
BACKUP_BUCKET="supabase-backup"

if $BACKUP; then
  BACKUP_VALUES="$(mktemp -t supabase-backup-values.XXXXXX.yaml)"
  trap 'rm -f "$BACKUP_VALUES"' EXIT
  cat >"$BACKUP_VALUES" <<EOF
deployment:
  minio:
    enabled: true
persistence:
  minio:
    enabled: true
cnpg:
  backup:
    enabled: true
    objectStore:
      configuration:
        destinationPath: s3://${BACKUP_BUCKET}/
        endpointURL: http://${MINIO_SVC}:9000
        s3Credentials:
          accessKeyId:
            name: ${MINIO_SECRET}
            key: user
          secretAccessKey:
            name: ${MINIO_SECRET}
            key: password
        wal:
          compression: gzip
        data:
          compression: gzip
    scheduledBackup:
      immediate: true
EOF
  HELM_VALUES_ARGS+=(-f "$BACKUP_VALUES")
fi

# Install -----------------------------------------------------------------
helm --kube-context "$CTX" upgrade --install "$RELEASE" "$CHART_PATH" \
  -n "$RELEASE" \
  "${HELM_VALUES_ARGS[@]}" \
  --set "host=$DOMAIN" \
  --set "ingress.enabled=$INGRESS_ENABLED" \
  --set "gateway.enabled=$GATEWAY_ENABLED" \
  --wait --timeout 10m

# Resolve Traefik LoadBalancer IP (assigned by cloud-provider-kind). Wait up
# to ~2 min because on a fresh cluster CPK can take a moment to reconcile.
lb_ip=""
for _ in $(seq 1 60); do
  lb_ip="$(kubectl --context "$CTX" -n traefik get svc traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$lb_ip" ]] && break
  sleep 2
done

echo
echo "Deployed."
if [[ -n "$lb_ip" ]]; then
  cat <<EOF
Add to /etc/hosts (sudo required) and open http://$DOMAIN:

  $lb_ip  $DOMAIN
EOF
else
  echo "WARNING: could not resolve Traefik LB IP — access via the LB IP printed by 'kubectl -n traefik get svc traefik'." >&2
fi

# --- Backup smoke test --------------------------------------------------
# Pre-creates the bucket in the in-cluster MinIO (CNPG's barman-cloud plugin
# expects it to exist), then triggers an on-demand Backup CR and waits for
# it to complete. The ScheduledBackup in values has immediate=true, but its
# first Backup races with bucket creation — we don't rely on it. A single
# explicit Backup CR gives a deterministic pass/fail signal.
if $BACKUP; then
  echo
  echo "Backup: bootstrapping MinIO bucket '$BACKUP_BUCKET'..."

  # Wait for MinIO Deployment to be Available — helm --wait already gates on
  # this, but be explicit so failures are attributed correctly.
  kubectl --context "$CTX" -n "$RELEASE" rollout status \
    "deployment/$MINIO_SVC" --timeout=120s

  mc_user="$(kubectl --context "$CTX" -n "$RELEASE" get secret "$MINIO_SECRET" \
    -o jsonpath='{.data.user}' | base64 -d)"
  mc_pass="$(kubectl --context "$CTX" -n "$RELEASE" get secret "$MINIO_SECRET" \
    -o jsonpath='{.data.password}' | base64 -d)"
  if [[ -z "$mc_user" || -z "$mc_pass" ]]; then
    echo "ERROR: could not read MinIO credentials from secret '$MINIO_SECRET'." >&2
    exit 4
  fi

  # Short-lived mc pod. --rm + --restart=Never + --attach gives us exit status.
  kubectl --context "$CTX" -n "$RELEASE" run "supabase-backup-bucket-init" \
    --image=minio/mc:latest \
    --restart=Never \
    --rm --attach --quiet \
    --env="MC_ENDPOINT=http://${MINIO_SVC}:9000" \
    --env="MC_USER=$mc_user" \
    --env="MC_PASS=$mc_pass" \
    --env="MC_BUCKET=$BACKUP_BUCKET" \
    --command -- sh -c \
      'mc alias set s3 "$MC_ENDPOINT" "$MC_USER" "$MC_PASS" >/dev/null \
        && mc mb --ignore-existing "s3/$MC_BUCKET" \
        && echo "bucket $MC_BUCKET ready"'

  echo
  echo "Backup: triggering smoke Backup CR and waiting for completion..."

  backup_name="${CNPG_CLUSTER}-smoke"
  kubectl --context "$CTX" -n "$RELEASE" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${backup_name}
spec:
  cluster:
    name: ${CNPG_CLUSTER}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

  kubectl --context "$CTX" -n "$RELEASE" wait \
    --for=jsonpath='{.status.phase}'=completed \
    "backup/${backup_name}" --timeout=5m

  echo "Backup: smoke backup ${backup_name} completed."
fi

# Studio dashboard credentials (HTTP Basic Auth through Kong). The generator
# Job runs as a pre-install hook so the Secret is in place once helm upgrade
# returns. If the user supplied their own secretRef, skip with a note.
dash_ref="$(helm --kube-context "$CTX" get values "$RELEASE" -n "$RELEASE" -a \
  -o json 2>/dev/null | python3 -c \
  'import json,sys;d=json.load(sys.stdin);print(d.get("secret",{}).get("dashboard",{}).get("secretRef",""))' 2>/dev/null || true)"
dash_secret="${dash_ref:-${FULLNAME}-dashboard}"
dash_user="$(kubectl --context "$CTX" -n "$RELEASE" get secret "$dash_secret" \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
dash_pass="$(kubectl --context "$CTX" -n "$RELEASE" get secret "$dash_secret" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -n "$dash_user" && -n "$dash_pass" ]]; then
  cat <<EOF

Studio dashboard login (HTTP Basic Auth):
  user: $dash_user
  pass: $dash_pass
EOF
else
  echo
  echo "WARNING: could not read dashboard credentials from Secret '$dash_secret' in namespace '$RELEASE'." >&2
fi