#!/usr/bin/env bash
#
# apply-clusterrole.sh — Create/update a ClusterRole that is like OpenShift's
# built-in cluster-reader, but without Secrets (and a few related escalations).
#
# Why not edit cluster-reader in place?
#   Red Hat docs advise against modifying default cluster roles; it can break
#   the cluster. Always create a *new* ClusterRole and bind that instead.
#
# Why export cluster-reader instead of hand-writing resources: ["*"]?
#   RBAC has no deny rules. Granting "*" includes Secrets. The workable pattern
#   is a whitelist built from the live aggregated cluster-reader rules, with
#   sensitive resources stripped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROLE_NAME="${ROLE_NAME:-cluster-reader-no-secrets}"
SOURCE_ROLE="${SOURCE_ROLE:-cluster-reader}"
OUT_FILE=""
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [options]

Exports the live OpenShift '${SOURCE_ROLE}' ClusterRole, strips Secrets and a
few privilege-escalation subresources, removes aggregation (so the result is a
static snapshot), and applies it as '${ROLE_NAME}'.

Options:
  --name NAME           Target ClusterRole name (default: ${ROLE_NAME})
  --source NAME         Source ClusterRole to clone (default: ${SOURCE_ROLE})
  -o, --output PATH     Also write the generated YAML to PATH
  --dry-run             Print the YAML; do not apply
  -h, --help            Show this help

Environment:
  ROLE_NAME             Same as --name
  SOURCE_ROLE           Same as --source

Examples:
  $0
  $0 --name learner-readonly -o /tmp/learner-readonly.yaml
  $0 --dry-run | oc apply --dry-run=server -f -
EOF
}

log() {
    printf '%s\n' "$*" >&2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            [[ -n "${2:-}" ]] || die "--name requires a value."
            ROLE_NAME=$2
            shift 2
            ;;
        --source)
            [[ -n "${2:-}" ]] || die "--source requires a value."
            SOURCE_ROLE=$2
            shift 2
            ;;
        -o|--output)
            [[ -n "${2:-}" ]] || die "--output requires a path."
            OUT_FILE=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

require_cmd oc
require_cmd python3

if ! oc whoami >/dev/null 2>&1; then
    die "Not logged in. Run 'oc login' first."
fi

log "📥 Exporting ClusterRole/${SOURCE_ROLE} ..."
SOURCE_JSON=$(oc get clusterrole "$SOURCE_ROLE" -o json) \
    || die "Could not get ClusterRole/${SOURCE_ROLE}. Are you a cluster-admin?"

GEN_ARGS=(--name "$ROLE_NAME" --format yaml)
if [[ -n "$OUT_FILE" ]]; then
    GEN_ARGS+=(-o "$OUT_FILE")
fi

log "🔧 Generating ClusterRole/${ROLE_NAME} (secrets stripped) ..."
if [[ -n "$OUT_FILE" ]]; then
    printf '%s\n' "$SOURCE_JSON" | python3 "${SCRIPT_DIR}/generate-clusterrole.py" "${GEN_ARGS[@]}"
    log "💾 Wrote ${OUT_FILE}"
    GENERATED=$(cat "$OUT_FILE")
else
    GENERATED=$(printf '%s\n' "$SOURCE_JSON" | python3 "${SCRIPT_DIR}/generate-clusterrole.py" --name "$ROLE_NAME" --format yaml)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s\n' "$GENERATED"
    log "✅ Dry-run only; nothing applied."
    exit 0
fi

printf '%s\n' "$GENERATED" | oc apply -f -
log "✅ ClusterRole/${ROLE_NAME} applied."
log "Next (recommended): ./setup-group.sh   # group + binding, then oc adm groups add-users"
log "Or bind directly:   ./bind.sh --group GROUP   /   ./bind.sh --user USER"
