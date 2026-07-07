# openshift-playground

Community scripts and utilities for OpenShift and Red Hat Ansible Automation Platform (AAP) operations.

> **Note:** These tools are unofficial and not supported by Red Hat. Use at your own discretion in non-production environments first.

## Contents

| Path | Description |
|------|-------------|
| [dump-aap-crds/](dump-aap-crds/) | Discover installed AAP operators and dump version-specific CRDs to local YAML for schema reference |
| [generate-aap-cr-examples/](generate-aap-cr-examples/) | Generate exhaustive Controller, Hub, and EDA CR example YAML from dumped CRD schemas |
| [restore-aap-crds/](restore-aap-crds/) | Re-apply AAP CRDs from the operator bundle image when definitions are missing or out of sync |

## dump-aap-crds

Discovers AAP operator subscriptions across cluster namespaces (for example `aap24` through `aap27`) and dumps CustomResourceDefinitions to `dump-aap-crds/crd-dumps/` for use when generating example config files.

```bash
cd dump-aap-crds
chmod +x dump-aap-crds.sh
./dump-aap-crds.sh
```

See [dump-aap-crds/README.md](dump-aap-crds/README.md) for source modes, options, and troubleshooting.

## generate-aap-cr-examples

Turns CRD dumps into exhaustive example manifests (`controller.yml`, `hub.yml`, `eda.yml`) with CRD defaults populated and optional fields commented.

```bash
cd generate-aap-cr-examples
chmod +x generate-aap-cr-examples.sh
./generate-aap-cr-examples.sh --version 2.4 --output-dir /path/to/output
```

See [generate-aap-cr-examples/README.md](generate-aap-cr-examples/README.md) for options and workflow.

## restore-aap-crds

Restores CustomResourceDefinitions for AAP operator versions 2.4 through 2.7. CRDs are extracted from the official Red Hat operator bundle image and applied to the cluster with `oc apply`.

**When to use:** CRDs were deleted or corrupted but the AAP operator subscription and InstallPlan are still present.

```bash
cd restore-aap-crds
chmod +x restore-aap-crds.sh
./restore-aap-crds.sh 2.7
```

When logged in with `oc`, the cluster pull secret is used automatically — no manual pull secret file is required.

See [restore-aap-crds/README.md](restore-aap-crds/README.md) for supported versions, pull secret options, expected output, and troubleshooting.

Original concept by [Michael Tipton](https://github.com/CastawayEGR).

## Requirements

Most scripts in this repo expect:

- An active OpenShift login (`oc login`)
- The OpenShift CLI (`oc`)
- Common shell utilities (`bash`, `grep`, etc.)

Individual tools may have additional requirements; check each folder's README.

## Contributing

Pull requests welcome. When adding a new tool, include a folder-level README and add it to the Contents table above.
