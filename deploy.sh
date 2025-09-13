#!/bin/bash

set -e  # Exit on any error

echo "=== UI Scout Deployment Script ==="

# Configuration
PROJECT_DIR=$(pwd)
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="$HOME/Library/LaunchAgents"
CONFIG_DIR="$HOME/.config/ui-scout"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_requirements() {
    log_info "Checking requirements..."
    
    # Check for Swift
    if ! command -v swift &> /dev/null; then
        log_error "Swift is required but not installed. Please install Xcode Command Line Tools."
        exit 1
    fi
    
    # Check for Node.js
    if ! command -v node &> /dev/null; then
        log_error "Node.js is required but not installed. Please install Node.js."
        exit 1
    fi
    
    # Check macOS version
    if [[ $(sw_vers -productVersion | cut -d. -f1) -lt 12 ]]; then
        log_warn "This system is designed for macOS 12+ but may work on older versions."
    fi
    
    log_info "Requirements check passed."
}

build_swift_library() {
    log_info "Building Swift library..."
    
    if [ -f "Package.swift" ]; then
        swift build -c release
        if [ $? -eq 0 ]; then
            log_info "Swift library built successfully."
        else
            log_error "Failed to build Swift library."
            exit 1
        fi
    else
        log_error "Package.swift not found. Are you in the correct directory?"
        exit 1
    fi
}

build_cli_tool() {
    log_info "Building CLI tool..."
    
    # Build the CLI executable
    swift build -c release --product ui-scout-cli
    
    # Copy to install directory (requires sudo)
    if [ -f ".build/release/ui-scout-cli" ]; then
        log_info "Installing CLI tool to $INSTALL_DIR..."
        sudo cp .build/release/ui-scout-cli "$INSTALL_DIR/ui-scout"
        sudo chmod +x "$INSTALL_DIR/ui-scout"
        log_info "CLI tool installed as 'ui-scout'"
    else
        log_error "CLI tool binary not found after build."
        exit 1
    fi
}

install_node_dependencies() {
    log_info "Installing Node.js dependencies..."
    
    if [ -f "mcp-tool/package.json" ]; then
        cd mcp-tool
        npm install
        npm run build
        cd ..
        log_info "Node.js dependencies installed."
    else
        log_warn "No Node.js package.json found, skipping dependency installation."
    fi
}

setup_configuration() {
    log_info "Setting up configuration..."
    
    # Create config directory
    mkdir -p "$CONFIG_DIR"
    
    # Copy configuration files
    if [ -f "config/ui-scout.json" ]; then
        cp config/ui-scout.json "$CONFIG_DIR/"
        log_info "Configuration copied to $CONFIG_DIR"
    fi
    
    # Set up development config if it exists
    if [ -f "config/development.json" ]; then
        cp config/development.json "$CONFIG_DIR/"
    fi
}

create_launch_agent() {
    log_info "Creating Launch Agent for automatic startup..."
    
    mkdir -p "$SERVICE_DIR"
    
    cat > "$SERVICE_DIR/com.uiscout.service.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.uiscout.service</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/ui-scout</string>
        <string>serve</string>
        <string>--config</string>
        <string>$CONFIG_DIR/ui-scout.json</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/ui-scout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ui-scout.error.log</string>
</dict>
</plist>
EOF

    log_info "Launch Agent created. Service will start automatically on login."
}

test_installation() {
    log_info "Testing installation..."
    
    # Test CLI tool
    if command -v ui-scout &> /dev/null; then
        log_info "✓ CLI tool is accessible"
        ui-scout --version || log_warn "Version command failed"
    else
        log_error "CLI tool not found in PATH"
        exit 1
    fi
    
    # Test service startup (briefly)
    log_info "Testing service startup..."
    timeout 5s ui-scout serve --test || log_warn "Service test failed or timed out"
    
    log_info "Installation test completed."
}

show_usage_info() {
    log_info "=== UI Scout Installation Complete ==="
    echo ""
    echo "Usage:"
    echo "  ui-scout discover              - Discover UI elements"
    echo "  ui-scout find 'button text'   - Find specific element"
    echo "  ui-scout serve                 - Start HTTP service"
    echo "  ui-scout --help               - Show all options"
    echo ""
    echo "Configuration:"
    echo "  Config files: $CONFIG_DIR"
    echo "  Logs: /tmp/ui-scout.log"
    echo ""
    echo "MCP Integration:"
    echo "  Add to your AI assistant's MCP configuration:"
    echo "  Server: http://localhost:3847"
    echo ""
    echo "Service Management:"
    echo "  Start:  launchctl load $SERVICE_DIR/com.uiscout.service.plist"
    echo "  Stop:   launchctl unload $SERVICE_DIR/com.uiscout.service.plist"
    echo "  Status: launchctl list | grep uiscout"
}

# Main installation flow
main() {
    echo "Starting UI Scout deployment..."
    
    check_requirements
    build_swift_library
    build_cli_tool
    install_node_dependencies
    setup_configuration
    create_launch_agent
    test_installation
    show_usage_info
    
    log_info "Deployment completed successfully!"
}

# Handle script options
case "${1:-deploy}" in
    deploy)
        main
        ;;
    clean)
        log_info "Cleaning build artifacts..."
        swift package clean
        rm -rf .build
        log_info "Clean completed."
        ;;
    uninstall)
        log_info "Uninstalling UI Scout..."
        sudo rm -f "$INSTALL_DIR/ui-scout"
        launchctl unload "$SERVICE_DIR/com.uiscout.service.plist" 2>/dev/null || true
        rm -f "$SERVICE_DIR/com.uiscout.service.plist"
        rm -rf "$CONFIG_DIR"
        log_info "Uninstall completed."
        ;;
    *)
        echo "Usage: $0 [deploy|clean|uninstall]"
        exit 1
        ;;
esac
