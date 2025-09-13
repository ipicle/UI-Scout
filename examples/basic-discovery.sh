#!/usr/bin/env bash
# UIScout Example: Basic Element Discovery

set -e

echo "🎯 UIScout Basic Element Discovery Example"
echo "This example demonstrates finding UI elements in common macOS applications."
echo

# Check if UIScout CLI is built
if [[ ! -f ".build/release/uisct-cli" ]]; then
    echo "❌ UIScout CLI not found. Please run 'make build' first."
    exit 1
fi

CLI=".build/release/uisct-cli"

# Check permissions
echo "1. Checking UIScout status..."
$CLI status --json > /tmp/uisct_status.json
CAN_OPERATE=$(cat /tmp/uisct_status.json | grep -o '"canOperate":[^,]*' | cut -d':' -f2)

if [[ "$CAN_OPERATE" != "true" ]]; then
    echo "⚠️  UIScout needs permissions. Running setup..."
    $CLI setup
else
    echo "✅ UIScout has necessary permissions"
fi

echo
echo "2. Finding elements in Raycast (if running)..."

# Check if Raycast is running
if pgrep -f "Raycast" > /dev/null; then
    echo "📱 Raycast is running, attempting to find elements..."
    
    # Find input field
    echo "  • Looking for input field..."
    $CLI find --app com.raycast.macos --type input --json > /tmp/raycast_input.json
    INPUT_CONFIDENCE=$(cat /tmp/raycast_input.json | grep -o '"confidence":[^,]*' | cut -d':' -f2)
    echo "    Input field confidence: $INPUT_CONFIDENCE"
    
    # Find reply area
    echo "  • Looking for reply area..."
    $CLI find --app com.raycast.macos --type reply --json > /tmp/raycast_reply.json
    REPLY_CONFIDENCE=$(cat /tmp/raycast_reply.json | grep -o '"confidence":[^,]*' | cut -d':' -f2)
    echo "    Reply area confidence: $REPLY_CONFIDENCE"
    
    # Show results
    echo "  • Results saved to /tmp/raycast_*.json"
else
    echo "📱 Raycast is not running, skipping..."
fi

echo
echo "3. Finding elements in VS Code (if running)..."

if pgrep -f "Visual Studio Code" > /dev/null; then
    echo "💻 VS Code is running, attempting to find elements..."
    
    # Find input field with lower confidence threshold (Electron apps are trickier)
    echo "  • Looking for input field..."
    $CLI find --app com.microsoft.VSCode --type input --min-confidence 0.6 --json > /tmp/vscode_input.json
    INPUT_CONFIDENCE=$(cat /tmp/vscode_input.json | grep -o '"confidence":[^,]*' | cut -d':' -f2)
    echo "    Input field confidence: $INPUT_CONFIDENCE"
    
    echo "  • Results saved to /tmp/vscode_*.json"
else
    echo "💻 VS Code is not running, skipping..."
fi

echo
echo "4. System statistics:"
$CLI status | grep -E "(Signatures|Evidence|Average)"

echo
echo "🎉 Example completed!"
echo "Next steps:"
echo "  • Review JSON results in /tmp/raycast_*.json and /tmp/vscode_*.json"
echo "  • Try 'make example-monitor' to see element monitoring"
echo "  • Use 'make http-service' to start the API server"
echo "  • Run 'make mcp-server' for LLM integration"
