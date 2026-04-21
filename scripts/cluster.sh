#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Pinned versions ------------------------------------------------------
K8S_VERSION="${K8S_VERSION:-v1.34.3}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"
CNPG_VERSION="${CNPG_VERSION:-1.28.2}"
CNPG_RELEASE_BRANCH="${CNPG_RELEASE_BRANCH:-release-1.28}"
BARMAN_PLUGIN_VERSION="${BARMAN_PLUGIN_VERSION:-0.12.0}"
TRAEFIK_HELM_VERSION="${TRAEFIK_HELM_VERSION:-39.0.8}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
CLOUD_PROVIDER_KIND_VERSION="${CLOUD_PROVIDER_KIND_VERSION:-v0.10.0}"
CLOUD_PROVIDER_KIND_NAME="${CLOUD_PROVIDER_KIND_NAME:-cloud-provider-kind}"

usage() {
  cat <<EOF
Usage:
  $0 create   --name <cluster> --mode <ingress|gateway> [--workers <N>]
  $0 validate --name <cluster>
  $0 destroy  --name <cluster>

Options:
  --workers <N>   Number of worker nodes to add (default: 0 = control-plane only).
                  Workers are labeled round-robin with
                  topology.kubernetes.io/zone=zone-{a,b,c} to let you test
                  topologySpreadConstraints locally.

Env overrides: K8S_VERSION, CERT_MANAGER_VERSION, CNPG_VERSION,
               CNPG_RELEASE_BRANCH, BARMAN_PLUGIN_VERSION,
               TRAEFIK_HELM_VERSION, GATEWAY_API_VERSION,
               CLOUD_PROVIDER_KIND_VERSION, CLOUD_PROVIDER_KIND_NAME
EOF
}

