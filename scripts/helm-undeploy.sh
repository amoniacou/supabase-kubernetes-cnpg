#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $0 --cluster <name> [<release-name>] [--delete-namespace] [--delete-pvcs]

Required:
  --cluster <name>     kind cluster name (context is kind-<name>)

Positional:
  <release-name>       Helm release + namespace to uninstall (default: supabase)

Options:
  --delete-namespace   Delete the namespace after uninstall (default: keep)
  --delete-pvcs        Delete PVCs in the namespace (data loss, including
                       CNPG Postgres data). Implied by --delete-namespace.
EOF
}

CLUSTER=""
DELETE_NS=0
DELETE_PVCS=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --delete-namespace) DELETE_NS=1; shift ;;
    --delete-pvcs) DELETE_PVCS=1; shift ;;
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

kubectl --context "$CTX" cluster-info >/dev/null

echo "Cluster : $CLUSTER (context $CTX)"
echo "Release : $RELEASE"

# Uninstall release (leaves PVCs by default — CNPG keeps WAL/data disks).
if helm --kube-context "$CTX" status "$RELEASE" -n "$RELEASE" >/dev/null 2>&1; then
  helm --kube-context "$CTX" uninstall "$RELEASE" -n "$RELEASE" --wait
else
  echo "Release '$RELEASE' not found in namespace '$RELEASE' — skipping helm uninstall."
fi

# PVC cleanup (destructive) ------------------------------------------------
if (( DELETE_PVCS || DELETE_NS )); then
  echo "Deleting PVCs in namespace '$RELEASE' (data loss)..."
  kubectl --context "$CTX" -n "$RELEASE" delete pvc --all --ignore-not-found
fi

# Namespace cleanup --------------------------------------------------------
if (( DELETE_NS )); then
  echo "Deleting namespace '$RELEASE'..."
  kubectl --context "$CTX" delete namespace "$RELEASE" --ignore-not-found
fi

echo "Done."
