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
  DOMAIN             Default <release-name>.local.gd
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
DOMAIN="${DOMAIN:-$RELEASE.local.gd}"

if [[ -z "${EDGE:-}" ]]; then
  if [[ $(kubectl --context "$CTX" get gatewayclasses -o name 2>/dev/null | wc -l) -gt 0 ]]; then
    EDGE=gateway
  elif [[ $(kubectl --context "$CTX" get ingressclasses -o name 2>/dev/null | wc -l) -gt 0 ]]; then
    EDGE=ingress
  else
    echo "ERROR: cluster has neither GatewayClass nor IngressClass" >&2
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

echo
echo "Deployed. Access: http://$DOMAIN"