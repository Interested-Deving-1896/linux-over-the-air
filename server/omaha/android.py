"""
android.py — Android-specific Omaha v3 response builder

Extends the base Nebraska server to handle Android OTA update checks.
Android devices (update_engine, custom OTA clients) send Omaha requests
with Android-specific app IDs and attributes. This module:

  - Recognises Android app IDs ({android-*} or custom device IDs)
  - Builds Omaha responses with Android payload.bin URLs
  - Includes payload_properties fields in the response metadata
  - Handles Virtual A/B and GSI update types
  - Routes Waydroid and Halium update checks to appropriate packages

Android Omaha request attributes (in <app> element):
  id          Device/product app ID (e.g. "{android-arm64-vanilla}")
  version     Current build ID or version string
  track       Channel: stable, beta, dev, lts
  arch        Architecture: arm64, arm, x86_64, x86, riscv64
  board       Device board name (optional)
  hardware    Hardware class (optional)
  delta_okay  "true" if device can accept delta payloads

Android-specific <updatecheck> response attributes:
  IsDeltaPayload   "true" for delta payloads
  MaxFailureCountPerUrl  retry limit
  DisablePayloadBackoff  "true" to disable exponential backoff
"""

import hashlib
import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional

# Android app ID prefixes that trigger Android-specific handling
ANDROID_APP_ID_PREFIXES = (
    "{android-",
    "android.",
    "com.android.",
)

# Waydroid app ID prefix
WAYDROID_APP_ID_PREFIX = "{waydroid-"

# Halium app ID prefix
HALIUM_APP_ID_PREFIX = "{halium-"


def is_android_request(app_id: str) -> bool:
    """Return True if this Omaha request is from an Android client."""
    return any(app_id.startswith(p) for p in ANDROID_APP_ID_PREFIXES)


def is_waydroid_request(app_id: str) -> bool:
    return app_id.startswith(WAYDROID_APP_ID_PREFIX)


def is_halium_request(app_id: str) -> bool:
    return app_id.startswith(HALIUM_APP_ID_PREFIX)


def parse_android_app_element(app_el: ET.Element) -> dict:
    """
    Parse an Android Omaha <app> element into a structured dict.

    Extracts standard fields plus Android-specific attributes like
    delta_okay, board, hardware, and oemcrypto_version.
    """
    return {
        "app_id":        app_el.get("id", ""),
        "version":       app_el.get("version", "0"),
        "arch":          app_el.get("arch", "arm64"),
        "channel":       app_el.get("track", "stable"),
        "board":         app_el.get("board", ""),
        "hardware":      app_el.get("hardware", ""),
        "delta_okay":    app_el.get("delta_okay", "false").lower() == "true",
        "wants_update":  app_el.find("updatecheck") is not None,
        "is_android":    is_android_request(app_el.get("id", "")),
        "is_waydroid":   is_waydroid_request(app_el.get("id", "")),
        "is_halium":     is_halium_request(app_el.get("id", "")),
    }


def build_android_response(
    app_id: str,
    package: Optional[dict],
    base_url: str,
    delta_okay: bool = False,
) -> str:
    """
    Build an Omaha v3 XML response for an Android update check.

    Includes Android-specific attributes in the <updatecheck> and
    <action> elements that update_engine expects.
    """
    root = ET.Element("response", protocol="3.0")
    root.set("server", "nebraska-android")

    daystart = ET.SubElement(root, "daystart")
    daystart.set("elapsed_seconds", "0")
    daystart.set("elapsed_days", "0")

    app = ET.SubElement(root, "app")
    app.set("appid", app_id)
    app.set("status", "ok")

    updatecheck = ET.SubElement(app, "updatecheck")

    if package is None:
        updatecheck.set("status", "noupdate")
        return ET.tostring(root, encoding="unicode", xml_declaration=True)

    updatecheck.set("status", "ok")

    # Android update_engine expects the codebase URL to end with /
    bundle_name = Path(package.get("_bundle_path", "")).name
    codebase = f"{base_url}/packages/{bundle_name}/"

    urls = ET.SubElement(updatecheck, "urls")
    url_el = ET.SubElement(urls, "url")
    url_el.set("codebase", codebase)

    manifest_el = ET.SubElement(updatecheck, "manifest")
    manifest_el.set("version", package.get("version", "0"))

    packages_el = ET.SubElement(manifest_el, "packages")
    pkg_el = ET.SubElement(packages_el, "package")
    pkg_el.set("name", "payload.bin")
    pkg_el.set("hash_sha256", package.get("payload_sha256", ""))
    pkg_el.set("size", str(package.get("payload_size", 0)))
    pkg_el.set("required", "true")

    # payload_properties.txt — update_engine reads this alongside payload.bin
    props_el = ET.SubElement(packages_el, "package")
    props_el.set("name", "payload_properties.txt")
    props_el.set("size", str(package.get("payload_properties_size", 0)))
    props_el.set("required", "false")

    actions = ET.SubElement(manifest_el, "actions")

    # install action — update_engine checks IsDeltaPayload here
    action_install = ET.SubElement(actions, "action")
    action_install.set("event", "install")
    action_install.set("run", "payload.bin")

    # postinstall action — Android-specific attributes
    action_post = ET.SubElement(actions, "action")
    action_post.set("event", "postinstall")

    is_delta = (
        package.get("payload_type") == "delta"
        or package.get("payload_format") == "android-crau-delta"
    )
    action_post.set("IsDeltaPayload", "true" if is_delta else "false")
    action_post.set("MaxFailureCountPerUrl", "3")
    action_post.set("DisablePayloadBackoff", "false")

    # Metadata hash for update_engine pre-verification
    if package.get("metadata_sha256"):
        action_post.set("MetadataSignatureRsa", package["metadata_sha256"])
    if package.get("metadata_size"):
        action_post.set("MetadataSize", str(package["metadata_size"]))

    return ET.tostring(root, encoding="unicode", xml_declaration=True)


