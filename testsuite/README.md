# UIScout E2E Test Suite and Simulator

This folder provides a lightweight end-to-end simulator for UIScout’s HTTP API, plus a runnable test harness. It lets you validate flows without macOS Accessibility permissions or real UI apps.

## What’s Included
- `simulator/server.js`: Mock HTTP server implementing UIScout endpoints
- `run-e2e.sh`: Bash harness that starts the simulator and runs E2E checks
- `scenarios/basic.json`: Example scenario describing a mock app/element

## Requirements
- macOS or Linux
- Node.js 16+ (for the simulator)
- curl (for the test harness)

## Quick Start

1) Start the simulator (defaults to http://127.0.0.1:18080):

```bash
node testsuite/simulator/server.js
```

2) In another terminal, run the E2E harness against the simulator:

```bash
bash testsuite/run-e2e.sh --base "http://127.0.0.1:18080"
```

You should see successful checks for health, find, after-send-diff, snapshot, learn, status, and signatures, plus a brief SSE observe test.

## Running Against Real Service

If you want to run the same checks against the real UIScout service:

```bash
# Ensure service is running (default: http://127.0.0.1:8080)
launchctl load ~/Library/LaunchAgents/com.uiscout.service.plist

# Run tests against the real service
bash testsuite/run-e2e.sh --base "http://127.0.0.1:8080"
```

Note: Some endpoints may depend on Accessibility permissions and real UI context; the simulator is intended for development/test environments where those are unavailable.

## Scenario Files

Scenarios in `testsuite/scenarios/*.json` shape the simulator responses. You can add more scenarios to test different app bundle IDs and element types.

## Extending
- Add more assertions in `run-e2e.sh`
- Add additional endpoints in `simulator/server.js`
- Create new scenario files under `testsuite/scenarios`

## Proof-of-Access E2E (Apps)

The `e2e/` folder contains an end-to-end proof harness that exercises real UI flows (no simulator): discovery, AX-safe send, OCR/AX read, copy-chat/copy-logs via the in-window actions menu, session swap, and evidence bundling.

### Generic Harness

```
testsuite/e2e/uisct-proof.sh --app <bundleId> [--copy-chat "Label"] [--copy-logs "Label"]
```

Artifacts are written to `./_proof-<timestamp>/` and a tarball is created. Requires the UIScout CLI binaries to be built (`swift build -c release --product uisct-cli` and `--product UIScoutRead`).

### Raycast Example

```
testsuite/e2e/proof-raycast.sh
```

This runs the generic proof for `com.raycast.macos` with common menu labels.

> Notes:
> - Ensure the target window is visible (OCR needs pixels).
> - On first run, grant Accessibility and Screen Recording permissions.
> - The harness reports WARN lines for advisory checks; hard failures exit non-zero.
