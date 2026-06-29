#!/usr/bin/env python3
"""Verify BearBrowser SourceOS control-plane manifests and launcher identity.

This verifier is intentionally dependency-free so it can run in Homebrew tests,
CI, and local bootstrap environments before the shared SourceOS control-plane
SDK is available.
"""

from __future__ import annotations

import json
import pathlib
import plistlib
import re
import sys
from typing import Any

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVICE_MANIFEST = REPO_ROOT / "manifests" / "sourceos" / "service.json"
LAUNCH_MANIFEST = REPO_ROOT / "manifests" / "sourceos" / "launch.macos.json"
INSTALL_SCRIPT = REPO_ROOT / "scripts" / "install-macos-app-launcher.sh"
REPAIR_SCRIPT = REPO_ROOT / "scripts" / "repair-macos-app-launcher.sh"
NATIVE_SOURCE = REPO_ROOT / "native" / "macos" / "BearBrowserWebKitLauncher.m"

UPSTREAM_TERMS = ("firefox", "mozilla", "gecko", "librewolf")
POLLUTION_VARS = {"PYTHONPATH", "NODE_PATH", "GEM_HOME", "CARGO_HOME", "JAVA_HOME", "NIX_PATH"}


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise SystemExit(f"{path}: expected top-level object")
    return obj


def text(path: pathlib.Path) -> str:
    if not path.exists():
        raise SystemExit(f"missing required file: {path}")
    return path.read_text(encoding="utf-8")


def normalized(value: Any) -> str:
    return str(value or "").lower().replace("-", "").replace("_", "").replace(".", "")


def has_upstream_leak(value: Any) -> list[str]:
    candidate = str(value or "").lower()
    return sorted(term for term in UPSTREAM_TERMS if term in candidate)


def extract_plist(script_body: str) -> dict[str, Any]:
    match = re.search(r"cat > \"\$plist\" <<'PLIST'\n(?P<body>.*?)\nPLIST", script_body, re.DOTALL)
    if not match:
        match = re.search(r"cat > \"\$contents/Info\.plist\" <<EOF\n(?P<body>.*?)\nEOF", script_body, re.DOTALL)
    if not match:
        raise ValueError("Info.plist heredoc not found")
    body = match.group("body")
    # Install script contains a shell variable for version; replace with safe plist text.
    body = body.replace("$version", "0.1.0-overlay")
    return plistlib.loads(body.encode("utf-8"))


def require(condition: bool, errors: list[str], message: str) -> None:
    if not condition:
        errors.append(message)


def verify_service(service: dict[str, Any], errors: list[str], warnings: list[str]) -> None:
    require(service.get("schema_version") == "sourceos.service.v0.1", errors, "service schema_version must be sourceos.service.v0.1")
    require(service.get("service_id") == "dev.sourceos.bearbrowser", errors, "service_id must be dev.sourceos.bearbrowser")
    require(service.get("display_name") == "BearBrowser", errors, "service display_name must be BearBrowser")
    require(service.get("authority_domain") == "app", errors, "service authority_domain must be app")

    owner = service.get("owner") or {}
    require(owner.get("org") == "SourceOS-Linux", errors, "service owner.org must be SourceOS-Linux")
    require(owner.get("repo") == "BearBrowser", errors, "service owner.repo must be BearBrowser")

    caps = service.get("capabilities") or {}
    required = set(caps.get("required") or [])
    optional = set(caps.get("optional") or [])
    denied = set(caps.get("denied") or [])

    require(bool(required), errors, "service required capabilities must be non-empty")
    require("identity.product.upstream_leak" in denied, errors, "service must deny identity.product.upstream_leak")
    require("telemetry.emit.remote.default" in denied, errors, "service must deny telemetry.emit.remote.default")
    require("launch.inherit_user_shell" in denied, errors, "service must deny launch.inherit_user_shell")
    require(not (required & denied), errors, "required capabilities must not also be denied")
    if optional & denied:
        warnings.append("optional capabilities overlap denied capabilities: " + ", ".join(sorted(optional & denied)))

    require(bool(service.get("data_classes")), errors, "service data_classes must be non-empty")
    require(bool(service.get("launch_triggers")), errors, "service launch_triggers must be non-empty")
    require(bool(service.get("resource_budget")), errors, "service resource_budget must be non-empty")

    obs = service.get("observability") or {}
    require(obs.get("emits_events") is True, errors, "service observability.emits_events must be true")
    require(obs.get("incident_bundle") is True, errors, "service observability.incident_bundle must be true")
    require(bool(obs.get("health_endpoint")), errors, "service observability.health_endpoint must be set")


