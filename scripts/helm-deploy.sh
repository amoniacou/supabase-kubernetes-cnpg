#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART="supabase"
CHART_PATH="$REPO_ROOT/charts/$CHART"
VALUES_DIR="$REPO_ROOT/values"

usage() {
  cat <<EOF
Usage: $0 --cluster <name> [<release-name>]

Required:
  --cluster <name>   kind cluster name (context is kind-<name>)

Positional:
  <release-name>     Helm release + namespace (default: supabase)

Environment:
  DOMAIN             Default <release-name>.supabase.local
  EDGE               Force "ingress" or "gateway" (overrides auto-detection)
EOF
}

CLUSTER=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
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

# Namespace ---------------------------------------------------------------
kubectl --context "$CTX" create namespace "$RELEASE" --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

# Values layering ---------------------------------------------------------
HELM_VALUES_ARGS=()
BASE_VALUES="$VALUES_DIR/$CHART.yaml"
LOCAL_VALUES="$VALUES_DIR/$CHART.local.yaml"
[[ -f "$BASE_VALUES"  ]] && HELM_VALUES_ARGS+=(-f "$BASE_VALUES")
[[ -f "$LOCAL_VALUES" ]] && HELM_VALUES_ARGS+=(-f "$LOCAL_VALUES")

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

# Studio dashboard credentials (HTTP Basic Auth through Kong). The generator
# Job runs as a pre-install hook so the Secret is in place once helm upgrade
# returns. If the user supplied their own secretRef, skip with a note.
dash_ref="$(helm --kube-context "$CTX" get values "$RELEASE" -n "$RELEASE" -a \
  -o json 2>/dev/null | python3 -c \
  'import json,sys;d=json.load(sys.stdin);print(d.get("secret",{}).get("dashboard",{}).get("secretRef",""))' 2>/dev/null || true)"
dash_secret="${dash_ref:-$RELEASE-supabase-dashboard}"
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