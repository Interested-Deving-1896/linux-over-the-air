#!/usr/bin/env python3
"""
server/hawkbit/server.py — Eclipse hawkBit DDI API server

Lightweight hawkBit-compatible DDI server for lota fleet management.
Suitable for self-hosted deployments without a full hawkBit installation.

For production fleet management, point devices at a real hawkBit instance
and use this only for local testing or air-gapped environments.

Usage:
  python3 server.py [--port PORT] [--packages-dir DIR] [--tenant TENANT]

Environment:
  HAWKBIT_PORT          Listen port (default: 8081)
  HAWKBIT_PACKAGES_DIR  Directory containing update bundles (default: ./packages)
  HAWKBIT_TENANT        Default tenant ID (default: default)
"""

import argparse
import json
import logging
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [hawkbit] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger("hawkbit")


class ActionStore:
    """In-memory store for deployment actions and device state."""

    def __init__(self):
        # device_id → {"version": str, "arch": str, "channel": str, ...}
        self.devices: dict[str, dict] = {}
        # device_id → action_id
        self.pending_actions: dict[str, int] = {}
        # action_id → {"device_id": str, "package": dict, "status": str}
        self.actions: dict[int, dict] = {}
        self._next_action_id = 1

    def register_device(self, device_id: str, attributes: dict):
        self.devices[device_id] = attributes
        log.info("Device registered: %s %s", device_id, attributes.get("version", ""))

    def assign_update(self, device_id: str, package: dict) -> int:
        action_id = self._next_action_id
        self._next_action_id += 1
        self.actions[action_id] = {
            "device_id": device_id,
            "package": package,
            "status": "running",
            "created_at": time.time(),
        }
        self.pending_actions[device_id] = action_id
        log.info("Action %d assigned to device %s", action_id, device_id)
        return action_id

    def get_pending_action(self, device_id: str) -> Optional[int]:
        return self.pending_actions.get(device_id)

    def update_action_status(self, action_id: int, status: str, progress: int = 0):
        if action_id in self.actions:
            self.actions[action_id]["status"] = status
            self.actions[action_id]["progress"] = progress
            if status in ("finished_success", "finished_failure"):
                device_id = self.actions[action_id]["device_id"]
                self.pending_actions.pop(device_id, None)
            log.info("Action %d status: %s (%d%%)", action_id, status, progress)


