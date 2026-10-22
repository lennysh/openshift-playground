#!/usr/bin/env bash
#
# setup-group.sh — Recommended day-0 setup: create an OpenShift Group, bind
# cluster-reader-no-secrets to it once, then add/remove learners via the group.
#
# Day-2 membership (no rebinding needed):
#   oc adm groups add-users    cluster-explorers user1 user2
#   oc adm groups remove-users cluster-explorers user1
#   oc get group cluster-explorers -o yaml

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROLE_NAME="${ROLE_NAME:-cluster-reader-no-secrets}"
GROUP_NAME="${GROUP_NAME:-cluster-explorers}"
BINDING_NAME=""
NAMESPACE=""
APPLY_ROLE=1
DRY_RUN=0
USERS=()

usage() {
    cat <<EOF
Usage: $0 [options] [USER ...]

Creates (if missing) an OpenShift Group, ensures ClusterRole/${ROLE_NAME}
exists, and binds that role to the group once. Extra USER arguments (or
--add-user) are added to the group membership.

This is the recommended pattern: bind the role to a group, then manage who
gets access with oc adm groups add-users / remove-users.

Options:
  --group NAME          Group name (default: ${GROUP_NAME})
  --role ROLE           ClusterRole to bind (default: ${ROLE_NAME})
  --name BINDING        ClusterRoleBinding / RoleBinding name
                        (default: <group>-<role>)
  -n, --namespace NS    Bind only in NS (RoleBinding) instead of cluster-wide
  --add-user USER       Add USER to the group (repeatable); same as trailing args
  --skip-apply-role     Do not run apply-clusterrole.sh (role must already exist)
  --dry-run             Print actions; do not create/apply
  -h, --help            Show this help

Environment:
  GROUP_NAME, ROLE_NAME  Same as --group / --role

Examples:
  # Create group + role + cluster-wide binding
  $0

  # Create and add initial members
  $0 alice@example.com bob@example.com
  $0 --add-user alice@example.com --add-user bob@example.com

  # Custom group name
  $0 --group training-readonly learner1 learner2

Day-2 (after setup):
  oc adm groups add-users ${GROUP_NAME} new-learner@example.com
  oc adm groups remove-users ${GROUP_NAME} alice@example.com
  oc get group ${GROUP_NAME}
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
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9.-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --group)
            [[ -n "${2:-}" ]] || die "--group requires a value."
            GROUP_NAME=$2
            shift 2
            ;;
        --role)
            [[ -n "${2:-}" ]] || die "--role requires a value."
            ROLE_NAME=$2
            shift 2
            ;;
        --name)
            [[ -n "${2:-}" ]] || die "--name requires a value."
            BINDING_NAME=$2
            shift 2
            ;;
        -n|--namespace)
            [[ -n "${2:-}" ]] || die "--namespace requires a value."
            NAMESPACE=$2
            shift 2
            ;;
        --add-user)
            [[ -n "${2:-}" ]] || die "--add-user requires a value."
            USERS+=("$2")
            shift 2
            ;;
        --skip-apply-role)
            APPLY_ROLE=0
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            USERS+=("$@")
            break
            ;;
        -*)
            die "Unknown argument: $1"
            ;;
        *)
            USERS+=("$1")
            shift
            ;;
    esac
done

require_cmd oc

if ! oc whoami >/dev/null 2>&1; then
    die "Not logged in. Run 'oc login' first."
fi

if [[ -z "$BINDING_NAME" ]]; then
    if [[ -n "$NAMESPACE" ]]; then
        BINDING_NAME=$(slugify "${GROUP_NAME}-${ROLE_NAME}-${NAMESPACE}")
    else
        BINDING_NAME=$(slugify "${GROUP_NAME}-${ROLE_NAME}")
    fi
fi

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Would run: $*"
    else
        "$@"
    fi
}

# --- ClusterRole -------------------------------------------------------------
if [[ "$APPLY_ROLE" -eq 1 ]]; then
    log "🔧 Ensuring ClusterRole/${ROLE_NAME} ..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Would run: ${SCRIPT_DIR}/apply-clusterrole.sh --name ${ROLE_NAME}"
    else
        "${SCRIPT_DIR}/apply-clusterrole.sh" --name "$ROLE_NAME"
    fi
elif ! oc get clusterrole "$ROLE_NAME" >/dev/null 2>&1; then
    die "ClusterRole/${ROLE_NAME} not found. Run ./apply-clusterrole.sh or omit --skip-apply-role."
fi

# --- Group -------------------------------------------------------------------
log "👥 Ensuring Group/${GROUP_NAME} ..."
if oc get group "$GROUP_NAME" >/dev/null 2>&1; then
    log "   Group already exists."
else
    run oc adm groups new "$GROUP_NAME"
fi

if [[ ${#USERS[@]} -gt 0 ]]; then
    log "➕ Adding users to Group/${GROUP_NAME}: ${USERS[*]}"
    run oc adm groups add-users "$GROUP_NAME" "${USERS[@]}"
fi

# --- Binding -----------------------------------------------------------------
log "🔗 Ensuring binding ${BINDING_NAME} → ClusterRole/${ROLE_NAME} ..."
if [[ -n "$NAMESPACE" ]]; then
    if oc get rolebinding "$BINDING_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        log "   RoleBinding already exists in namespace/${NAMESPACE}."
    else
        run oc create rolebinding "$BINDING_NAME" \
            --clusterrole="$ROLE_NAME" \
            --group="$GROUP_NAME" \
            -n "$NAMESPACE"
    fi
    SCOPE="RoleBinding/${BINDING_NAME} (namespace/${NAMESPACE})"
else
    if oc get clusterrolebinding "$BINDING_NAME" >/dev/null 2>&1; then
        log "   ClusterRoleBinding already exists."
    else
        run oc create clusterrolebinding "$BINDING_NAME" \
            --clusterrole="$ROLE_NAME" \
            --group="$GROUP_NAME"
    fi
    SCOPE="ClusterRoleBinding/${BINDING_NAME}"
fi

log ""
log "✅ Setup complete."
log "   Group:    ${GROUP_NAME}"
log "   Role:     ${ROLE_NAME}"
log "   Binding:  ${SCOPE}"
log ""
log "Day-2 membership (no RBAC changes needed):"
log "  oc adm groups add-users ${GROUP_NAME} <user> [<user>...]"
log "  oc adm groups remove-users ${GROUP_NAME} <user> [<user>...]"
log "  oc get group ${GROUP_NAME}"
log ""
log "Verify:"
log "  oc auth can-i get pods -A --as=<user> --as-group=${GROUP_NAME}    # yes"
log "  oc auth can-i get secrets -A --as=<user> --as-group=${GROUP_NAME} # no"
