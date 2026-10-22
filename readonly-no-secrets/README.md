# readonly-no-secrets

Create an OpenShift **read-only** `ClusterRole` for learners who should explore
the console/CLI (layouts, pods, logs, Deployments, Routes, Operators, …) **without
reading Secrets**.

## Why a custom role?

| Built-in role | Problem for this use case |
|---------------|---------------------------|
| `view` | Namespace-scoped when bound locally; good for one project, not full-cluster sightseeing. Does not include Secrets (good), but is narrower than `cluster-reader`. |
| `cluster-reader` | Cluster-wide read of *most* objects, **including Secrets** (and other credential-bearing objects). Too open for training accounts. |

Kubernetes / OpenShift RBAC is **allow-only** — there is no “deny Secrets” rule.
You cannot grant `resources: ["*"]` and then subtract Secrets. The workable
pattern is:

1. Export the live aggregated `cluster-reader` rules (they already track CRDs via aggregation).
2. Remove `aggregationRule` so you own a **static snapshot**.
3. Strip Secrets (and a few related escalation vectors).
4. Apply as a **new** ClusterRole (never edit the system `cluster-reader`).
5. Bind that role to a **Group** once; add/remove users on the group afterward.

Red Hat documents the default roles (including `cluster-reader` / `view`) in
[Using RBAC to define and apply permissions](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/authentication_and_authorization/using-rbac).

## Recommended: bind a Group

Binding each user to the ClusterRole works, but a **Group** is simpler day-to-day:

- Create Group + ClusterRoleBinding **once**
- Grant/revoke access with `oc adm groups add-users` / `remove-users` (no new bindings)
- Membership is visible with `oc get group …`

Default group name from the setup script: `cluster-explorers`.

If your IdP (LDAP/OIDC/GitHub) already syncs a group into OpenShift, skip creating
a local Group and just bind that existing group with `./bind.sh --group <idp-group>`.

## Prerequisites

- Logged into the cluster as a user who can create ClusterRoles / Groups / bindings (`cluster-admin` is typical)
- [`oc`](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) CLI
- `python3` (stdlib only; used to filter the exported JSON)

## Quick start

```bash
cd readonly-no-secrets
chmod +x setup-group.sh apply-clusterrole.sh bind.sh generate-clusterrole.py

# Day 0: role + group + binding (optional initial members)
./setup-group.sh alice@example.com bob@example.com

# Day 2+: just manage membership — no RBAC changes
oc adm groups add-users cluster-explorers carol@example.com
oc adm groups remove-users cluster-explorers alice@example.com
oc get group cluster-explorers
```

Custom group name or single-project scope:

```bash
./setup-group.sh --group training-readonly learner1 learner2
./setup-group.sh --group demo-viewers -n demo-app
```

Per-user binding is still available when a group is overkill:

```bash
./apply-clusterrole.sh
./bind.sh --user learner@example.com
```

### Verify

```bash
oc auth can-i get pods -A --as=alice@example.com --as-group=cluster-explorers          # yes
oc auth can-i get pods/log -n demo-app --as=alice@example.com --as-group=cluster-explorers  # yes
oc auth can-i get secrets -A --as=alice@example.com --as-group=cluster-explorers       # no
oc auth can-i create pods --as=alice@example.com --as-group=cluster-explorers          # no
```

## What gets stripped

The generator removes these resources / subresources from every rule copied out
of `cluster-reader`:

