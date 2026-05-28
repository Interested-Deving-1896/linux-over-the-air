#!/usr/bin/env python3
"""
nebraska.py — Lightweight Omaha protocol mock server for OTA testing.

Implements the Omaha v3 XML protocol used by update_engine and the lota
engine. Suitable for local testing, CI, and air-gapped environments.

Endpoints:
  POST /update          Omaha v3 update check
  GET  /healthz         Health check
  GET  /api/packages    List available packages
  POST /api/packages    Register a new package
  GET  /api/config      Show server config

Usage:
  python3 nebraska.py [--port PORT] [--packages-dir DIR] [--public-key FILE]

Environment:
  NEBRASKA_PORT         Listen port (default: 8080)
  NEBRASKA_PACKAGES_DIR Directory containing update bundles (default: ./packages)
  NEBRASKA_PUBLIC_KEY   Path to public key for bundle verification
  NEBRASKA_CHANNEL      Default channel to serve (default: stable)
"""

import argparse
import hashlib
import json
import logging
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse, parse_qs

# Android-specific Omaha handling (optional — graceful fallback if not found)
try:
    import importlib.util, pathlib
    _android_spec = importlib.util.spec_from_file_location(
        "android",
        pathlib.Path(__file__).parent.parent / "omaha" / "android.py",
    )
    _android_mod = importlib.util.module_from_spec(_android_spec)
    _android_spec.loader.exec_module(_android_mod)
    _android = _android_mod
except Exception:
    _android = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [nebraska] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger("nebraska")


class PackageRegistry:
    """Manages available update packages indexed by (channel, arch, appid)."""

    def __init__(self, packages_dir: Path):
        self.packages_dir = packages_dir
        self.packages: dict[tuple, dict] = {}
        self._scan()

    def _scan(self):
        """Scan packages_dir for .lota bundles and load their manifests."""
        if not self.packages_dir.exists():
            log.warning("Packages directory not found: %s", self.packages_dir)
            return

        for bundle in self.packages_dir.glob("*.lota"):
            manifest_path = bundle / "manifest.json"
            if not manifest_path.exists():
                continue
            try:
                with open(manifest_path) as f:
                    manifest = json.load(f)
                key = (
                    manifest.get("channel", "stable"),
                    manifest.get("arch", "amd64"),
                    manifest.get("distro", "linux"),
                )
                # Keep the newest version per key
                existing = self.packages.get(key)
                if existing is None or manifest["version"] > existing["version"]:
                    manifest["_bundle_path"] = str(bundle)
                    self.packages[key] = manifest
                    log.info("Registered package: %s %s", key, manifest["version"])
            except Exception as e:
                log.warning("Failed to load bundle %s: %s", bundle, e)

    def get(self, channel: str, arch: str, appid: str) -> Optional[dict]:
        return self.packages.get((channel, arch, appid))

    def list_all(self) -> list[dict]:
        return list(self.packages.values())

    def register(self, manifest: dict):
        key = (
            manifest.get("channel", "stable"),
            manifest.get("arch", "amd64"),
            manifest.get("distro", "linux"),
        )
        self.packages[key] = manifest
        log.info("Registered package via API: %s %s", key, manifest.get("version"))


def build_omaha_response(
    appid: str,
    version: str,
    package: Optional[dict],
    base_url: str,
) -> str:
    """Build an Omaha v3 XML response."""
    root = ET.Element("response", protocol="3.0")
    root.set("server", "nebraska")

    daystart = ET.SubElement(root, "daystart")
    daystart.set("elapsed_seconds", "0")
    daystart.set("elapsed_days", "0")

    app = ET.SubElement(root, "app")
    app.set("appid", appid)
    app.set("status", "ok")

    updatecheck = ET.SubElement(app, "updatecheck")

    if package is None:
        updatecheck.set("status", "noupdate")
        return ET.tostring(root, encoding="unicode", xml_declaration=True)

    updatecheck.set("status", "ok")

    urls = ET.SubElement(updatecheck, "urls")
    bundle_name = Path(package["_bundle_path"]).name
    url = ET.SubElement(urls, "url")
    url.set("codebase", f"{base_url}/packages/{bundle_name}/")

    manifest_el = ET.SubElement(updatecheck, "manifest")
    manifest_el.set("version", package["version"])

    packages_el = ET.SubElement(manifest_el, "packages")
    pkg_el = ET.SubElement(packages_el, "package")
    pkg_el.set("name", "payload")
    pkg_el.set("hash_sha256", package.get("payload_sha256", ""))
    pkg_el.set("size", str(package.get("payload_size", 0)))
    pkg_el.set("required", "true")

    actions = ET.SubElement(manifest_el, "actions")
    action_install = ET.SubElement(actions, "action")
    action_install.set("event", "install")
    action_install.set("run", "payload")

    action_postinstall = ET.SubElement(actions, "action")
    action_postinstall.set("event", "postinstall")
    action_postinstall.set("IsDeltaPayload", str(package.get("payload_type") == "delta").lower())

    return ET.tostring(root, encoding="unicode", xml_declaration=True)