class HawkBitHandler(BaseHTTPRequestHandler):
    store: ActionStore
    registry: object  # PackageRegistry from nebraska.py
    base_url: str
    default_tenant: str

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)

    def send_json(self, code: int, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length > 0 else b""

    def do_GET(self):
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]

        # /{tenant}/controller/v1/{controllerId}
        if len(parts) == 4 and parts[1] == "controller" and parts[2] == "v1":
            tenant, _, _, device_id = parts
            self._handle_poll(tenant, device_id)

        # /{tenant}/controller/v1/{controllerId}/deploymentBase/{actionId}
        elif len(parts) == 6 and parts[4] == "deploymentBase":
            tenant, _, _, device_id, _, action_id = parts
            self._handle_deployment_base(tenant, device_id, int(action_id))

        # /{tenant}/controller/v1/{controllerId}/softwaremodules/{moduleId}/artifacts/{filename}
        elif len(parts) == 7 and parts[4] == "softwaremodules" and parts[6] == "artifacts":
            # Redirect to the actual package file
            self.send_response(302)
            self.send_header("Location", f"{self.base_url}/packages/{parts[5]}/{parts[7] if len(parts) > 7 else 'payload'}")
            self.end_headers()

        elif parsed.path == "/healthz":
            self.send_json(200, {"status": "ok", "devices": len(self.store.devices)})

        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        body = self.read_body()

        # /{tenant}/controller/v1/{controllerId}/deploymentBase/{actionId}/feedback
        if len(parts) == 7 and parts[4] == "deploymentBase" and parts[6] == "feedback":
            action_id = int(parts[5])
            self._handle_feedback(action_id, body)

        else:
            self.send_json(404, {"error": "not found"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        body = self.read_body()

        # /{tenant}/controller/v1/{controllerId}/configData
        if len(parts) == 5 and parts[4] == "configData":
            device_id = parts[3]
            try:
                data = json.loads(body)
                attrs = data.get("data", {})
                self.store.register_device(device_id, attrs)
                self.send_json(200, {"status": "ok"})
            except json.JSONDecodeError:
                self.send_json(400, {"error": "invalid JSON"})
        else:
            self.send_json(404, {"error": "not found"})

    def _handle_poll(self, tenant: str, device_id: str):
        """Handle device poll — return deployment base link if update available."""
        action_id = self.store.get_pending_action(device_id)

        # Check if there's a new package for this device
        if action_id is None and self.registry:
            device_info = self.store.devices.get(device_id, {})
            channel = device_info.get("channel", "stable")
            arch = device_info.get("arch", "amd64")
            distro = device_info.get("distro", "linux")
            package = self.registry.get(channel, arch, distro)
            if package:
                current_version = device_info.get("version", "")
                if package.get("version", "") != current_version:
                    action_id = self.store.assign_update(device_id, package)

        response = {
            "_links": {
                "configData": {
                    "href": f"{self.base_url}/{tenant}/controller/v1/{device_id}/configData"
                }
            },
            "config": {"polling": {"sleep": "00:05:00"}},
        }

        if action_id is not None:
            response["_links"]["deploymentBase"] = {
                "href": f"{self.base_url}/{tenant}/controller/v1/{device_id}/deploymentBase/{action_id}"
            }

        self.send_json(200, response)

    def _handle_deployment_base(self, tenant: str, device_id: str, action_id: int):
        """Return deployment details for a specific action."""
        action = self.store.actions.get(action_id)
        if not action:
            self.send_json(404, {"error": "action not found"})
            return

        package = action["package"]
        bundle_name = Path(package.get("_bundle_path", "")).name

        response = {
            "id": str(action_id),
            "deployment": {
                "download": "forced",
                "update": "forced",
                "maintenanceWindow": "available",
                "chunks": [
                    {
                        "part": "os",
                        "version": package.get("version", "0"),
                        "name": bundle_name,
                        "artifacts": [
                            {
                                "filename": "payload",
                                "hashes": {
                                    "sha256": package.get("payload_sha256", ""),
                                },
                                "size": package.get("payload_size", 0),
                                "_links": {
                                    "download": {
                                        "href": f"{self.base_url}/packages/{bundle_name}/payload"
                                    },
                                    "md5sum": {
                                        "href": f"{self.base_url}/packages/{bundle_name}/payload.sha256"
                                    },
                                },
                            }
                        ],
                    }
                ],
            },
        }
        self.send_json(200, response)

    def _handle_feedback(self, action_id: int, body: bytes):
        """Process device feedback on a deployment action."""
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid JSON"})
            return

        execution = data.get("status", {}).get("execution", "")
        result_finished = data.get("status", {}).get("result", {}).get("finished", "")
        progress = data.get("status", {}).get("result", {}).get("progress", {}).get("cnt", 0)

        if result_finished == "success":
            self.store.update_action_status(action_id, "finished_success", 100)
        elif result_finished == "failure":
            self.store.update_action_status(action_id, "finished_failure", 0)
        else:
            self.store.update_action_status(action_id, execution, progress)

        self.send_json(200, {"status": "ok"})


def make_handler(store: ActionStore, registry, base_url: str, tenant: str):
    class Handler(HawkBitHandler):
        pass
    Handler.store = store
    Handler.registry = registry
    Handler.base_url = base_url
    Handler.default_tenant = tenant
    return Handler


def main():
    parser = argparse.ArgumentParser(description="hawkBit DDI server")
    parser.add_argument("--port", type=int, default=int(os.environ.get("HAWKBIT_PORT", 8081)))
    parser.add_argument("--packages-dir", default=os.environ.get("HAWKBIT_PACKAGES_DIR", "./packages"))
    parser.add_argument("--tenant", default=os.environ.get("HAWKBIT_TENANT", "default"))
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    # Reuse Nebraska's PackageRegistry if available
    try:
        import sys
        sys.path.insert(0, str(Path(__file__).parent.parent / "nebraska"))
        from nebraska import PackageRegistry
        registry = PackageRegistry(Path(args.packages_dir))
    except ImportError:
        registry = None
        log.warning("Nebraska PackageRegistry not available — no package serving")

    store = ActionStore()
    base_url = f"http://{args.host}:{args.port}"
    handler = make_handler(store, registry, base_url, args.tenant)

    server = HTTPServer((args.host, args.port), handler)
    log.info("hawkBit DDI server listening on %s:%d (tenant: %s)", args.host, args.port, args.tenant)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
