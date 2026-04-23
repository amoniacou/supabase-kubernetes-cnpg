#!/usr/bin/env bash
set -euo pipefail

# Mirrors .github/workflows/test.yaml locally:
# creates a kind cluster, installs the CNPG operator, runs `ct install`.
# Useful for reproducing CI before opening a PR.
#
# Usage:
#   scripts/ct-test.sh [lint|install|all]   # default: all
#   scripts/ct-test.sh destroy              # delete the kind cluster
#
# Env overrides: CLUSTER_NAME, K8S_VERSION, CNPG_VERSION, CNPG_RELEASE_BRANCH,
#                TARGET_BRANCH

CLUSTER_NAME="${CLUSTER_NAME:-supabase-ct}"
K8S_VERSION="${K8S_VERSION:-v1.34.3}"
CNPG_VERSION="${CNPG_VERSION:-1.28.2}"
CNPG_RELEASE_BRANCH="${CNPG_RELEASE_BRANCH:-release-1.28}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"

CTX="kind-${CLUSTER_NAME}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 1; }
}

ensure_cluster() {
  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    echo "kind cluster '$CLUSTER_NAME' already exists — reusing."
  else
    echo "Creating kind cluster '$CLUSTER_NAME' (k8s $K8S_VERSION)..."
    kind create cluster --name "$CLUSTER_NAME" --image "kindest/node:${K8S_VERSION}"
  fi
}

ensure_cnpg() {
  echo "Installing CNPG operator ${CNPG_VERSION} (${CNPG_RELEASE_BRANCH})..."
  kubectl --context "$CTX" apply --server-side -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"
  kubectl --context "$CTX" -n cnpg-system rollout status \
    deployment/cnpg-controller-manager --timeout=180s
}

run_lint() {
  echo "Running ct lint..."
  ct lint \
    --check-version-increment=false \
    --validate-maintainers=false \
    --target-branch "$TARGET_BRANCH"
}

run_install() {
  echo "Running ct install against context '$CTX'..."
  kubectl config use-context "$CTX" >/dev/null
  ct install --all --target-branch "$TARGET_BRANCH"
}

cmd_destroy() {
  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    kind delete cluster --name "$CLUSTER_NAME"
  else
    echo "kind cluster '$CLUSTER_NAME' not found — nothing to delete."
  fi
}

mode="${1:-all}"
case "$mode" in
  lint)
    require ct
    run_lint
    ;;
  install)
    require kind; require kubectl; require helm; require ct
    ensure_cluster
    ensure_cnpg
    run_install
    ;;
  all)
    require kind; require kubectl; require helm; require ct
    run_lint
    ensure_cluster
    ensure_cnpg
    run_install
    ;;
  destroy)
    require kind
    cmd_destroy
    ;;
  -h|--help)
    sed -n '3,15p' "$0"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    sed -n '3,15p' "$0" >&2
    exit 2
    ;;
esac
