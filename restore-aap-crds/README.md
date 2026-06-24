# restore-aap-crds

Re-applies Ansible Automation Platform (AAP) CustomResourceDefinitions by extracting them from the official operator bundle image and applying them to the cluster.

Use this when CRDs were accidentally deleted, corrupted, or are otherwise missing while the AAP operator is still installed.

## Prerequisites

- Logged into an OpenShift cluster (`oc login`)
- [`oc`](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) CLI
- Permission to read `pull-secret` in the `openshift-config` namespace (included for most cluster admins)
- Cluster subscription with access to AAP images on `registry.redhat.io`

## Supported versions

| Version | Bundle image |
|---------|----------------|
| 2.4     | `registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.4` |
| 2.5     | `registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.5` |
| 2.6     | `registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.6` |
| 2.7     | `registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.7` |

## Usage

```bash
./restore-aap-crds.sh <version> [--pull-secret PATH]
```

| Argument / option     | Description |
|-----------------------|-------------|
| `version`             | AAP version (`2.4`, `2.5`, `2.6`, or `2.7`) |
| `--pull-secret PATH`  | Override registry config for `registry.redhat.io` |
| `PULL_SECRET` env var | Same as `--pull-secret` |
| `-h`, `--help`        | Show usage |

No namespace argument is required — CRDs are cluster-scoped resources.

### Pull secret resolution

When logged in with `oc`, the script uses the cluster pull secret automatically. Override only if needed:

1. `--pull-secret` flag or `PULL_SECRET` environment variable
2. Cluster pull secret from `openshift-config/pull-secret` (default)
3. `~/pull-secret`, `~/.pull-secret`, or `~/.docker/config.json`

The cluster pull secret is written to a temporary file during extraction and removed when the script exits.

### Examples

```bash
chmod +x restore-aap-crds.sh

# Uses cluster pull secret automatically
./restore-aap-crds.sh 2.7

# Override with a local pull secret
./restore-aap-crds.sh 2.7 --pull-secret ~/pull-secret
```

## What it does

1. Resolves a registry pull secret (cluster secret by default).
2. Extracts `/manifests/` from the AAP operator bundle image for the requested version.
3. Filters manifests to `CustomResourceDefinition` resources only.
4. Applies each CRD to the cluster with `oc apply`.

This is equivalent to extracting and applying CRDs manually:

```bash
# Extract a single CRD from the bundle
oc image extract \
    registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.7 \
    --path /manifests/eda.ansible.com_edas.yaml:. \
    --registry-config ~/pull-secret --confirm

oc apply -f eda.ansible.com_edas.yaml
```

The script extracts the full manifests directory and applies all CRDs in one run.

## Expected output

On success you should see one `configured` (or `created`) line per CRD, followed by:

```
🎉 Success! Re-applied 27 AAP 2.7 CRD(s) to the cluster.
```

The exact CRD count may vary by AAP version.

### `last-applied-configuration` warnings

If CRDs were originally installed by OLM rather than `oc apply`, you may see warnings like:

```
Warning: resource customresourcedefinitions/... is missing the kubectl.kubernetes.io/last-applied-configuration annotation...
```

These are expected and harmless. `oc apply` adds the annotation and continues.

## Troubleshooting

**Failed to extract operator bundle image**

- Confirm the cluster subscription includes AAP on `registry.redhat.io`.
- Verify pull secret access: `oc get secret pull-secret -n openshift-config`
- Override with an explicit pull secret: `./restore-aap-crds.sh 2.7 --pull-secret ~/pull-secret`

**No manifest YAML files found after extracting**

- Confirm the bundle image tag matches your AAP version.
- Test a manual extract (see [What it does](#what-it-does)).

**Permission denied running the script**

```bash
chmod +x restore-aap-crds.sh
```

**Not logged into OpenShift**

```bash
oc login
```

**Cannot read cluster pull secret**

Your `oc` user needs permission to read secrets in `openshift-config`. Use `--pull-secret` with a local registry config instead.

## Credits

Original concept by [Michael Tipton](https://github.com/CastawayEGR) ([@CastawayEGR](https://github.com/CastawayEGR)).
