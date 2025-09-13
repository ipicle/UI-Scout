#!/bin/bash

# UI Scout System Check Script
# Verifies installation and functionality

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m' 
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== UI Scout System Check ===${NC}\n"

# Track overall status
ISSUES=0

check_requirement() {
    local name=$1
    local command=$2
    local required=$3
    
    if command -v "$command" &> /dev/null; then
        echo -e "${GREEN}✓${NC} $name is available"
        if [ "$command" = "swift" ]; then
            swift --version | head -1
        elif [ "$command" = "node" ]; then
            echo "  Version: $(node --version)"
        fi
    else
        echo -e "${RED}✗${NC} $name is missing"
        if [ "$required" = "true" ]; then
            ((ISSUES++))
        fi
    fi
}

check_file() {
    local name=$1
    local path=$2
    local required=$3
    
    if [ -f "$path" ]; then
        echo -e "${GREEN}✓${NC} $name exists"
    else
        echo -e "${RED}✗${NC} $name missing: $path"
        if [ "$required" = "true" ]; then
            ((ISSUES++))
        fi
    fi
}

check_directory() {
    local name=$1
    local path=$2
    
    if [ -d "$path" ]; then
        echo -e "${GREEN}✓${NC} $name directory exists"
        echo "  $(ls -1 "$path" | wc -l | xargs) files in $path"
    else
        echo -e "${YELLOW}⚠${NC} $name directory missing: $path"
    fi
}

check_permissions() {
    local app_name="Terminal"
    
    echo -e "\n${BLUE}Checking Accessibility Permissions${NC}"
    
    # This is a simplified check - in practice you'd need to test actual accessibility API calls
    echo -e "${YELLOW}⚠${NC} Please verify Accessibility permissions manually:"
    echo "  System Preferences → Security & Privacy → Privacy → Accessibility"
    echo "  Ensure your terminal app is listed and enabled"
}

check_service() {
    echo -e "\n${BLUE}Checking Service Status${NC}"
    
    # Check if service is running
    if pgrep -f "ui-scout serve" > /dev/null; then
        echo -e "${GREEN}✓${NC} UI Scout service is running"
        
        # Test if service responds
        if curl -s http://localhost:3847/health > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} Service responds to health checks"
        else
            echo -e "${YELLOW}⚠${NC} Service running but not responding on port 3847"
        fi
    else
        echo -e "${YELLOW}⚠${NC} UI Scout service is not currently running"
        echo "  Start with: ui-scout serve"
    fi
}

performance_test() {
    echo -e "\n${BLUE}Running Performance Tests${NC}"
    
    if command -v ui-scout &> /dev/null; then
        echo "Testing element discovery speed..."
        
        # Time the discovery command
        start_time=$(date +%s%N)
        if ui-scout discover --quiet > /dev/null 2>&1; then
            end_time=$(date +%s%N)
            duration_ms=$(((end_time - start_time) / 1000000))
            
            if [ $duration_ms -lt 50 ]; then
                echo -e "${GREEN}✓${NC} Discovery completed in ${duration_ms}ms (target: <40ms)"
            elif [ $duration_ms -lt 100 ]; then
                echo -e "${YELLOW}⚠${NC} Discovery completed in ${duration_ms}ms (acceptable)"
            else
                echo -e "${RED}✗${NC} Discovery took ${duration_ms}ms (too slow)"
                ((ISSUES++))
            fi
        else
            echo -e "${RED}✗${NC} Discovery test failed"
            ((ISSUES++))
        fi
    else
        echo -e "${RED}✗${NC} Cannot run performance test - ui-scout command not available"
        ((ISSUES++))
    fi
}

# Main checks
echo -e "${BLUE}System Requirements${NC}"
check_requirement "Swift" "swift" "true"
check_requirement "Node.js" "node" "true"
check_requirement "npm" "npm" "true"
check_requirement "curl" "curl" "false"

echo -e "\n${BLUE}Installation Status${NC}"
check_file "UI Scout CLI" "/usr/local/bin/ui-scout" "true"
check_file "Main config" "$HOME/.config/ui-scout/ui-scout.json" "false"
check_file "Launch Agent" "$HOME/Library/LaunchAgents/com.uiscout.service.plist" "false"

echo -e "\n${BLUE}Project Structure${NC}"
PROJECT_DIR="/Users/petermsimon/Tools/AI_playground/ui-scout"
check_directory "Swift Sources" "$PROJECT_DIR/Sources"
check_directory "MCP Tool" "$PROJECT_DIR/mcp-tool" 
check_directory "Tests" "$PROJECT_DIR/Tests"
check_directory "Examples" "$PROJECT_DIR/examples"
check_directory "Config" "$PROJECT_DIR/config"

check_permissions
check_service

if [ $ISSUES -eq 0 ]; then
    performance_test
fi

# Summary
echo -e "\n${BLUE}=== System Check Summary ===${NC}"

if [ $ISSUES -eq 0 ]; then
    echo -e "${GREEN}✓ All critical checks passed!${NC}"
    echo -e "UI Scout appears to be properly installed and ready for use.\n"
    
    echo "Next Steps:"
    echo "1. Start the service: ui-scout serve"
    echo "2. Test element discovery: ui-scout discover"
    echo "3. Configure your AI assistant with MCP integration"
    echo "4. Run integration demo: node examples/integration_demo.js"
    
elif [ $ISSUES -eq 1 ]; then
    echo -e "${YELLOW}⚠ 1 issue found${NC}"
    echo "Please address the issue above before using UI Scout."
    
else
    echo -e "${RED}✗ $ISSUES issues found${NC}"
    echo "Please address the issues above before using UI Scout."
    echo ""
    echo "Common solutions:"
    echo "- Install missing requirements (Swift, Node.js)"
    echo "- Run deployment script: ./deploy.sh"
    echo "- Grant Accessibility permissions"
fi

exit $ISSUES
