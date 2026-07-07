#!/usr/bin/env bash
#
# dump-aap-crds - Discover installed AAP operators via oc and dump their CRDs to YAML files.
#
# Uses OpenShift subscriptions/CSVs to find each AAP version and namespace, then writes
# version-specific CustomResourceDefinition manifests to a local directory for use as schema
# reference when generating example config files.

set -euo pipefail

readonly AAP_PACKAGE="ansible-automation-platform-operator"
readonly BUNDLE_IMAGE_BASE="registry.redhat.io/ansible-automation-platform/platform-operator-bundle"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/crd-dumps"

SUPPORTED_VERSIONS=("2.4" "2.5" "2.6" "2.7")
PULL_SECRET="${PULL_SECRET:-}"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
SOURCE="bundle"
NAMESPACES=()
VERSIONS=()
DUMPED_TOTAL=0

usage() {
    cat <<EOF
Usage: $0 [options]

Discover Ansible Automation Platform operators on the connected OpenShift cluster and dump
their CustomResourceDefinitions to local YAML files.

By default, CRDs are extracted from the official operator bundle image for each discovered
AAP version. This produces accurate, version-specific schemas even when multiple AAP
operators share a cluster (cluster-scoped CRDs only reflect the latest schema).

Options:
  --output-dir PATH     Output directory (default: ${DEFAULT_OUTPUT_DIR})
  --source MODE         CRD source: bundle (default) or cluster
  --namespaces LIST     Comma-separated namespaces to scan (default: auto-discover)
  --versions LIST       Comma-separated AAP versions to include (${SUPPORTED_VERSIONS[*]})
  --pull-secret PATH    Registry pull secret for bundle extraction
  -h, --help            Show this help

Environment:
  PULL_SECRET           Same as --pull-secret

Examples:
  $0
  $0 --source cluster --output-dir /tmp/aap-crds
  $0 --namespaces aap24,aap27 --versions 2.4,2.7
EOF
}

log() {
    printf '%s\n' "$*" >&2
}

die() {
    printf '❌ Error: %s\n' "$*" >&2
    exit 1
}

is_supported_version() {
    local v=$1
    local supported
    for supported in "${SUPPORTED_VERSIONS[@]}"; do
        if [ "$v" = "$supported" ]; then
            return 0
        fi
    done
    return 1
}

version_selected() {
    local v=$1
    if [ "${#VERSIONS[@]}" -eq 0 ]; then
        return 0
    fi
    local selected
    for selected in "${VERSIONS[@]}"; do
        if [ "$v" = "$selected" ]; then
            return 0
        fi
    done
    return 1
}

namespace_selected() {
    local ns=$1
    if [ "${#NAMESPACES[@]}" -eq 0 ]; then
        return 0
    fi
    local selected
    for selected in "${NAMESPACES[@]}"; do
        if [ "$ns" = "$selected" ]; then
            return 0
        fi
    done
    return 1
}

parse_csv_list() {
    local value=$1
    local item
    IFS=',' read -r -a _parsed <<< "$value"
    for item in "${_parsed[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [ -n "$item" ] && printf '%s\n' "$item"
    done
}

