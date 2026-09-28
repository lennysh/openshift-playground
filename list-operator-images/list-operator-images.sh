#!/usr/bin/env bash
#
# list-operator-images - Extract container image references from an OLM ClusterServiceVersion.
#
# Accepts a live CSV (name + namespace via oc) or a CSV manifest file (YAML/JSON).
# Prints relatedImages, deployment images, and IMAGE-related env vars the operator
# typically uses when reconciling owned CRs.

set -euo pipefail

CSV_NAME=""
CSV_NAMESPACE=""
CSV_FILE=""
OUTPUT_FORMAT="tsv"
INCLUDE_RUNTIME=0
OUTPUT_FILE=""

usage() {
    cat <<EOF
Usage:
  $0 --csv NAME -n NAMESPACE [options]
  $0 --file PATH [options]
  $0 --file - [options]          # read CSV YAML/JSON from stdin

Extract container image paths (and tags/digests) declared by an OpenShift
Operator Lifecycle Manager ClusterServiceVersion (CSV).

Sources consulted in the CSV:
  - spec.relatedImages
  - install deployment container / initContainer images
  - env vars whose names match IMAGE (e.g. RELATED_IMAGE_*)

With --include-runtime and a cluster CSV, also merges env from the live
operator Deployment(s) in the CSV namespace (useful if values were patched).

Options:
  --csv NAME            CSV name on the cluster (requires -n / --namespace)
  -n, --namespace NS    Namespace of the CSV
  --file PATH           Path to a CSV YAML/JSON file, or '-' for stdin
  --format FORMAT       Output format: tsv (default), list, json
  --include-runtime     Also read live Deployment env (cluster CSV only)
  -o, --output PATH     Write results to PATH instead of stdout
  -h, --help            Show this help

Examples:
  $0 --csv aap-operator.v2.5.0-0.172.16.1.4 -n aap25
  $0 --file ./aap-operator.csv.yaml --format list
  oc get csv aap-operator.v2.5.0-0.172.16.1.4 -n aap25 -o yaml | $0 --file - --format json
EOF
}

log() {
    printf '%s\n' "$*" >&2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --csv)
            [ -n "${2:-}" ] || die "--csv requires a name."
            CSV_NAME=$2
            shift 2
            ;;
        -n|--namespace)
            [ -n "${2:-}" ] || die "--namespace requires a value."
            CSV_NAMESPACE=$2
            shift 2
            ;;
        --file)
            [ -n "${2:-}" ] || die "--file requires a path (or '-')."
            CSV_FILE=$2
            shift 2
            ;;
        --format)
            [ -n "${2:-}" ] || die "--format requires tsv, list, or json."
            OUTPUT_FORMAT=$2
            shift 2
            ;;
        --include-runtime)
            INCLUDE_RUNTIME=1
            shift
            ;;
        -o|--output)
            [ -n "${2:-}" ] || die "--output requires a path."
            OUTPUT_FILE=$2
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

case "$OUTPUT_FORMAT" in
    tsv|list|json) ;;
    *) die "Unsupported format '${OUTPUT_FORMAT}'. Use tsv, list, or json." ;;
esac

for cmd in python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "'${cmd}' is required but not installed."
done

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    die "python3 PyYAML is required. Install python3-pyyaml."
fi

WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CSV_JSON="${WORK_DIR}/csv.json"
RUNTIME_JSON="${WORK_DIR}/runtime.json"

load_csv_from_cluster() {
    command -v oc >/dev/null 2>&1 || die "'oc' is required for --csv mode."
    if ! oc whoami >/dev/null 2>&1; then
        die "You are not logged into an OpenShift cluster. Run 'oc login' first."
    fi
    [ -n "$CSV_NAMESPACE" ] || die "--csv requires -n / --namespace."

    if ! oc get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o json > "$CSV_JSON" 2>/dev/null; then
        die "CSV '${CSV_NAME}' not found in namespace '${CSV_NAMESPACE}'."
    fi
}

