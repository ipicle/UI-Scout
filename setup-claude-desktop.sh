#!/bin/bash

# UI Scout - Claude Desktop Setup Script

set -e

echo "🤖 Setting up UI Scout for Claude Desktop"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Paths
CLAUDE_CONFIG_DIR="$HOME/.config/claude-desktop"
CLAUDE_CONFIG_FILE="$CLAUDE_CONFIG_DIR/mcp_settings.json"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_TOOL_PATH="$PROJECT_DIR/cmd/uisct-mcp/dist/index.js"

echo -e "${BLUE}Project Directory:${NC} $PROJECT_DIR"
echo -e "${BLUE}MCP Tool Path:${NC} $MCP_TOOL_PATH"

# Check if Claude Desktop config directory exists
if [ ! -d "$CLAUDE_CONFIG_DIR" ]; then
    echo -e "${YELLOW}Creating Claude Desktop config directory...${NC}"
    mkdir -p "$CLAUDE_CONFIG_DIR"
fi

# Check if MCP tool is built
if [ ! -f "$MCP_TOOL_PATH" ]; then
    echo -e "${YELLOW}Building MCP tool...${NC}"
    cd "$PROJECT_DIR/cmd/uisct-mcp"
    npm install
    npm run build
    cd "$PROJECT_DIR"
fi

# Generate the configuration
echo -e "${BLUE}Generating Claude Desktop configuration...${NC}"

# Check if config file exists and has content
if [ -f "$CLAUDE_CONFIG_FILE" ] && [ -s "$CLAUDE_CONFIG_FILE" ]; then
    echo -e "${YELLOW}Existing Claude Desktop configuration found.${NC}"
    echo "Please manually add the following to your $CLAUDE_CONFIG_FILE:"
    echo ""
    echo -e "${GREEN}Add this to the \"mcpServers\" section:${NC}"
    echo '    "ui-scout": {'
    echo '      "command": "node",'
    echo "      \"args\": [\"$MCP_TOOL_PATH\"],"
    echo '      "env": {'
    echo '        "NODE_ENV": "production"'
    echo '      }'
    echo '    },'
    echo ""
else
    # Create new config file
    echo -e "${GREEN}Creating new Claude Desktop configuration...${NC}"
    cat > "$CLAUDE_CONFIG_FILE" << EOF
{
  "mcpServers": {
    "ui-scout": {
      "command": "node",
      "args": ["$MCP_TOOL_PATH"],
      "env": {
        "NODE_ENV": "production"
      }
    }
  }
}
EOF
    echo -e "${GREEN}✅ Configuration created at:${NC} $CLAUDE_CONFIG_FILE"
fi

echo ""
echo -e "${BLUE}🚀 Setup Complete!${NC}"
echo ""
echo "Next steps:"
echo "1. Make sure UI Scout service is running:"
echo "   cd $PROJECT_DIR && ./.build/debug/uisct-service"
echo ""
echo "2. Restart Claude Desktop to load the new MCP configuration"
echo ""
echo "3. In Claude Desktop, you should now have access to UI Scout tools:"
echo "   • findElement - Find UI elements by type and app"
echo "   • captureSnapshot - Capture element snapshots"
echo "   • observeElement - Monitor UI changes"
echo "   • learnSignature - Store element signatures"
echo ""
echo "4. Test with: 'Find the input field in Finder'"
echo ""
echo -e "${GREEN}Happy automating! 🎯${NC}"