parse_args() {
  NAME=""
  MODE=""
  WORKERS=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) NAME="$2"; shift 2 ;;
      --mode) MODE="$2"; shift 2 ;;
      --workers) WORKERS="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
    esac
  done
  if [[ -z "$NAME" ]]; then
    echo "ERROR: --name is required" >&2
    exit 2
  fi
  if ! [[ "$WORKERS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --workers must be a non-negative integer (got '$WORKERS')" >&2
    exit 2
  fi
}

ctx() { echo "kind-$NAME"; }

wait_deployment() {
  local ctx="$1" ns="$2" name="$3" timeout="${4:-300}"
  echo "Waiting for deployment $ns/$name (up to ${timeout}s)..."
  kubectl --context "$ctx" -n "$ns" wait --for=condition=Available \
    "deployment/$name" --timeout="${timeout}s"
}

cmd_create() {
  local CTX; CTX="$(ctx)"

  if kind get clusters | grep -qx "$NAME"; then
    echo "Cluster '$NAME' already exists — skipping create."
  else
    local tmp; tmp="$(mktemp -d)"
    {
      cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "0.0.0.0"
  kubeProxyMode: "ipvs"
nodes:
  - role: control-plane
EOF
      local zones=(a b c)
      for i in $(seq 1 "$WORKERS"); do
        local zone="${zones[$(( (i - 1) % ${#zones[@]} ))]}"
        cat <<EOF
  - role: worker
    labels:
      topology.kubernetes.io/region: local
      topology.kubernetes.io/zone: zone-${zone}
EOF
      done
    } >"$tmp/kind-config.yaml"
    echo "Creating kind cluster '$NAME' with 1 control-plane + $WORKERS worker(s)..."
    kind create cluster --name "$NAME" --image "kindest/node:$K8S_VERSION" --config "$tmp/kind-config.yaml"
  fi

  for node in $(kind get nodes --name "$NAME"); do
    docker exec "$node" sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
  done

  # Shared cloud-provider-kind container serves LB IPs for ALL kind clusters.
  # On cluster recreate, the apiserver CA changes — restart CPK so it re-reads
  # kubeconfigs, otherwise LB IP assignment stalls with x509 TLS errors.
  if docker inspect "$CLOUD_PROVIDER_KIND_NAME" >/dev/null 2>&1; then
    echo "Shared '$CLOUD_PROVIDER_KIND_NAME' already running — restarting to refresh kubeconfigs."
    docker restart "$CLOUD_PROVIDER_KIND_NAME" >/dev/null
  else
    docker run -d \
      --name "$CLOUD_PROVIDER_KIND_NAME" \
      --network kind \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CLOUD_PROVIDER_KIND_VERSION}"
  fi

  # --- cert-manager -----------------------------------------------------
  kubectl --context "$CTX" apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  wait_deployment "$CTX" cert-manager cert-manager
  wait_deployment "$CTX" cert-manager cert-manager-webhook
  wait_deployment "$CTX" cert-manager cert-manager-cainjector

  # --- CNPG operator ----------------------------------------------------
  kubectl --context "$CTX" apply --server-side -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"
  wait_deployment "$CTX" cnpg-system cnpg-controller-manager

  # --- CNPG barman-cloud plugin ----------------------------------------
  kubectl --context "$CTX" apply -f \
    "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v${BARMAN_PLUGIN_VERSION}/manifest.yaml"
  # The manifest ships a selfsigned Issuer + two Certificates that materialize
  # `barman-cloud-{client,server}-tls` secrets. CNPG operator polls for the
  # server secret and log-spams until it exists; wait for both to be Ready
  # before moving on so downstream reconciliation settles.
  echo "Waiting for barman-cloud Certificates to be Ready..."
  kubectl --context "$CTX" -n cnpg-system wait --for=condition=Ready \
    certificate/barman-cloud-client certificate/barman-cloud-server --timeout=120s
  wait_deployment "$CTX" cnpg-system barman-cloud 300

  # Restart CNPG operator so it discovers the freshly-installed barman-cloud plugin socket.
  kubectl --context "$CTX" -n cnpg-system rollout restart deployment/cnpg-controller-manager
  kubectl --context "$CTX" -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=120s

  # --- Gateway API CRDs (gateway mode only) ----------------------------
  if [[ "$MODE" == "gateway" ]]; then
    kubectl --context "$CTX" apply -f \
      "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  fi

  # --- Traefik ---------------------------------------------------------
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo update traefik >/dev/null

  kubectl --context "$CTX" create namespace traefik --dry-run=client -o yaml \
    | kubectl --context "$CTX" apply -f -

  local -a traefik_flags
  if [[ "$MODE" == "gateway" ]]; then
    # Gateway API CRDs come from the upstream release above. The chart's own
    # Gateway + GatewayClass are used; rename the Gateway to "traefik" to match
    # the default parentRef in charts/*/templates, and open the "web" listener
    # to HTTPRoutes from any namespace.
    traefik_flags=(
      --set providers.kubernetesIngress.enabled=false
      --set providers.kubernetesGateway.enabled=true
      --set gateway.name=traefik
      --set gateway.listeners.web.namespacePolicy.from=All
    )
  else
    traefik_flags=(
      --set providers.kubernetesIngress.enabled=true
      --set providers.kubernetesGateway.enabled=false
    )
  fi

  helm --kube-context "$CTX" upgrade --install traefik traefik/traefik \
    -n traefik \
    --version "$TRAEFIK_HELM_VERSION" \
    "${traefik_flags[@]}" \
    --wait --timeout 5m

  wait_deployment "$CTX" traefik traefik

  # --- Wait for Traefik LoadBalancer IP --------------------------------
  echo "Waiting for Traefik LoadBalancer IP..."
  local lb_ip=""
  for _ in $(seq 1 60); do
    lb_ip="$(kubectl --context "$CTX" -n traefik get svc traefik \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$lb_ip" ]] && break
    sleep 2
  done
  if [[ -z "$lb_ip" ]]; then
    echo "WARNING: no LB IP yet (cloud-provider-kind may still be syncing)."
  else
    echo "Cluster '$NAME' ready in '$MODE' mode. Traefik LB IP: $lb_ip"
  fi
}
cmd_validate() {
  local CTX; CTX="$(ctx)"

  echo "Context: $CTX"
  kubectl --context "$CTX" cluster-info >/dev/null

  wait_deployment "$CTX" cert-manager cert-manager 60
  wait_deployment "$CTX" cert-manager cert-manager-webhook 60
  wait_deployment "$CTX" cert-manager cert-manager-cainjector 60
  wait_deployment "$CTX" cnpg-system cnpg-controller-manager 60

  kubectl --context "$CTX" -n cnpg-system wait --for=condition=Ready \
    certificate/barman-cloud-client certificate/barman-cloud-server --timeout=60s
  wait_deployment "$CTX" cnpg-system barman-cloud 60

  wait_deployment "$CTX" traefik traefik 60

  local lb_ip
  lb_ip="$(kubectl --context "$CTX" -n traefik get svc traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$lb_ip" ]] || { echo "ERROR: Traefik service has no LoadBalancer IP" >&2; exit 1; }

  local detected_mode=""
  if kubectl --context "$CTX" get gatewayclass traefik >/dev/null 2>&1; then
    kubectl --context "$CTX" wait --for=condition=Accepted gatewayclass/traefik --timeout=60s
    kubectl --context "$CTX" -n traefik wait --for=condition=Programmed gateway/traefik --timeout=60s
    detected_mode="gateway"
  elif kubectl --context "$CTX" get ingressclass traefik >/dev/null 2>&1; then
    detected_mode="ingress"
  else
    echo "ERROR: neither GatewayClass nor IngressClass 'traefik' is present" >&2
    exit 1
  fi

  cat <<EOF

Cluster : $NAME
Mode    : $detected_mode
LB IP   : $lb_ip
Example : http://<release>.local.gd (routed via Traefik LB $lb_ip)
EOF
}
cmd_destroy() {
  if kind get clusters | grep -qx "$NAME"; then
    kind delete cluster --name "$NAME"
  else
    echo "Cluster '$NAME' not found — nothing to delete."
  fi

  echo
  echo "Shared '$CLOUD_PROVIDER_KIND_NAME' container is left running so other"
  echo "clusters continue to get LoadBalancer IPs. Remove it manually when done:"
  echo "  docker rm -f $CLOUD_PROVIDER_KIND_NAME"
}

if [[ $# -lt 1 ]]; then usage; exit 2; fi
SUBCMD="$1"; shift
case "$SUBCMD" in
  create)
    parse_args "$@"
    case "${MODE:-}" in
      ingress|gateway) ;;
      *) echo "ERROR: create requires --mode ingress|gateway" >&2; exit 2 ;;
    esac
    cmd_create
    ;;
  validate)
    parse_args "$@"
    cmd_validate
    ;;
  destroy)
    parse_args "$@"
    cmd_destroy
    ;;
  -h|--help) usage ;;
  *) echo "Unknown subcommand: $SUBCMD" >&2; usage; exit 2 ;;
esac