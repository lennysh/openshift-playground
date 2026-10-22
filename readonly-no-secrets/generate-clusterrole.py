#!/usr/bin/env python3
"""Build a static ClusterRole from OpenShift's cluster-reader, minus sensitive bits.

Kubernetes/OpenShift RBAC is allow-only (no deny rules). You cannot grant
``resources: ["*"]`` and then exclude secrets. The practical approach is to
snapshot the aggregated ``cluster-reader`` rules and drop resources that
expose credentials or enable privilege escalation via the API.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

# Resource names (and prefixes like "secrets/") to strip from every rule.
DENIED_RESOURCES = frozenset(
    {
        "secrets",
        "oauthclients",
        "oauthaccesstokens",
        "oauthauthorizetokens",
        # Subresources that escalate beyond read-only exploration
        "pods/exec",
        "pods/attach",
        "pods/portforward",
        "serviceaccounts/token",
    }
)

DENIED_PREFIXES = (
    "secrets/",
)

METADATA_DROP = (
    "creationTimestamp",
    "resourceVersion",
    "uid",
    "generation",
    "managedFields",
    "selfLink",
    "ownerReferences",
)


def resource_denied(name: str) -> bool:
    lower = name.lower()
    if lower in DENIED_RESOURCES:
        return True
    return any(lower.startswith(prefix) for prefix in DENIED_PREFIXES)


def filter_rule(rule: dict[str, Any]) -> dict[str, Any] | None:
    """Return a copy of rule with denied resources removed, or None if empty."""
    if "nonResourceURLs" in rule and "resources" not in rule:
        # Non-resource URLs (e.g. /healthz) are fine for read-only explorers.
        return dict(rule)

    resources = rule.get("resources")
    if resources is None:
        return dict(rule)

    kept = [r for r in resources if not resource_denied(r)]
    if not kept:
        return None

    out = dict(rule)
    out["resources"] = kept
    return out


def sanitize_clusterrole(
    source: dict[str, Any],
    *,
    name: str,
) -> dict[str, Any]:
    meta = dict(source.get("metadata") or {})
    for key in METADATA_DROP:
        meta.pop(key, None)
    meta["name"] = name
    # Avoid accidentally aggregating into default roles if labels were copied.
    labels = dict(meta.get("labels") or {})
    for key in list(labels):
        if key.startswith("rbac.authorization.k8s.io/aggregate-to-"):
            del labels[key]
    if labels:
        meta["labels"] = labels
    else:
        meta.pop("labels", None)

    annotations = dict(meta.get("annotations") or {})
    annotations["openshift-playground.lennysh/derived-from"] = "cluster-reader"
    annotations["openshift-playground.lennysh/purpose"] = (
        "Read-only exploration without Secrets or exec/attach"
    )
    meta["annotations"] = annotations

    rules_in = source.get("rules") or []
    rules_out: list[dict[str, Any]] = []
    for rule in rules_in:
        filtered = filter_rule(rule)
        if filtered is not None:
            rules_out.append(filtered)

    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRole",
        "metadata": meta,
        "rules": rules_out,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Transform an exported cluster-reader ClusterRole JSON into a "
            "static read-only ClusterRole without Secrets."
        )
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Write YAML/JSON to this path (default: stdout)",
    )
    parser.add_argument(
        "--name",
        default="cluster-reader-no-secrets",
        help="ClusterRole name (default: cluster-reader-no-secrets)",
    )
    parser.add_argument(
        "--format",
        choices=("json", "yaml"),
        default="yaml",
        help="Output format (default: yaml)",
    )
    args = parser.parse_args()

    try:
        source = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"Error: invalid JSON on stdin: {exc}", file=sys.stderr)
        return 1

    if source.get("kind") != "ClusterRole":
        print("Error: stdin must be a ClusterRole JSON document.", file=sys.stderr)
        return 1

    role = sanitize_clusterrole(source, name=args.name)

    if args.format == "json":
        text = json.dumps(role, indent=2) + "\n"
    else:
        try:
            import yaml  # type: ignore
        except ImportError:
            # PyYAML is not always present; emit JSON with a YAML-compatible layout
            # via a minimal emitter that is valid YAML for this structure.
            text = _to_simple_yaml(role)
        else:
            text = yaml.safe_dump(role, default_flow_style=False, sort_keys=False)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


def _to_simple_yaml(obj: Any, indent: int = 0) -> str:
    """Minimal YAML emitter for ClusterRole-shaped dict/list/scalars."""
    sp = "  " * indent
    if isinstance(obj, dict):
        if not obj:
            return sp + "{}\n"
        lines: list[str] = []
        for key, value in obj.items():
            if isinstance(value, (dict, list)):
                lines.append(f"{sp}{key}:")
                lines.append(_to_simple_yaml(value, indent + 1).rstrip("\n"))
            else:
                lines.append(f"{sp}{key}: {_yaml_scalar(value)}")
        return "\n".join(lines) + "\n"
    if isinstance(obj, list):
        if not obj:
            return sp + "[]\n"
        lines = []
        for item in obj:
            if isinstance(item, dict):
                # First key on the dash line, rest indented.
                items = list(item.items())
                if not items:
                    lines.append(f"{sp}- {{}}")
                    continue
                first_k, first_v = items[0]
                if isinstance(first_v, (dict, list)):
                    lines.append(f"{sp}- {first_k}:")
                    lines.append(_to_simple_yaml(first_v, indent + 2).rstrip("\n"))
                else:
                    lines.append(f"{sp}- {first_k}: {_yaml_scalar(first_v)}")
                for k, v in items[1:]:
                    if isinstance(v, (dict, list)):
                        lines.append(f"{sp}  {k}:")
                        lines.append(_to_simple_yaml(v, indent + 2).rstrip("\n"))
                    else:
                        lines.append(f"{sp}  {k}: {_yaml_scalar(v)}")
            elif isinstance(item, list):
                lines.append(f"{sp}-")
                lines.append(_to_simple_yaml(item, indent + 1).rstrip("\n"))
            else:
                lines.append(f"{sp}- {_yaml_scalar(item)}")
        return "\n".join(lines) + "\n"
    return sp + _yaml_scalar(obj) + "\n"


def _yaml_scalar(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if text == "" or any(c in text for c in ":#{}[],&*?|>!%@`'\"\n") or text.strip() != text:
        return json.dumps(text)
    return text


if __name__ == "__main__":
    raise SystemExit(main())