def build_waydroid_response(
    app_id: str,
    package: Optional[dict],
    base_url: str,
) -> str:
    """
    Build an Omaha response for a Waydroid image update check.

    Waydroid images (system.img + vendor.img) are served as a lota bundle.
    The response points to the bundle directory containing both images.
    """
    root = ET.Element("response", protocol="3.0")
    root.set("server", "nebraska-waydroid")

    daystart = ET.SubElement(root, "daystart")
    daystart.set("elapsed_seconds", "0")
    daystart.set("elapsed_days", "0")

    app = ET.SubElement(root, "app")
    app.set("appid", app_id)
    app.set("status", "ok")

    updatecheck = ET.SubElement(app, "updatecheck")

    if package is None:
        updatecheck.set("status", "noupdate")
        return ET.tostring(root, encoding="unicode", xml_declaration=True)

    updatecheck.set("status", "ok")

    bundle_name = Path(package.get("_bundle_path", "")).name
    codebase = f"{base_url}/packages/{bundle_name}/"

    urls = ET.SubElement(updatecheck, "urls")
    ET.SubElement(urls, "url").set("codebase", codebase)

    manifest_el = ET.SubElement(updatecheck, "manifest")
    manifest_el.set("version", package.get("version", "0"))

    packages_el = ET.SubElement(manifest_el, "packages")

    # system.img
    if package.get("system_sha256"):
        sys_el = ET.SubElement(packages_el, "package")
        sys_el.set("name", "system.img")
        sys_el.set("hash_sha256", package["system_sha256"])
        sys_el.set("size", str(package.get("system_size", 0)))
        sys_el.set("required", "true")

    # vendor.img
    if package.get("vendor_sha256"):
        ven_el = ET.SubElement(packages_el, "package")
        ven_el.set("name", "vendor.img")
        ven_el.set("hash_sha256", package["vendor_sha256"])
        ven_el.set("size", str(package.get("vendor_size", 0)))
        ven_el.set("required", "false")

    actions = ET.SubElement(manifest_el, "actions")
    action = ET.SubElement(actions, "action")
    action.set("event", "postinstall")
    action.set("IsDeltaPayload", "false")

    return ET.tostring(root, encoding="unicode", xml_declaration=True)


def enrich_package_with_android_metadata(package: dict) -> dict:
    """
    Augment a package manifest dict with Android-specific fields
    read from the bundle directory (payload_properties.txt, etc.).
    """
    bundle_path = Path(package.get("_bundle_path", ""))
    if not bundle_path.exists():
        return package

    # Read payload_properties.txt if present
    props_path = bundle_path / "payload_properties.txt"
    if props_path.exists():
        props = {}
        for line in props_path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
        package["metadata_sha256"] = props.get("METADATA_HASH", "")
        package["metadata_size"] = int(props.get("METADATA_SIZE", 0) or 0)
        package["payload_properties_size"] = props_path.stat().st_size

    # Read Waydroid image hashes if present
    for img_name, key_prefix in [("system.img", "system"), ("vendor.img", "vendor")]:
        img_path = bundle_path / img_name
        if img_path.exists():
            sha256 = hashlib.sha256(img_path.read_bytes()).hexdigest()
            package[f"{key_prefix}_sha256"] = sha256
            package[f"{key_prefix}_size"] = img_path.stat().st_size

    return package


def route_android_request(
    app: dict,
    registry,  # PackageRegistry from nebraska.py
    base_url: str,
) -> str:
    """
    Route an Android Omaha request to the appropriate response builder.

    Called by the Nebraska server's POST /update handler when it detects
    an Android app ID.
    """
    app_id = app.get("app_id", "")
    channel = app.get("channel", "stable")
    arch = app.get("arch", "arm64")
    delta_okay = app.get("delta_okay", False)

    if app.get("is_waydroid"):
        # Waydroid: look up waydroid-specific package
        distro = "waydroid"
        package = registry.get(channel, arch, distro)
        if package:
            package = enrich_package_with_android_metadata(package)
        return build_waydroid_response(app_id, package, base_url)

    if app.get("is_halium"):
        # Halium: look up halium-specific package
        distro = "halium"
        package = registry.get(channel, arch, distro)
        if package:
            package = enrich_package_with_android_metadata(package)
        return build_android_response(app_id, package, base_url, delta_okay)

    # Standard Android device: look up by (channel, arch, "android")
    package = registry.get(channel, arch, "android")
    if package is None:
        # Fall back to app_id-based lookup (device-specific packages)
        package = registry.get(channel, arch, app_id)
    if package:
        package = enrich_package_with_android_metadata(package)

    return build_android_response(app_id, package, base_url, delta_okay)