load_csv_from_file() {
    local path=$1
    if [ "$path" = "-" ]; then
        python3 -c '
import json, sys, yaml
doc = yaml.safe_load(sys.stdin)
if not isinstance(doc, dict):
    sys.exit("stdin did not contain a YAML/JSON object")
json.dump(doc, sys.stdout)
' > "$CSV_JSON"
        return
    fi

    [ -f "$path" ] || die "File not found: ${path}"
    python3 -c '
import json, sys, yaml
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = yaml.safe_load(f)
if not isinstance(doc, dict):
    sys.exit(f"{path} did not contain a YAML/JSON object")
json.dump(doc, sys.stdout)
' "$path" > "$CSV_JSON"
}

collect_runtime_env() {
    # Best-effort: merge env from Deployments named in the CSV install strategy.
    python3 -c '
import json, sys
csv = json.load(open(sys.argv[1], encoding="utf-8"))
deps = (
    csv.get("spec", {})
    .get("install", {})
    .get("spec", {})
    .get("deployments", [])
    or []
)
for d in deps:
    name = d.get("name")
    if name:
        print(name)
' "$CSV_JSON" > "${WORK_DIR}/deployments.txt"

    local dep ns
    ns=$(python3 -c '
import json, sys
csv = json.load(open(sys.argv[1], encoding="utf-8"))
print(csv.get("metadata", {}).get("namespace") or "")
' "$CSV_JSON")
    [ -n "$ns" ] || ns="$CSV_NAMESPACE"
    [ -n "$ns" ] || {
        log "Warning: --include-runtime skipped; no namespace available."
        printf '[]\n' > "$RUNTIME_JSON"
        return
    }

    command -v oc >/dev/null 2>&1 || {
        log "Warning: --include-runtime skipped; oc not available."
        printf '[]\n' > "$RUNTIME_JSON"
        return
    }

    python3 - "$CSV_JSON" "$ns" "${WORK_DIR}/deployments.txt" <<'PY' > "$RUNTIME_JSON"
import json
import subprocess
import sys

csv_path, ns, dep_list_path = sys.argv[1], sys.argv[2], sys.argv[3]
entries = []

with open(dep_list_path, encoding="utf-8") as f:
    names = [line.strip() for line in f if line.strip()]

for name in names:
    proc = subprocess.run(
        ["oc", "get", "deploy", name, "-n", ns, "-o", "json"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        continue
    deploy = json.loads(proc.stdout)
    pod_spec = (
        deploy.get("spec", {})
        .get("template", {})
        .get("spec", {})
        or {}
    )
    for kind in ("containers", "initContainers"):
        for c in pod_spec.get(kind) or []:
            image = c.get("image")
            if image:
                entries.append(
                    {
                        "source": "runtime-deployment",
                        "name": f"{name}/{c.get('name', kind)}",
                        "image": image,
                        "detail": kind,
                    }
                )
            for env in c.get("env") or []:
                ename = env.get("name") or ""
                if "IMAGE" not in ename.upper():
                    continue
                value = env.get("value")
                if value:
                    entries.append(
                        {
                            "source": "runtime-env",
                            "name": ename,
                            "image": value,
                            "detail": f"{name}/{c.get('name', '')}",
                        }
                    )

json.dump(entries, sys.stdout)
PY
}

if [ -n "$CSV_FILE" ] && [ -n "$CSV_NAME" ]; then
    die "Use either --file or --csv, not both."
fi

if [ -n "$CSV_FILE" ]; then
    load_csv_from_file "$CSV_FILE"
elif [ -n "$CSV_NAME" ]; then
    load_csv_from_cluster
else
    die "Provide --csv NAME -n NAMESPACE or --file PATH."
fi

# Validate kind when present
python3 -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
kind = doc.get("kind")
if kind and kind != "ClusterServiceVersion":
    sys.exit(f"Expected kind ClusterServiceVersion, got {kind!r}")
' "$CSV_JSON"

if [ "$INCLUDE_RUNTIME" -eq 1 ]; then
    if [ -z "$CSV_NAME" ] && [ -z "$CSV_NAMESPACE" ]; then
        # file mode: still try if metadata.namespace is set
        :
    fi
    collect_runtime_env
else
    printf '[]\n' > "$RUNTIME_JSON"
fi

emit_results() {
    python3 - "$CSV_JSON" "$RUNTIME_JSON" "$OUTPUT_FORMAT" <<'PY'
import json
import sys

csv_path, runtime_path, fmt = sys.argv[1], sys.argv[2], sys.argv[3]
csv = json.load(open(csv_path, encoding="utf-8"))
runtime = json.load(open(runtime_path, encoding="utf-8"))

rows = []
seen = set()


def add(source, name, image, detail=""):
    if not image or not isinstance(image, str):
        return
    image = image.strip()
    if not image:
        return
    key = (source, name, image, detail)
    if key in seen:
        return
    seen.add(key)
    rows.append(
        {
            "source": source,
            "name": name or "",
            "image": image,
            "detail": detail or "",
        }
    )


spec = csv.get("spec") or {}

for item in spec.get("relatedImages") or []:
    add("relatedImages", item.get("name") or "", item.get("image") or "")

install_deps = (
    ((spec.get("install") or {}).get("spec") or {}).get("deployments") or []
)
for dep in install_deps:
    dep_name = dep.get("name") or "deployment"
    pod_spec = (
        ((dep.get("spec") or {}).get("template") or {}).get("spec") or {}
    )
    for kind in ("containers", "initContainers"):
        for c in pod_spec.get(kind) or []:
            cname = c.get("name") or kind
            add(
                "csv-deployment",
                f"{dep_name}/{cname}",
                c.get("image") or "",
                kind,
            )
            for env in c.get("env") or []:
                ename = env.get("name") or ""
                if "IMAGE" not in ename.upper():
                    continue
                add(
                    "csv-env",
                    ename,
                    env.get("value") or "",
                    f"{dep_name}/{cname}",
                )

for item in runtime:
    add(
        item.get("source") or "runtime",
        item.get("name") or "",
        item.get("image") or "",
        item.get("detail") or "",
    )

# Stable sort: relatedImages first, then csv-*, then runtime-*, by name/image
order = {
    "relatedImages": 0,
    "csv-deployment": 1,
    "csv-env": 2,
    "runtime-deployment": 3,
    "runtime-env": 4,
}
rows.sort(key=lambda r: (order.get(r["source"], 99), r["name"], r["image"]))

meta = {
    "csv": (csv.get("metadata") or {}).get("name") or "",
    "namespace": (csv.get("metadata") or {}).get("namespace") or "",
    "displayName": spec.get("displayName") or "",
    "version": spec.get("version") or "",
    "image_count": len({r["image"] for r in rows}),
    "entry_count": len(rows),
}

if fmt == "json":
    json.dump({"meta": meta, "images": rows}, sys.stdout, indent=2)
    sys.stdout.write("\n")
elif fmt == "list":
    for image in sorted({r["image"] for r in rows}):
        print(image)
else:  # tsv
    print("source\tname\timage\tdetail")
    for r in rows:
        print(f"{r['source']}\t{r['name']}\t{r['image']}\t{r['detail']}")

# Summary on stderr
print(
    f"CSV: {meta['csv'] or '(unnamed)'}  "
    f"unique images: {meta['image_count']}  "
    f"entries: {meta['entry_count']}",
    file=sys.stderr,
)
PY
}

if [ -n "$OUTPUT_FILE" ]; then
    emit_results > "$OUTPUT_FILE"
    log "Wrote ${OUTPUT_FILE}"
else
    emit_results
fi
