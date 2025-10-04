#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/uisct-proof.sh" --app com.raycast.macos --copy-chat "Copy Chat" --copy-logs "Copy Error Logs"
