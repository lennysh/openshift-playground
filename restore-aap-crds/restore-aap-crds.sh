#!/usr/bin/env bash
#
# restore-aap-crds - Re-apply AAP CustomResourceDefinitions from the operator bundle image.
# Original concept by Michael Tipton (https://github.com/CastawayEGR)

# Exit immediately if a command exits with a non-zero status
set -e

SUPPORTED_VERSIONS=("2.4" "2.5" "2.6" "2.7")
BUNDLE_IMAGE_BASE="registry.redhat.io/ansible-automation-platform/platform-operator-bundle"

VERSION=""
PULL_SECRET="${PULL_SECRET:-}"

usage() {
    echo "Usage: $0 <version> [--pull-secret PATH]"
    echo ""
    echo "  version              AAP version (${SUPPORTED_VERSIONS[*]})"
    echo "  --pull-secret PATH   Override registry pull secret (optional)"
    echo ""
    echo "When logged in with oc, the cluster pull secret from openshift-config"
    echo "is used automatically."
    echo ""
    echo "Example: $0 2.7"
}

is_supported_version() {
    local v=$1
    for supported in "${SUPPORTED_VERSIONS[@]}"; do
        if [ "$v" = "$supported" ]; then
            return 0
        fi
    done
    return 1
}

resolve_pull_secret() {
    local work_dir=$1
    local cluster_secret="${work_dir}/cluster-pull-secret.json"

    if [ -n "$PULL_SECRET" ] && [ -f "$PULL_SECRET" ]; then
        echo "$PULL_SECRET"
        return 0
    fi

    if oc get secret pull-secret -n openshift-config \
        -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d > "$cluster_secret" \
        && [ -s "$cluster_secret" ]; then
        echo "$cluster_secret"
        return 0
    fi
    rm -f "$cluster_secret"

    for candidate in "$HOME/pull-secret" "$HOME/.pull-secret" "$HOME/.docker/config.json"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pull-secret)
            if [ -z "${2:-}" ]; then
                echo "❌ Error: --pull-secret requires a path."
                usage
                exit 1
            fi
            PULL_SECRET=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION=$1
            else
                echo "❌ Error: Unexpected argument '$1'."
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "❌ Error: Missing required argument: version."
    usage
    exit 1
fi

if ! is_supported_version "$VERSION"; then
    echo "❌ Error: Unsupported version '$VERSION'."
    echo "   Supported versions: ${SUPPORTED_VERSIONS[*]}"
    exit 1
fi

# Dependency check
for cmd in oc grep; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Error: '$cmd' is required but not installed. Exiting."
        exit 1
    fi
done

# Check active OpenShift session
if ! oc whoami &> /dev/null; then
    echo "❌ Error: You are not logged into an OpenShift cluster. Run 'oc login' first."
    exit 1
fi

BUNDLE_IMAGE="${BUNDLE_IMAGE_BASE}:${VERSION}"
EXTRACT_DIR=$(mktemp -d)
APPLIED=0

cleanup() {
    rm -rf "$EXTRACT_DIR"
}
trap cleanup EXIT

EXTRACT_CMD=(oc image extract "$BUNDLE_IMAGE" --path /manifests/:. --confirm)
if RESOLVED_PULL_SECRET=$(resolve_pull_secret "$EXTRACT_DIR"); then
    EXTRACT_CMD+=(--registry-config "$RESOLVED_PULL_SECRET")
    if [ "$RESOLVED_PULL_SECRET" = "${EXTRACT_DIR}/cluster-pull-secret.json" ]; then
        echo "📦 Using cluster pull secret from openshift-config/pull-secret"
    else
        echo "📦 Using pull secret: $RESOLVED_PULL_SECRET"
    fi
else
    echo "⚠️  No pull secret found; relying on existing registry credentials."
fi

echo "📥 Extracting manifests from $BUNDLE_IMAGE..."
if ! (cd "$EXTRACT_DIR" && "${EXTRACT_CMD[@]}"); then
    echo "❌ Error: Failed to extract operator bundle image."
    echo "   Provide a pull secret with --pull-secret or set PULL_SECRET."
    exit 1
fi

# oc image extract places directory contents directly in the destination
if [ -d "$EXTRACT_DIR/manifests" ]; then
    MANIFEST_DIR="$EXTRACT_DIR/manifests"
else
    MANIFEST_DIR="$EXTRACT_DIR"
fi

if ! compgen -G "$MANIFEST_DIR/*.yaml" > /dev/null; then
    echo "❌ Error: No manifest YAML files found after extracting operator bundle."
    exit 1
fi

echo "⚙️  Re-applying AAP ${VERSION} CustomResourceDefinitions..."

for manifest in "$MANIFEST_DIR"/*.yaml; do
    [ -f "$manifest" ] || continue
    if grep -q '^kind: CustomResourceDefinition' "$manifest"; then
        oc apply -f "$manifest"
        APPLIED=$((APPLIED + 1))
    fi
done

if [ "$APPLIED" -gt 0 ]; then
    echo "🎉 Success! Re-applied ${APPLIED} AAP ${VERSION} CRD(s) to the cluster."
else
    echo "❌ Error: No CustomResourceDefinition manifests found in operator bundle."
    exit 1
fi