def parse_omaha_request(body: bytes) -> dict:
    """Parse an Omaha v3 XML request, return relevant fields."""
    try:
        root = ET.fromstring(body)
    except ET.ParseError as e:
        raise ValueError(f"Invalid XML: {e}") from e

    result = {
        "protocol": root.get("protocol", "3.0"),
        "apps": [],
    }

    for app in root.findall("app"):
        app_data = {
            "appid": app.get("id", ""),
            "version": app.get("version", "0.0.0"),
            "arch": app.get("arch", "amd64"),
            "channel": app.get("track", "stable"),
        }
        if app.find("updatecheck") is not None:
            app_data["wants_update"] = True
        result["apps"].append(app_data)

    return result


class NebraskaHandler(BaseHTTPRequestHandler):
    registry: PackageRegistry
    base_url: str
    default_channel: str

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)

    def send_json(self, code: int, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_xml(self, code: int, xml_str: str):
        body = xml_str.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length > 0 else b""

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/healthz":
            self.send_json(200, {"status": "ok", "packages": len(self.registry.packages)})

        elif path == "/api/packages":
            self.send_json(200, self.registry.list_all())

        elif path == "/api/config":
            self.send_json(200, {
                "packages_dir": str(self.registry.packages_dir),
                "default_channel": self.default_channel,
                "base_url": self.base_url,
            })

        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/update":
            body = self.read_body()
            try:
                req = parse_omaha_request(body)
            except ValueError as e:
                self.send_json(400, {"error": str(e)})
                return

            responses = []
            for app in req.get("apps", []):
                if not app.get("wants_update"):
                    continue
                channel = app.get("channel") or self.default_channel
                arch = app.get("arch", "amd64")
                appid = app.get("appid", "linux")

                # Route Android requests to the Android-specific handler
                if _android and _android.is_android_request(appid):
                    android_app = {
                        "app_id": appid,
                        "version": app.get("version", "0"),
                        "arch": arch,
                        "channel": channel,
                        "delta_okay": False,
                        "wants_update": True,
                        "is_android": True,
                        "is_waydroid": _android.is_waydroid_request(appid),
                        "is_halium": _android.is_halium_request(appid),
                    }
                    xml_resp = _android.route_android_request(
                        android_app, self.registry, self.base_url
                    )
                else:
                    package = self.registry.get(channel, arch, appid)
                    xml_resp = build_omaha_response(
                        appid=appid,
                        version=app.get("version", "0.0.0"),
                        package=package,
                        base_url=self.base_url,
                    )
                responses.append(xml_resp)

            # Return first app response (single-app typical case)
            if responses:
                self.send_xml(200, responses[0])
            else:
                # No apps requested update
                dummy = build_omaha_response("", "", None, self.base_url)
                self.send_xml(200, dummy)

        elif path == "/api/packages":
            body = self.read_body()
            try:
                manifest = json.loads(body)
            except json.JSONDecodeError as e:
                self.send_json(400, {"error": str(e)})
                return
            self.registry.register(manifest)
            self.send_json(201, {"status": "registered"})

        else:
            self.send_json(404, {"error": "not found"})


def make_handler(registry: PackageRegistry, base_url: str, default_channel: str):
    class Handler(NebraskaHandler):
        pass
    Handler.registry = registry
    Handler.base_url = base_url
    Handler.default_channel = default_channel
    return Handler


def main():
    parser = argparse.ArgumentParser(description="Nebraska — Omaha mock server")
    parser.add_argument("--port", type=int, default=int(os.environ.get("NEBRASKA_PORT", 8080)))
    parser.add_argument("--packages-dir", default=os.environ.get("NEBRASKA_PACKAGES_DIR", "./packages"))
    parser.add_argument("--public-key", default=os.environ.get("NEBRASKA_PUBLIC_KEY", ""))
    parser.add_argument("--channel", default=os.environ.get("NEBRASKA_CHANNEL", "stable"))
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    packages_dir = Path(args.packages_dir)
    registry = PackageRegistry(packages_dir)

    base_url = f"http://{args.host}:{args.port}"
    handler = make_handler(registry, base_url, args.channel)

    server = HTTPServer((args.host, args.port), handler)
    log.info("Nebraska listening on %s:%d", args.host, args.port)
    log.info("Packages dir: %s (%d packages)", packages_dir, len(registry.packages))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
