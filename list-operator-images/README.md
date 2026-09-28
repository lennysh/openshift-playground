# list-operator-images

Extract container image references (paths, tags, and digests) from an OLM
[ClusterServiceVersion](https://docs.openshift.com/container-platform/latest/operators/understanding/olm-understanding-operatorgroups.html)
(CSV).

Use this when you want the image set an operator release declares for itself and
its operands — for mirroring, air-gap planning, or comparing versions.

## Prerequisites

- `python3` with [PyYAML](https://pyyaml.org/)
- For cluster mode: logged into OpenShift (`oc login`) and the `oc` CLI

## What it extracts

| Source | Description |
|--------|-------------|
| `relatedImages` | Images listed on `spec.relatedImages` (usual disconnected-mirror set) |
| `csv-deployment` | Container / initContainer images in the CSV install strategy |
| `csv-env` | Env vars matching `*IMAGE*` on those containers (e.g. `RELATED_IMAGE_*`) |
| `runtime-*` | Optional live Deployment images/env (`--include-runtime`) |

**Caveat:** This is the operator’s *declared / injected* set. A CR can still
override image fields or enable optional components that never appear on the
CSV. Treat the output as the default pull list for that CSV release, not a
proof of every possible runtime pull.

## Usage

```bash
chmod +x list-operator-images.sh

# Live CSV on the cluster
./list-operator-images.sh --csv aap-operator.v2.5.0-0.172.16.1.4 -n aap25

# CSV file you already exported
./list-operator-images.sh --file ./aap-operator.csv.yaml

# Pipe from oc
oc get csv aap-operator.v2.5.0-0.172.16.1.4 -n aap25 -o yaml \
  | ./list-operator-images.sh --file - --format list

# Unique image list only (good for mirroring)
./list-operator-images.sh --file ./csv.yaml --format list -o images.txt

# JSON with metadata
./list-operator-images.sh --csv "$CSV" -n "$NS" --format json

# Also merge env from the live operator Deployment(s)
./list-operator-images.sh --csv "$CSV" -n "$NS" --include-runtime
```

### Options

| Option | Description |
|--------|-------------|
| `--csv NAME` | CSV name on the cluster (requires `-n`) |
| `-n`, `--namespace NS` | Namespace of the CSV |
| `--file PATH` | CSV YAML/JSON path, or `-` for stdin |
| `--format tsv\|list\|json` | Output format (default: `tsv`) |
| `--include-runtime` | Merge images/env from live Deployments named in the CSV |
| `-o`, `--output PATH` | Write to a file instead of stdout |
| `-h`, `--help` | Show usage |

### Output formats

- **tsv** (default) — columns: `source`, `name`, `image`, `detail`
- **list** — unique image references, one per line
- **json** — `{ "meta": {...}, "images": [ ... ] }`

A one-line summary (CSV name, unique image count) is always printed on stderr.

## Related

- [dump-aap-crds](../dump-aap-crds/) — discover AAP CSVs and dump owned CRDs
- [restore-aap-crds](../restore-aap-crds/) — re-apply AAP CRDs from the operator bundle image
