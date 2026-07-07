#!/usr/bin/env python3
"""Generate exhaustive AAP Custom Resource example YAML from operator CRD OpenAPI schemas.

Reads CRD dumps (for example from ../dump-aap-crds/crd-dumps/<version>/) and writes
reference manifests that list every spec field: CRD defaults are set explicitly, and
fields without defaults appear as commented placeholders.

Designed for AutomationController, AutomationHub, and EDA CRs used in OpenShift
operator deployments.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required: pip install pyyaml") from exc

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CRD_ROOT = SCRIPT_DIR.parent / "dump-aap-crds" / "crd-dumps"

CRD_FILES = {
    "AutomationController": (
        "automationcontroller.ansible.com_automationcontrollers.yaml",
        "automationcontroller.ansible.com/v1beta1",
        "AutomationController",
        "example-controller",
        "controller.yml",
    ),
    "AutomationHub": (
        "automationhub.ansible.com_automationhubs.yaml",
        "automationhub.ansible.com/v1beta1",
        "AutomationHub",
        "example-hub",
        "hub.yml",
    ),
    "EDA": (
        "eda.ansible.com_edas.yaml",
        "eda.ansible.com/v1beta1",
        "EDA",
        "example-eda",
        "eda.yml",
    ),
}

# Example secret wiring for the aap-notes reference layout (override via --overrides-file later).
OVERRIDES: dict[str, dict[str, str]] = {
    "AutomationController": {
        "secret_key_secret": "example-controller-secret-key",
        "postgres_configuration_secret": "controller-postgres-configuration",
        "ee_pull_credentials_secret": "ee-pull-secret",
        "route_tls_secret": "controller-route-tls-secret",
        "admin_password_secret": "example-controller-admin-password",
    },
    "AutomationHub": {
        "db_fields_encryption_secret": "example-hub-secret-key",
        "postgres_configuration_secret": "hub-postgres-configuration",
        "object_storage_s3_secret": "hub-s3-storage-secret",
        "route_tls_secret": "hub-route-tls-secret",
        "storage_type": "S3",
    },
    "EDA": {
        "db_fields_encryption_secret": "example-eda-secret-key",
        "database.database_secret": "eda-postgres-configuration",
        "automation_server_url": "https://example-controller-aap.apps.example.com",
        "route_tls_secret": "eda-route-tls-secret",
        "admin_password_secret": "example-eda-admin-password",
    },
}

# Fields that are environment-specific or migration-only — shown commented unless overridden.
COMMENT_PATHS: dict[str, set[str]] = {
    "AutomationController": {
        "old_postgres_configuration_secret",
        "broadcast_websocket_secret",
        "bundle_cacert_secret",
        "ldap_cacert_secret",
        "ldap_password_secret",
        "metrics_utility_secret",
        "metrics_utility_configmap",
        "projects_existing_claim",
        "projects_use_existing_claim",
        "ca_trust_bundle",
        "affinity",
        "task_affinity",
        "web_affinity",
        "host_aliases",
        "extra_settings",
        "extra_settings_files",
        "ee_images",
        "ingress_tls_secret",
        "ingress_hosts",
        "ingress_annotations",
    },
    "AutomationHub": {
        "sso_secret",
        "object_storage_azure_secret",
        "bundle_cacert_secret",
        "container_token_secret",
        "signing_secret",
        "signing_scripts_configmap",
        "admin_password_secret",
        "postgres_migrant_configuration_secret",
        "affinity",
        "pulp_settings",
    },
    "EDA": {
        "bundle_cacert_secret",
        "ingress_tls_secret",
        "extra_settings",
        "redis.redis_secret",
        "automation_server_ssl_verify",
    },
}

ALWAYS_EXPAND = {
    "api",
    "content",
    "redis",
    "resource_manager",
    "web",
    "worker",
    "database",
    "scheduler",
    "ui",
    "default_worker",
    "activation_worker",
    "event_stream",
    "ee_resource_requirements",
    "web_resource_requirements",
    "task_resource_requirements",
    "redis_resource_requirements",
    "rsyslog_resource_requirements",
    "init_container_resource_requirements",
    "postgres_resource_requirements",
    "postgres_storage_requirements",
    "postgres_init_container_resource_requirements",
    "security_context_settings",
    "storage_requirements",
}

SECTIONS: dict[str, list[tuple[str, list[str]]]] = {
    "AutomationController": [
        ("Admin & account", ["admin_user", "admin_email", "admin_password_secret"]),
        (
            "Operator behavior",
            [
                "auto_upgrade",
                "create_preload_data",
                "garbage_collect_secrets",
                "no_log",
                "set_self_labels",
                "development_mode",
                "idle_deployment",
                "deployment_type",
                "kind",
                "replicas",
                "termination_grace_period_seconds",
            ],
        ),
        (
            "Secrets & encryption",
            [
                "secret_key_secret",
                "broadcast_websocket_secret",
                "bundle_cacert_secret",
                "ldap_cacert_secret",
                "ldap_password_secret",
                "ca_trust_bundle",
            ],
        ),
        (
            "Database (external Postgres)",
            [
                "postgres_configuration_secret",
                "old_postgres_configuration_secret",
                "postgres_data_path",
                "postgres_extra_args",
                "postgres_annotations",
                "postgres_image",
                "postgres_image_version",
                "postgres_keep_pvc_after_upgrade",
                "postgres_keepalives",
                "postgres_keepalives_idle",
                "postgres_keepalives_interval",
                "postgres_keepalives_count",
                "postgres_label_selector",
                "postgres_priority_class",
                "postgres_selector",
                "postgres_storage_class",
                "postgres_tolerations",
                "postgres_extra_volumes",
                "postgres_extra_volume_mounts",
                "pg_dump_suffix",
                "postgres_init_container_resource_requirements",
                "postgres_resource_requirements",
                "postgres_storage_requirements",
            ],
        ),
        (
            "Projects persistence",
            [
                "projects_persistence",
                "projects_storage_access_mode",
                "projects_storage_size",
                "projects_storage_class",
                "projects_existing_claim",
                "projects_use_existing_claim",
            ],
        ),
        (
            "Execution environments",
            [
                "ee_pull_credentials_secret",
                "ee_images",
                "control_plane_ee_image",
                "ee_extra_env",
                "ee_extra_volume_mounts",
                "ee_resource_requirements",
            ],
        ),
        (
            "Container images",
            [
                "image",
                "image_version",
                "image_pull_policy",
                "image_pull_secret",
                "image_pull_secrets",
                "init_container_image",
                "init_container_image_version",
                "init_projects_container_image",
                "redis_image",
                "redis_image_version",
                "metrics_utility_image",
                "metrics_utility_image_version",
                "metrics_utility_image_pull_policy",
            ],
        ),
        (
            "Ingress / Route / LoadBalancer",
            [
                "ingress_type",
                "ingress_api_version",
                "ingress_class_name",
                "ingress_controller",
                "ingress_path",
                "ingress_path_type",
                "ingress_annotations",
                "ingress_hosts",
                "ingress_tls_secret",
                "route_api_version",
                "route_host",
                "route_tls_secret",
                "route_tls_termination_mechanism",
                "loadbalancer_class",
                "loadbalancer_ip",
                "loadbalancer_port",
                "loadbalancer_protocol",
                "nodeport_port",
                "service_type",
                "hostname",
                "public_base_url",
                "api_urlpattern_prefix",
                "api_version",
            ],
        ),
        (
            "Web pod",
            [
                "web_replicas",
                "web_manage_replicas",
                "web_resource_requirements",
                "web_extra_env",
                "web_extra_volume_mounts",
                "web_args",
                "web_command",
                "web_annotations",
                "web_node_selector",
                "web_tolerations",
                "web_topology_spread_constraints",
                "web_affinity",
                "web_liveness_failure_threshold",
                "web_liveness_initial_delay",
                "web_liveness_period",
                "web_liveness_timeout",
                "web_readiness_failure_threshold",
                "web_readiness_initial_delay",
                "web_readiness_period",
                "web_readiness_timeout",
                "uwsgi_processes",
                "uwsgi_listen_queue_size",
            ],
        ),
        (
            "Task pod",
            [
                "task_replicas",
                "task_manage_replicas",
                "task_resource_requirements",
                "task_extra_env",
                "task_extra_volume_mounts",
                "task_args",
                "task_command",
                "task_annotations",
                "task_node_selector",
                "task_tolerations",
                "task_topology_spread_constraints",
                "task_affinity",
                "task_privileged",
                "task_liveness_failure_threshold",
                "task_liveness_initial_delay",
                "task_liveness_period",
                "task_liveness_timeout",
                "task_readiness_failure_threshold",
                "task_readiness_initial_delay",
                "task_readiness_period",
                "task_readiness_timeout",
                "receptor_log_level",
            ],
        ),
        ("Redis pod", ["redis_resource_requirements", "redis_capabilities"]),
        (
            "Rsyslog pod",
            [
                "rsyslog_resource_requirements",
                "rsyslog_extra_env",
                "rsyslog_extra_volume_mounts",
                "rsyslog_args",
                "rsyslog_command",
            ],
        ),
        (
            "Init container",
            [
                "init_container_resource_requirements",
                "init_container_extra_commands",
                "init_container_extra_volume_mounts",
            ],
        ),
        (
            "Metrics utility",
            [
                "metrics_utility_enabled",
                "metrics_utility_console_enabled",
                "metrics_utility_cronjob_gather_schedule",
                "metrics_utility_cronjob_report_schedule",
                "metrics_utility_pvc_claim",
                "metrics_utility_pvc_claim_size",
                "metrics_utility_pvc_claim_storage_class",
                "metrics_utility_secret",
                "metrics_utility_configmap",
                "metrics_utility_ship_target",
            ],
        ),
        (
            "Nginx tuning",
            [
                "nginx_worker_processes",
                "nginx_worker_connections",
                "nginx_worker_cpu_affinity",
                "nginx_listen_queue_size",
            ],
        ),
        (
            "Security & session",
            [
                "csrf_cookie_secure",
                "session_cookie_secure",
                "security_context_settings",
                "control_plane_priority_class",
            ],
        ),
        (
            "Scheduling & labels",
            [
                "node_selector",
                "tolerations",
                "topology_spread_constraints",
                "affinity",
                "additional_labels",
                "annotations",
                "service_account_annotations",
                "service_annotations",
                "service_labels",
            ],
        ),
        (
            "Extra configuration",
            [
                "extra_settings",
                "extra_settings_files",
                "extra_volumes",
                "host_aliases",
                "ipv6_disabled",
            ],
        ),
    ],
    "AutomationHub": [
        (
            "Secrets & encryption",
            [
                "db_fields_encryption_secret",
                "sso_secret",
                "bundle_cacert_secret",
                "container_token_secret",
                "signing_secret",
                "signing_scripts_configmap",
                "admin_password_secret",
            ],
        ),
        (
            "Database (external Postgres)",
            [
                "postgres_configuration_secret",
                "postgres_migrant_configuration_secret",
                "postgres_data_path",
                "postgres_extra_args",
                "postgres_host_auth_method",
                "postgres_initdb_args",
                "postgres_image",
                "postgres_keep_pvc_after_upgrade",
                "postgres_label_selector",
                "postgres_selector",
                "postgres_storage_class",
                "postgres_tolerations",
                "postgres_resource_requirements",
                "postgres_storage_requirements",
                "force_drop_db",
            ],
        ),
        (
            "Object / file storage",
            [
                "storage_type",
                "object_storage_s3_secret",
                "object_storage_azure_secret",
                "file_storage_access_mode",
                "file_storage_size",
                "file_storage_storage_class",
            ],
        ),
        (
            "Container images",
            [
                "image",
                "image_version",
                "image_web",
                "image_web_version",
                "image_pull_policy",
                "image_pull_secret",
                "image_pull_secrets",
                "redis_image",
            ],
        ),
        (
            "Ingress / Route / LoadBalancer",
            [
                "ingress_type",
                "ingress_annotations",
                "ingress_tls_secret",
                "route_host",
                "route_tls_secret",
                "route_tls_termination_mechanism",
                "loadbalancer_port",
                "loadbalancer_protocol",
                "nodeport_port",
                "hostname",
                "public_base_url",
            ],
        ),
        (
            "Gunicorn / proxy timeouts",
            [
                "gunicorn_api_workers",
                "gunicorn_content_workers",
                "gunicorn_timeout",
                "haproxy_timeout",
                "nginx_client_max_body_size",
                "nginx_proxy_connect_timeout",
                "nginx_proxy_read_timeout",
                "nginx_proxy_send_timeout",
            ],
        ),
        ("API deployment", ["api"]),
        ("Content deployment", ["content"]),
        ("Redis deployment", ["redis", "redis_storage_class", "redis_storage_size", "redis_resource_requirements"]),
        ("Resource manager deployment", ["resource_manager"]),
        ("Web deployment", ["web"]),
        ("Worker deployment", ["worker"]),
        ("Operator behavior", ["no_log", "idle_deployment", "deployment_type"]),
        ("Scheduling", ["node_selector", "tolerations", "topology_spread_constraints", "affinity", "service_annotations"]),
        ("Extra configuration", ["pulp_settings"]),
    ],
    "EDA": [
        ("Admin & account", ["admin_user", "admin_password_secret"]),
        (
            "Operator behavior",
            [
                "no_log",
                "set_self_labels",
                "force_drop_db",
                "idle_deployment",
                "ui_disabled",
                "ipv6_disabled",
                "public_base_url",
            ],
        ),
        ("Secrets & encryption", ["db_fields_encryption_secret", "bundle_cacert_secret"]),
        ("Controller integration", ["automation_server_url", "automation_server_ssl_verify"]),
        ("Database", ["database"]),
        ("Redis", ["redis", "redis_image", "redis_image_version"]),
        (
            "Container images",
            [
                "image",
                "image_version",
                "image_web",
                "image_web_version",
                "image_pull_policy",
                "image_pull_secrets",
                "postgres_image",
                "postgres_image_version",
            ],
        ),
        (
            "Ingress / Route / LoadBalancer",
            [
                "ingress_type",
                "ingress_api_version",
                "ingress_class_name",
                "ingress_path",
                "ingress_path_type",
                "ingress_annotations",
                "ingress_tls_secret",
                "route_api_version",
                "route_host",
                "route_tls_secret",
                "route_tls_termination_mechanism",
                "loadbalancer_port",
                "loadbalancer_protocol",
                "nodeport_port",
                "service_type",
                "hostname",
            ],
        ),
        ("API deployment", ["api"]),
        ("UI deployment", ["ui"]),
        ("Scheduler deployment", ["scheduler"]),
        ("Worker deployments", ["worker", "default_worker", "activation_worker"]),
        ("Event stream deployment", ["event_stream"]),
        ("Scheduling & labels", ["service_account_annotations", "additional_labels"]),
        ("Extra configuration", ["extra_settings"]),
    ],
}


def resolve(root: dict[str, Any], schema: dict[str, Any] | None, depth: int = 0) -> dict[str, Any]:
    if depth > 12 or not schema:
        return {}
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref.startswith("#/"):
            node: Any = root
            for part in ref.lstrip("#/").split("/"):
                node = node[part]
            return resolve(root, node, depth + 1)
    if "allOf" in schema:
        merged: dict[str, Any] = {}
        for item in schema["allOf"]:
            merged.update(resolve(root, item, depth + 1))
        return merged
    return schema


def load_schema(crd_path: Path) -> dict[str, Any]:
    with crd_path.open(encoding="utf-8") as handle:
        crd = yaml.safe_load(handle)
    return crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]


def is_secret_field(name: str, path: str = "") -> bool:
    return name.endswith("_secret") or path.endswith(".database_secret") or path.endswith(".redis_secret")


def fmt_val(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(value)


def short_desc(schema: dict[str, Any]) -> str:
    description = (schema.get("description") or "").strip().split("\n")[0]
    return description[:90] if description else ""


class Generator:
    def __init__(self, kind: str, crd_path: Path, namespace: str = "aap") -> None:
        self.kind = kind
        self.crd_path = crd_path
        self.namespace = namespace
        self.root = load_schema(crd_path)
        self.fname, self.api, self.k, self.meta_name, self.out_name = CRD_FILES[kind]

    def comment_suffix(self, path: str, name: str, parts: list[str]) -> tuple[str, str]:
        suffix = " # notsecret" if is_secret_field(name, path) else ""
        comment = f'  # {"; ".join(parts)}' if parts else ""
        return suffix, comment

    def emit_scalar(
        self,
        name: str,
        schema: dict[str, Any],
        path: str,
        indent: int,
        lines: list[str],
        force_comment: bool = False,
    ) -> None:
        ind = "  " * indent
        override = OVERRIDES.get(self.kind, {}).get(path)
        comment_set = COMMENT_PATHS.get(self.kind, set())
        default = schema.get("default")
        enum = schema.get("enum")
        parts: list[str] = []
        if short_desc(schema):
            parts.append(short_desc(schema))
        if enum and override is None:
            parts.append(f"enum: {', '.join(str(item) for item in enum[:6])}")

        if force_comment or (path in comment_set and override is None):
            if schema.get("type") == "array":
                line = f"{ind}# {name}: []"
                if parts:
                    line += f'  # {"; ".join(parts)}'
                lines.append(line)
                return
            if schema.get("type") == "object" or "properties" in schema:
                line = f"{ind}# {name}: {{}}"
                if parts:
                    line += f'  # {"; ".join(parts)}'
                lines.append(line)
                return
            placeholder = (
                "0"
                if schema.get("type") == "integer"
                else "false"
                if schema.get("type") == "boolean"
                else "example-value"
            )
            val = override or placeholder
            suffix, comment = self.comment_suffix(path, name, parts)
            lines.append(f"{ind}# {name}: {val}{suffix}{comment}")
            return

        if override is not None:
            suffix, comment = self.comment_suffix(path, name, parts)
            lines.append(f"{ind}{name}: {fmt_val(override)}{suffix}{comment}")
            return

        if default is not None:
            comment = f'  # default; {"; ".join(parts)}' if parts else "  # default"
            lines.append(f"{ind}{name}: {fmt_val(default)}{comment}")
            return

        placeholder = (
            "0"
            if schema.get("type") == "integer"
            else "false"
            if schema.get("type") == "boolean"
            else "example-value"
        )
        comment = f'  # {"; ".join(parts)}' if parts else ""
        if schema.get("type") == "array":
            lines.append(f"{ind}# {name}: []{comment}")
        elif schema.get("type") == "object" or "properties" in schema:
            lines.append(f"{ind}# {name}: {{}}{comment}")
        else:
            lines.append(f"{ind}# {name}: {placeholder}{comment}")

    def emit_object(self, name: str, schema: dict[str, Any], path: str, indent: int, lines: list[str]) -> None:
        schema = resolve(self.root, schema)
        props = schema.get("properties", {})
        comment_set = COMMENT_PATHS.get(self.kind, set())
        force_comment = path in comment_set and path not in OVERRIDES.get(self.kind, {})

        if force_comment:
            lines.append(f'{"  " * indent}# {name}: {{}}')
            return

        lines.append(f'{"  " * indent}{name}:')
        for key, value in sorted(props.items()):
            sub = resolve(self.root, value)
            subpath = f"{path}.{key}" if path else key
            sub_force = subpath in comment_set and subpath not in OVERRIDES.get(self.kind, {})
            if "properties" in sub and (
                key in ALWAYS_EXPAND
                or path.split(".")[-1] in ALWAYS_EXPAND
                or subpath in OVERRIDES.get(self.kind, {})
            ):
                self.emit_object(key, sub, subpath, indent + 1, lines)
            elif "properties" in sub:
                self.emit_scalar(key, sub, subpath, indent + 1, lines, force_comment=True)
            else:
                self.emit_scalar(key, sub, subpath, indent + 1, lines, force_comment=sub_force)

    def generate(self) -> str:
        spec = resolve(self.root, self.root["properties"]["spec"])
        props = spec.get("properties", {})

        ordered: list[str] = []
        seen: set[str] = set()
        for _, fields in SECTIONS[self.kind]:
            for field in fields:
                if field in props and field not in seen:
                    ordered.append(field)
                    seen.add(field)
        for field in sorted(props):
            if field not in seen:
                ordered.append(field)

        lines = [
            "---",
            f"# {self.kind} Custom Resource — exhaustive spec example",
            f"# Derived from CRD: {self.crd_path.name}",
            "# Fields with CRD defaults are set explicitly; unset options are commented with placeholders.",
            f"apiVersion: {self.api}",
            f"kind: {self.k}",
            "metadata:",
            f"  name: {self.meta_name}",
            f"  namespace: {self.namespace}",
            "spec:",
        ]

        current_section: str | None = None
        for field in ordered:
            for section_name, section_fields in SECTIONS[self.kind]:
                if field == section_fields[0] and section_name != current_section:
                    lines.append("")
                    lines.append(f"  # --- {section_name} ---")
                    current_section = section_name
                    break
            schema = resolve(self.root, props[field])
            if "properties" in schema:
                self.emit_object(field, schema, field, 1, lines)
            else:
                self.emit_scalar(field, schema, field, 1, lines)

        return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate exhaustive AAP CR example YAML from operator CRD schemas.",
    )
    parser.add_argument(
        "--version",
        default="2.4",
        help="AAP version subdirectory under the CRD root (default: 2.4)",
    )
    parser.add_argument(
        "--crd-dir",
        type=Path,
        help="Directory containing CRD YAML dumps (default: ../dump-aap-crds/crd-dumps/<version>)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Directory to write controller.yml, hub.yml, and/or eda.yml",
    )
    parser.add_argument(
        "--namespace",
        default="aap",
        help="Namespace for metadata.namespace in generated CRs (default: aap)",
    )
    parser.add_argument(
        "--kinds",
        default="AutomationController,AutomationHub,EDA",
        help="Comma-separated kinds to generate (default: all three)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    crd_dir = args.crd_dir or (DEFAULT_CRD_ROOT / args.version)
    if not crd_dir.is_dir():
        print(f"CRD directory not found: {crd_dir}", file=sys.stderr)
        return 1

    kinds = [kind.strip() for kind in args.kinds.split(",") if kind.strip()]
    unknown = [kind for kind in kinds if kind not in CRD_FILES]
    if unknown:
        print(f"Unknown kinds: {', '.join(unknown)}", file=sys.stderr)
        return 1

    args.output_dir.mkdir(parents=True, exist_ok=True)

    for kind in kinds:
        crd_file = crd_dir / CRD_FILES[kind][0]
        if not crd_file.is_file():
            print(f"Missing CRD file: {crd_file}", file=sys.stderr)
            return 1
        out_path = args.output_dir / CRD_FILES[kind][4]
        content = Generator(kind, crd_file, namespace=args.namespace).generate()
        out_path.write_text(content, encoding="utf-8")
        print(f"Wrote {out_path} ({len(content.splitlines())} lines)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