resolve_pull_secret() {
    local work_dir=$1
    local cluster_secret="${work_dir}/cluster-pull-secret.json"

    if [ -n "$PULL_SECRET" ] && [ -f "$PULL_SECRET" ]; then
        printf '%s\n' "$PULL_SECRET"
        return 0
    fi

    if oc get secret pull-secret -n openshift-config \
        -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d > "$cluster_secret" \
        && [ -s "$cluster_secret" ]; then
        printf '%s\n' "$cluster_secret"
        return 0
    fi
    rm -f "$cluster_secret"

    for candidate in "$HOME/pull-secret" "$HOME/.pull-secret" "$HOME/.docker/config.json"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

normalize_aap_version() {
    local raw=$1
    local channel=$2

    if [[ "$raw" =~ ^([0-9]+\.[0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$channel" =~ stable-([0-9]+\.[0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

discover_operators() {
    local ns channel csv version phase owned_count

    while IFS=$'\t' read -r ns channel csv phase; do
        [ -n "$ns" ] || continue
        namespace_selected "$ns" || continue

        version=$(normalize_aap_version "${csv#aap-operator.v}" "$channel") || continue
        is_supported_version "$version" || continue
        version_selected "$version" || continue

        owned_count=$(get_owned_crd_names "$csv" "$ns" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$version" "$ns" "$csv" "$channel" "${phase:-Unknown}" "$owned_count"
    done < <(
        oc get subscription -A -o json | python3 -c '
import json
import sys

package = "ansible-automation-platform-operator"
data = json.load(sys.stdin)

for item in sorted(data.get("items", []), key=lambda x: x["metadata"]["namespace"]):
    spec = item.get("spec", {})
    if spec.get("name") != package:
        continue
    ns = item["metadata"]["namespace"]
    channel = spec.get("channel", "")
    csv = item.get("status", {}).get("currentCSV", "")
    phase = item.get("status", {}).get("state", "")
    if not csv:
        continue
    print(f"{ns}\t{channel}\t{csv}\t{phase}")
'
    )
}

get_owned_crd_names() {
    local csv=$1
    local ns=$2
    oc get csv "$csv" -n "$ns" -o jsonpath='{range .spec.customresourcedefinitions.owned[*]}{.name}{"\n"}{end}'
}

clean_cluster_crd_yaml() {
    python3 - <<'PY'
import sys
import yaml

doc = yaml.safe_load(sys.stdin)
if not isinstance(doc, dict):
    sys.exit(1)

for key in (
    "status",
    "metadata.resourceVersion",
    "metadata.uid",
    "metadata.generation",
    "metadata.creationTimestamp",
    "metadata.managedFields",
    "metadata.annotations.kubectl.kubernetes.io/last-applied-configuration",
):
    if "." in key:
        parent, child = key.split(".", 1)
        if parent in doc and isinstance(doc[parent], dict):
            doc[parent].pop(child, None)
    else:
        doc.pop(key, None)

yaml.safe_dump(doc, sys.stdout, sort_keys=False, default_flow_style=False)
PY
}

dump_crds_from_cluster() {
    local version=$1
    local ns=$2
    local csv=$3
    local out_dir=$4
    local crd count=0

    mkdir -p "$out_dir"

    while IFS= read -r crd; do
        [ -n "$crd" ] || continue
        if ! oc get crd "$crd" >/dev/null 2>&1; then
            log "⚠️  ${version}: CRD ${crd} listed by CSV but not present on cluster; skipping."
            continue
        fi
        oc get crd "$crd" -o yaml | clean_cluster_crd_yaml > "${out_dir}/${crd}.yaml"
        count=$((count + 1))
    done < <(get_owned_crd_names "$csv" "$ns")

    printf '%s' "$count"
}

dump_crds_from_bundle() {
    local version=$1
    local out_dir=$2
    local work_dir=$3
    local pull_secret=$4
    local bundle_image="${BUNDLE_IMAGE_BASE}:${version}"
    local extract_dir="${work_dir}/extract-${version}"
    local manifest_dir manifest count=0

    mkdir -p "$out_dir" "$extract_dir"

    local extract_cmd=(oc image extract "$bundle_image" --path /manifests/:. --confirm)
    if [ -n "$pull_secret" ]; then
        extract_cmd+=(--registry-config "$pull_secret")
    fi

    log "📥 ${version}: extracting CRDs from ${bundle_image}..."
    if ! (cd "$extract_dir" && "${extract_cmd[@]}"); then
        die "Failed to extract operator bundle image for AAP ${version}."
    fi

    if [ -d "${extract_dir}/manifests" ]; then
        manifest_dir="${extract_dir}/manifests"
    else
        manifest_dir="$extract_dir"
    fi

    shopt -s nullglob
    for manifest in "$manifest_dir"/*.yaml "$manifest_dir"/*.yml; do
        [ -f "$manifest" ] || continue
        if grep -q '^kind: CustomResourceDefinition' "$manifest"; then
            cp "$manifest" "${out_dir}/$(basename "$manifest")"
            count=$((count + 1))
        fi
    done
    shopt -u nullglob

    if [ "$count" -eq 0 ]; then
        die "No CustomResourceDefinition manifests found in bundle for AAP ${version}."
    fi

    printf '%s' "$count"
}

write_manifest() {
    local manifest_file=$1
    shift
    local rows=("$@")

    {
        printf 'generated_at: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf 'cluster: %s\n' "$(oc whoami --show-server 2>/dev/null || echo unknown)"
        printf 'source: %s\n' "$SOURCE"
        printf 'operators:\n'
        local row
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r version ns csv channel phase owned_count crd_count <<< "$row"
            [ -n "$version" ] || continue
            printf '  - version: "%s"\n' "$version"
            printf '    namespace: "%s"\n' "$ns"
            printf '    csv: "%s"\n' "$csv"
            printf '    channel: "%s"\n' "$channel"
            printf '    subscription_state: "%s"\n' "$phase"
            printf '    csv_owned_crds: %s\n' "$owned_count"
            printf '    dumped_crds: %s\n' "$crd_count"
            printf '    output_dir: "%s/%s"\n' "$OUTPUT_DIR" "$version"
        done
    } > "$manifest_file"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            [ -n "${2:-}" ] || die "--output-dir requires a path."
            OUTPUT_DIR=$2
            shift 2
            ;;
        --source)
            [ -n "${2:-}" ] || die "--source requires bundle or cluster."
            SOURCE=$2
            shift 2
            ;;
        --namespaces)
            [ -n "${2:-}" ] || die "--namespaces requires a comma-separated list."
            mapfile -t NAMESPACES < <(parse_csv_list "$2")
            shift 2
            ;;
        --versions)
            [ -n "${2:-}" ] || die "--versions requires a comma-separated list."
            mapfile -t VERSIONS < <(parse_csv_list "$2")
            shift 2
            ;;
        --pull-secret)
            [ -n "${2:-}" ] || die "--pull-secret requires a path."
            PULL_SECRET=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unexpected argument: $1"
            ;;
    esac
done

case "$SOURCE" in
    bundle|cluster) ;;
    *) die "Unsupported source '${SOURCE}'. Use bundle or cluster." ;;
esac

for cmd in oc grep python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "'${cmd}' is required but not installed."
done

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    die "python3 PyYAML is required for cluster CRD cleanup. Install python3-pyyaml or use --source bundle."
fi

if ! oc whoami >/dev/null 2>&1; then
    die "You are not logged into an OpenShift cluster. Run 'oc login' first."
fi

for version in "${VERSIONS[@]}"; do
    is_supported_version "$version" || die "Unsupported version '${version}'."
done

WORK_DIR=$(mktemp -d)
PULL_SECRET_PATH=""
MANIFEST_ROWS=()

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"

log "🔍 Discovering AAP operators (package: ${AAP_PACKAGE})..."
mapfile -t OPERATORS < <(discover_operators)

if [ "${#OPERATORS[@]}" -eq 0 ]; then
    die "No AAP operator subscriptions found. Check cluster access or pass --namespaces."
fi

if [ "$SOURCE" = "bundle" ]; then
    if RESOLVED_PULL_SECRET=$(resolve_pull_secret "$WORK_DIR"); then
        PULL_SECRET_PATH=$RESOLVED_PULL_SECRET
        if [ "$PULL_SECRET_PATH" = "${WORK_DIR}/cluster-pull-secret.json" ]; then
            log "📦 Using cluster pull secret from openshift-config/pull-secret"
        else
            log "📦 Using pull secret: ${PULL_SECRET_PATH}"
        fi
    else
        log "⚠️  No pull secret found; relying on existing registry credentials for bundle extraction."
    fi
fi

log "📁 Writing CRDs to: ${OUTPUT_DIR}"
log ""

for entry in "${OPERATORS[@]}"; do
    IFS=$'\t' read -r version ns csv channel phase owned_count <<< "$entry"
    version_dir="${OUTPUT_DIR}/${version}"

    log "⚙️  AAP ${version} (namespace: ${ns}, CSV: ${csv}, owned CRDs: ${owned_count})"

    if [ "$SOURCE" = "bundle" ]; then
        crd_count=$(dump_crds_from_bundle "$version" "$version_dir" "$WORK_DIR" "$PULL_SECRET_PATH")
    else
        log "📋 ${version}: dumping cluster CRDs owned by CSV..."
        crd_count=$(dump_crds_from_cluster "$version" "$ns" "$csv" "$version_dir")
    fi

    DUMPED_TOTAL=$((DUMPED_TOTAL + crd_count))
    MANIFEST_ROWS+=("${version}"$'\t'"${ns}"$'\t'"${csv}"$'\t'"${channel}"$'\t'"${phase}"$'\t'"${owned_count}"$'\t'"${crd_count}")
    log "✅ ${version}: wrote ${crd_count} CRD file(s) to ${version_dir}/"
    log ""
done

write_manifest "${OUTPUT_DIR}/manifest.yaml" "${MANIFEST_ROWS[@]}"
log "📝 Wrote discovery manifest: ${OUTPUT_DIR}/manifest.yaml"
log "🎉 Done. Dumped ${DUMPED_TOTAL} CRD file(s) across ${#MANIFEST_ROWS[@]} AAP version(s)."

if [ "$SOURCE" = "cluster" ]; then
    log ""
    log "Note: CRDs are cluster-scoped. When multiple AAP versions are installed, live cluster"
    log "schemas usually reflect the newest operator. Prefer --source bundle for version-accurate schemas."
fi
