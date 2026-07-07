# dump-aap-crds

Discover installed Ansible Automation Platform (AAP) operators on an OpenShift cluster and dump their CustomResourceDefinitions to local YAML files.

Use the output as schema reference when generating example manifests that document every available CR field, default value, and description.

## Prerequisites

- Logged into an OpenShift cluster (`oc login`)
- [`oc`](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) CLI
- `python3` with PyYAML (required for `--source cluster` cleanup)
- For `--source bundle` (default): permission to read `pull-secret` in `openshift-config`, or a local registry config for `registry.redhat.io`

## What it does

1. Scans cluster subscriptions for `ansible-automation-platform-operator`.
2. Reads each namespace's channel, installed CSV, and owned CRD list.
3. Writes CRD YAML files under a versioned output directory (for example `2.4/`, `2.7/`).
4. Writes `manifest.yaml` summarizing what was discovered and dumped.

## CRD source modes

| Mode | Flag | Description |
|------|------|-------------|
| **bundle** (default) | `--source bundle` | Extracts CRDs from `registry.redhat.io/ansible-automation-platform/platform-operator-bundle:<version>`. Best for version-accurate schemas when multiple AAP versions share one cluster. |
| **cluster** | `--source cluster` | Dumps live CRDs from the cluster for each CSV's owned CRD names. Faster, but cluster-scoped CRDs usually reflect only the newest operator schema. |

## Usage

```bash
chmod +x dump-aap-crds.sh

# Dump all discovered AAP versions to the default output directory
./dump-aap-crds.sh

# Dump only selected namespaces / versions
./dump-aap-crds.sh --namespaces aap24,aap27 --versions 2.4,2.7

# Dump live cluster CRDs instead of bundle manifests
./dump-aap-crds.sh --source cluster

# Custom output location
./dump-aap-crds.sh --output-dir /tmp/aap-crds
```

### Default output directory

By default, CRDs are written to a `crd-dumps/` subfolder next to the script:

```text
dump-aap-crds/crd-dumps/
  manifest.yaml
  2.4/
    automationcontrollers.automationcontroller.ansible.com.yaml
    ...
  2.5/
  2.6/
  2.7/
```

### Options

| Option | Description |
|--------|-------------|
| `--output-dir PATH` | Destination directory for dumped CRDs |
| `--source bundle\|cluster` | Where to read CRD definitions (default: `bundle`) |
| `--namespaces LIST` | Comma-separated namespaces to scan (default: auto-discover) |
| `--versions LIST` | Comma-separated versions to include (`2.4`, `2.5`, `2.6`, `2.7`) |
| `--pull-secret PATH` | Registry config for bundle extraction |
| `PULL_SECRET` env var | Same as `--pull-secret` |
| `-h`, `--help` | Show usage |

## Example cluster layout

This script expects one AAP operator subscription per namespace, such as:

| Namespace | Channel | Example CSV |
|-----------|---------|-------------|
| `aap24` | `stable-2.4` | `aap-operator.v2.4.0-0....` |
| `aap25` | `stable-2.5` | `aap-operator.v2.5.0-0....` |
| `aap26` | `stable-2.6` | `aap-operator.v2.6.0-0....` |
| `aap27` | `stable-2.7` | `aap-operator.v2.7.0-0....` |

Subscription names may vary; discovery matches on package name `ansible-automation-platform-operator`.

## Expected output

```text
🔍 Discovering AAP operators (package: ansible-automation-platform-operator)...
📦 Using cluster pull secret from openshift-config/pull-secret
📁 Writing CRDs to: .../dump-aap-crds/crd-dumps

⚙️  AAP 2.4 (namespace: aap24, CSV: aap-operator.v2.4.0-0...., owned CRDs: 19)
📥 2.4: extracting CRDs from registry.redhat.io/.../platform-operator-bundle:2.4...
✅ 2.4: wrote 19 CRD file(s) to .../2.4/

...

📝 Wrote discovery manifest: .../manifest.yaml
🎉 Done. Dumped 96 CRD file(s) across 4 AAP version(s).
```

Exact CRD counts vary by AAP version.

## Troubleshooting

**No AAP operator subscriptions found**

- Confirm operators are installed: `oc get subscription -A | grep ansible-automation-platform`
- Pass explicit namespaces: `./dump-aap-crds.sh --namespaces aap24,aap25,aap26,aap27`

**Failed to extract operator bundle image**

- Confirm your subscription includes AAP on `registry.redhat.io`
- Provide a pull secret: `./dump-aap-crds.sh --pull-secret ~/pull-secret`

**Cluster source shows identical schemas for all versions**

- Expected when multiple AAP operators share one cluster. Use `--source bundle` instead.

## Related

- [restore-aap-crds](../restore-aap-crds/) — re-applies AAP CRDs from the operator bundle image to a cluster
