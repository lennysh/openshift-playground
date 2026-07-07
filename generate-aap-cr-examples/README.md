# generate-aap-cr-examples

Generate exhaustive Ansible Automation Platform Custom Resource example YAML from operator CRD OpenAPI schemas.

Use this after [dump-aap-crds](../dump-aap-crds/) to produce reference manifests that document every available `spec` field. Fields with CRD defaults are written explicitly; fields without defaults appear as commented placeholders.

Currently supports:

- `AutomationController` → `controller.yml`
- `AutomationHub` → `hub.yml`
- `EDA` → `eda.yml`
- `AnsibleAutomationPlatform` → `aap.yml` (2.5+; embeds full component specs under `spec.controller`, `spec.hub`, `spec.eda`)

## Prerequisites

- Python 3.9+
- PyYAML (`pip install pyyaml`)
- CRD dumps from [dump-aap-crds](../dump-aap-crds/) (or any compatible CRD YAML directory)

## Usage

```bash
cd generate-aap-cr-examples
chmod +x generate-aap-cr-examples.sh

# Write examples to a target directory using bundled 2.4 CRD dumps
./generate-aap-cr-examples.sh \
  --version 2.4 \
  --output-dir /path/to/aap-notes/config-examples/AAP24/openshift

# Custom CRD source and subset of kinds
./generate-aap-cr-examples.sh \
  --crd-dir ../dump-aap-crds/crd-dumps/2.7 \
  --output-dir ./out/2.7 \
  --kinds AnsibleAutomationPlatform
```

For AAP 2.5+ platform CRs, pass all four CRD files in the same `--crd-dir` (platform + component CRDs):

```bash
python3 generate-aap-cr-examples.py \
  --version 2.5 \
  --crd-dir /path/to/aap-notes/config-examples/.crd-dumps/2.5 \
  --output-dir /path/to/aap-notes/config-examples/AAP25/openshift \
  --kinds AnsibleAutomationPlatform
```

### Options

| Option | Description |
|--------|-------------|
| `--version VERSION` | AAP version under the default CRD root (default: `2.4`) |
| `--crd-dir PATH` | CRD dump directory (default: `../dump-aap-crds/crd-dumps/<version>`) |
| `--output-dir PATH` | **Required.** Destination for generated YAML |
| `--namespace NAME` | `metadata.namespace` value (default: `aap`) |
| `--kinds LIST` | Comma-separated kinds (default: all three) |

## What it generates

Each output file includes:

- Section headers grouping related spec fields
- Active example wiring for common secrets (Postgres, encryption keys, route TLS, etc.)
- `# notsecret` suffixes on secret reference fields (for git leak scanner allowlists)
- CRD default values where defined
- Commented placeholders for unset / environment-specific options

Secret name wiring and “always comment” fields are defined in `generate-aap-cr-examples.py` (`OVERRIDES`, `COMMENT_PATHS`). Adjust those constants for your layout before regenerating.

## Typical workflow

```bash
# 1. Dump CRDs from cluster or operator bundle
cd ../dump-aap-crds
./dump-aap-crds.sh --versions 2.4

# 2. Generate exhaustive CR examples
cd ../generate-aap-cr-examples
./generate-aap-cr-examples.sh \
  --version 2.4 \
  --output-dir ../../aap-notes/config-examples/AAP24/openshift
```

Generated CR files are meant to pair with hand-maintained secret manifests (`secrets-controller.yml`, `secrets-hub.yml`, `secrets-eda.yml`) in the target repo.

## Related

- [dump-aap-crds](../dump-aap-crds/) — fetch version-accurate CRD schemas
- [aap-notes](https://github.com/lennysh/aap-notes) — example OpenShift manifests consuming this output
