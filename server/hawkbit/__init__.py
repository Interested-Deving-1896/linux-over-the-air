"""
server/hawkbit — Eclipse hawkBit DDI (Direct Device Integration) API server

Implements the hawkBit DDI REST API for fleet-scale OTA management.
hawkBit is an alternative to Omaha for environments that need:
  - Device group management
  - Rollout campaigns with percentage-based rollout
  - Feedback and status reporting from devices
  - Software module versioning

Endpoints (DDI API v1):
  GET  /{tenant}/controller/v1/{controllerId}
       → deployment base, config data, cancel action links

  GET  /{tenant}/controller/v1/{controllerId}/deploymentBase/{actionId}
       → deployment details: chunks, artifacts, maintenance window

  POST /{tenant}/controller/v1/{controllerId}/deploymentBase/{actionId}/feedback
       → device reports progress/success/failure

  GET  /{tenant}/controller/v1/{controllerId}/softwaremodules/{moduleId}/artifacts/{filename}
       → artifact download

  PUT  /{tenant}/controller/v1/{controllerId}/configData
       → device reports attributes (version, arch, board, etc.)

See server/hawkbit/server.py for the implementation.
"""
