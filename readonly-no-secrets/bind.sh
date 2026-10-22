#!/usr/bin/env bash
#
# bind.sh — Bind cluster-reader-no-secrets (or another ClusterRole) to a user
# or group, either cluster-wide or in a single project/namespace.

set -euo pipefail

ROLE_NAME="${ROLE_NAME:-cluster-reader-no-secrets}"
BINDING_NAME=""
USER_NAME=""
GROUP_NAME=""
NAMESPACE=""
DRY_RUN=0

usage() {
    cat <<EOF
Usage:
  $0 --user USER [--name BINDING] [--namespace NS] [--role ROLE]
  $0 --group GROUP [--name BINDING] [--namespace NS] [--role ROLE]

Creates a ClusterRoleBinding (cluster-wide) or RoleBinding (single namespace)
that grants the read-only-no-secrets ClusterRole.

Options:
  --user NAME           OpenShift user to bind (mutually exclusive with --group)
  --group NAME          OpenShift group to bind
  --name BINDING        Binding object name (default: derived from subject + role)
  --role ROLE           ClusterRole name (default: ${ROLE_NAME})
  -n, --namespace NS    If set, create a RoleBinding in NS instead of a
                        ClusterRoleBinding (limits access to that project)
  --dry-run             Show the oc create command; do not run it
  -h, --help            Show this help

Examples:
  # Cluster-wide exploration (all projects)
  $0 --user learner@example.com
  $0 --group training-learners --name training-readonly

  # Single project only
  $0 --user learner@example.com -n demo-app
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

slugify() {
    # Binding names must be DNS-1123; keep it simple.
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9.-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            [[ -n "${2:-}" ]] || die "--user requires a value."
            USER_NAME=$2
            shift 2
            ;;
        --group)
            [[ -n "${2:-}" ]] || die "--group requires a value."
            GROUP_NAME=$2
            shift 2
            ;;
        --name)
            [[ -n "${2:-}" ]] || die "--name requires a value."
            BINDING_NAME=$2
            shift 2
            ;;
        --role)
            [[ -n "${2:-}" ]] || die "--role requires a value."
            ROLE_NAME=$2
            shift 2
            ;;
        -n|--namespace)
            [[ -n "${2:-}" ]] || die "--namespace requires a value."
            NAMESPACE=$2
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

if [[ -n "$USER_NAME" && -n "$GROUP_NAME" ]]; then
    die "Specify only one of --user or --group."
fi
if [[ -z "$USER_NAME" && -z "$GROUP_NAME" ]]; then
    die "Specify --user or --group."
fi

require_cmd oc

if ! oc whoami >/dev/null 2>&1; then
    die "Not logged in. Run 'oc login' first."
fi

if ! oc get clusterrole "$ROLE_NAME" >/dev/null 2>&1; then
    die "ClusterRole/${ROLE_NAME} not found. Run ./apply-clusterrole.sh first."
fi

SUBJECT_LABEL=${USER_NAME:-$GROUP_NAME}
if [[ -z "$BINDING_NAME" ]]; then
    if [[ -n "$NAMESPACE" ]]; then
        BINDING_NAME=$(slugify "${SUBJECT_LABEL}-${ROLE_NAME}-${NAMESPACE}")
    else
        BINDING_NAME=$(slugify "${SUBJECT_LABEL}-${ROLE_NAME}")
    fi
fi

CMD=(oc create)
if [[ -n "$NAMESPACE" ]]; then
    CMD+=(rolebinding "$BINDING_NAME" --clusterrole="$ROLE_NAME" -n "$NAMESPACE")
    SCOPE="RoleBinding/${BINDING_NAME} in namespace/${NAMESPACE}"
else
    CMD+=(clusterrolebinding "$BINDING_NAME" --clusterrole="$ROLE_NAME")
    SCOPE="ClusterRoleBinding/${BINDING_NAME}"
fi

if [[ -n "$USER_NAME" ]]; then
    CMD+=(--user="$USER_NAME")
else
    CMD+=(--group="$GROUP_NAME")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would run: ${CMD[*]}"
    exit 0
fi

"${CMD[@]}"
log "✅ Bound ClusterRole/${ROLE_NAME} via ${SCOPE}"
log ""
log "Verify (as admin):"
if [[ -n "$USER_NAME" ]]; then
    AS_ARGS=(--as="$USER_NAME")
else
    # Groups cannot be passed alone to --as; use a sample user known to be in the group,
    # or check the binding and use oc auth can-i with --as-group.
    AS_ARGS=(--as="system:anonymous" --as-group="$GROUP_NAME")
fi
log "  oc auth can-i get pods -A ${AS_ARGS[*]}          # expect yes"
log "  oc auth can-i get secrets -A ${AS_ARGS[*]}       # expect no"
log "  oc auth can-i get pods/log -n <ns> ${AS_ARGS[*]} # expect yes"