def verify_launch(launch: dict[str, Any], errors: list[str], warnings: list[str]) -> None:
    require(launch.get("schema_version") == "sourceos.launch_manifest.v0.1", errors, "launch schema_version must be sourceos.launch_manifest.v0.1")
    require(launch.get("product_id") == "dev.sourceos.BearBrowser", errors, "launch product_id must be dev.sourceos.BearBrowser")
    require(launch.get("display_name") == "BearBrowser", errors, "launch display_name must be BearBrowser")

    bundle = launch.get("bundle_identity") or {}
    require(bundle.get("bundle_id") == "dev.sourceos.BearBrowser", errors, "bundle_id must be dev.sourceos.BearBrowser")
    require(bundle.get("expected_process_name") == "BearBrowser", errors, "expected_process_name must be BearBrowser")

    entrypoint = launch.get("entrypoint") or {}
    require(entrypoint.get("absolute_path") == "/Applications/BearBrowser.app/Contents/MacOS/BearBrowser", errors, "entrypoint must point to native BearBrowser executable")

    env = launch.get("environment") or {}
    require(env.get("inherit_user_shell") is False, errors, "launch environment must not inherit user shell")
    path_entries = env.get("path") or []
    require(len(path_entries) == len(set(path_entries)), errors, "launch PATH must not contain duplicates")
    for entry in path_entries:
        if "homebrew" in str(entry).lower() or "/nix" in str(entry).lower():
            warnings.append(f"launch PATH contains developer/toolchain path: {entry}")
    denied_vars = set(env.get("denied_variables") or [])
    missing_vars = sorted(POLLUTION_VARS - denied_vars)
    require(not missing_vars, errors, "launch denied_variables missing: " + ", ".join(missing_vars))

    invariants = launch.get("identity_invariants") or {}
    for key in ("dock_name", "menu_name", "crash_report_name", "helper_prefix"):
        require(invariants.get(key) == "BearBrowser", errors, f"identity_invariants.{key} must be BearBrowser")
    profile_policy = invariants.get("profile_path_policy", "")
    require("MUST NOT" in profile_policy, errors, "profile_path_policy must explicitly forbid upstream identity leakage")

    user_surfaces = [
        launch.get("display_name"),
        bundle.get("bundle_id"),
        bundle.get("expected_process_name"),
        invariants.get("dock_name"),
        invariants.get("menu_name"),
        invariants.get("crash_report_name"),
        invariants.get("helper_prefix"),
    ]
    for surface in user_surfaces:
        leaked = has_upstream_leak(surface)
        require(not leaked, errors, f"user-facing launch surface leaks upstream terms {leaked}: {surface}")


def verify_launcher_scripts(launch: dict[str, Any], errors: list[str]) -> None:
    install_body = text(INSTALL_SCRIPT)
    repair_body = text(REPAIR_SCRIPT)
    native_body = text(NATIVE_SOURCE)

    for script_name, script_body in (("install", install_body), ("repair", repair_body)):
        try:
            plist = extract_plist(script_body)
        except Exception as exc:
            errors.append(f"{script_name} script Info.plist extraction failed: {exc}")
            continue
        require(plist.get("CFBundleName") == "BearBrowser", errors, f"{script_name} plist CFBundleName must be BearBrowser")
        require(plist.get("CFBundleDisplayName") == "BearBrowser", errors, f"{script_name} plist CFBundleDisplayName must be BearBrowser")
        require(plist.get("CFBundleIdentifier") == "dev.sourceos.BearBrowser", errors, f"{script_name} plist CFBundleIdentifier must be dev.sourceos.BearBrowser")
        require(plist.get("CFBundleExecutable") == "BearBrowser", errors, f"{script_name} plist CFBundleExecutable must be BearBrowser")

    require("BearBrowser native bootstrap active" in text(REPO_ROOT / "native" / "macos" / "BearBrowser-start.html"), errors, "native start page must carry BearBrowser product identity")
    require("BBEmitEvent(@\"app.launch\"" in native_body, errors, "native launcher must emit app.launch event")
    require("BearBrowser" in native_body, errors, "native launcher source must carry BearBrowser product identity")


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    service = load_json(SERVICE_MANIFEST)
    launch = load_json(LAUNCH_MANIFEST)

    verify_service(service, errors, warnings)
    verify_launch(launch, errors, warnings)
    verify_launcher_scripts(launch, errors)

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print("BearBrowser SourceOS control-plane manifests verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