| Resource | Why |
|----------|-----|
| `secrets` | Credential material (tokens, passwords, TLS keys, …) |
| `oauthclients` | Often contain OAuth client secrets |
| `oauthaccesstokens` / `oauthauthorizetokens` | Identity tokens |
| `pods/exec`, `pods/attach`, `pods/portforward` | Not needed for browsing; can escalate ([RBAC rules allow execution privileges](https://access.redhat.com/solutions/6989997)) |
| `serviceaccounts/token` | Minting SA tokens |

Everything else that `cluster-reader` could read (Pods, logs via `pods/log`,
ConfigMaps, Deployments, Routes, Nodes, CRDs present at generation time, …)
stays, as long as it appeared in the exported rules.

## Scripts

| Script | Purpose |
|--------|---------|
| [`setup-group.sh`](setup-group.sh) | **Recommended:** create Group + ensure role + bind once (+ optional users) |
| [`apply-clusterrole.sh`](apply-clusterrole.sh) | Export → filter → `oc apply` the ClusterRole only |
| [`bind.sh`](bind.sh) | Bind an existing role to a user or group |
| [`generate-clusterrole.py`](generate-clusterrole.py) | Pure transform (stdin JSON → YAML/JSON); used by apply |

```bash
# Preview role YAML without applying
./apply-clusterrole.sh --dry-run | less

# Preview full group setup
./setup-group.sh --dry-run alice@example.com

# Custom role name + save a copy
./apply-clusterrole.sh --name learner-readonly -o ./learner-readonly.yaml
```

Re-run `./apply-clusterrole.sh` after installing new Operators/CRDs if learners
need read access to those new APIs (the snapshot does not auto-update once
aggregation is removed).

## Manual `oc` cookbook (no scripts)

Equivalent steps if you prefer to drive everything by hand:

```bash
# 1) Export the system role
oc get clusterrole cluster-reader -o yaml > /tmp/cluster-reader.yaml

# 2) Edit /tmp/cluster-reader.yaml:
#    - Change metadata.name to e.g. cluster-reader-no-secrets
#    - Delete aggregationRule entirely
#    - Delete metadata.creationTimestamp / resourceVersion / uid / managedFields
#    - Remove any rule resources named secrets (or drop secrets from mixed lists)
#    - Remove oauthclients / oauth*tokens / pods/exec / pods/attach /
#      pods/portforward / serviceaccounts/token if present
#    - Do NOT keep aggregate-to-* labels

# Or generate with the helper:
oc get clusterrole cluster-reader -o json \
  | python3 generate-clusterrole.py --name cluster-reader-no-secrets \
  > /tmp/cluster-reader-no-secrets.yaml

# 3) Apply
oc apply -f /tmp/cluster-reader-no-secrets.yaml

# 4) Group + bind once (recommended)
oc adm groups new cluster-explorers
oc create clusterrolebinding cluster-explorers-cluster-reader-no-secrets \
  --clusterrole=cluster-reader-no-secrets \
  --group=cluster-explorers

# 5) Add / remove learners anytime
oc adm groups add-users cluster-explorers learner@example.com
oc adm groups remove-users cluster-explorers learner@example.com

# Per-user binding instead (optional)
oc create clusterrolebinding learner-readonly \
  --clusterrole=cluster-reader-no-secrets \
  --user=learner@example.com

# One project only
oc create rolebinding learner-readonly \
  --clusterrole=cluster-reader-no-secrets \
  --group=cluster-explorers \
  -n demo-app
```

### Namespace-only alternative

If learners only need one project and you are fine with the narrower built-in
`view` role (already excludes Secrets):

```bash
oc adm policy add-role-to-user view learner@example.com -n demo-app
```

That does **not** give cluster-wide browsing (other projects, nodes, cluster
Operators, etc.).

## Security caveats (still sensitive without Secrets)

This role reduces credential exposure; it is **not** a hard security boundary.

- **ConfigMaps** can still hold passwords or certificates people pasted in by mistake.
- **Routes** with edge/reencrypt TLS may include private keys under `.spec.tls.key`.
- **Custom resources** / Operator CRs sometimes embed credentials in status or spec.
- **Pod specs** show env var *names*, projected volume mounts, and Secret *references* (not values).
- Learners can still read **most** cluster configuration useful for reconnaissance.

Use dedicated training clusters / non-production projects when possible. Prefer
`--namespace` bindings when cluster-wide access is unnecessary.

## Uninstall

```bash
oc delete clusterrolebinding cluster-explorers-cluster-reader-no-secrets --ignore-not-found
oc delete group cluster-explorers --ignore-not-found
oc delete clusterrole cluster-reader-no-secrets --ignore-not-found
# If you used a namespaced RoleBinding:
# oc delete rolebinding <name> -n <namespace>
```

## Requirements

Same as the rest of this repo: active `oc login`, `oc` CLI, and (for the
generator) `python3`.
