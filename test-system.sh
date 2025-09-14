#!/bin/bash

# UI Scout - Test Script

echo "🧪 Testing UI Scout System"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

ERRORS=0

test_service() {
    echo -n "Testing HTTP service... "
    if curl -s http://localhost:8080/health > /dev/null; then
        echo -e "${GREEN}✅ OK${NC}"
    else
        echo -e "${RED}❌ FAILED${NC}"
        echo "  Service not responding on http://localhost:8080"
        ((ERRORS++))
    fi
}

test_api() {
    echo -n "Testing API endpoint... "
    local response=$(curl -s -X POST http://localhost:8080/api/v1/find \
        -H "Content-Type: application/json" \
        -d '{"appBundleId": "com.apple.finder", "elementType": "input"}')
    
    if echo "$response" | grep -q '"success":true'; then
        echo -e "${GREEN}✅ OK${NC}"
        local confidence=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin)['confidence'])")
        echo "  Found element with confidence: $confidence"
    elif echo "$response" | grep -q '"success":false'; then
        echo -e "${YELLOW}⚠️  OK (no elements found)${NC}"
        echo "  This is normal if Finder doesn't have input fields open"
    else
        echo -e "${RED}❌ FAILED${NC}"
        echo "  Response: $response"
        ((ERRORS++))
    fi
}

test_mcp_tool() {
    echo -n "Testing MCP tool... "
    if [ -f "./cmd/uisct-mcp/dist/index.js" ]; then
        echo -e "${GREEN}✅ OK${NC}"
        echo "  MCP tool built and ready"
    else
        echo -e "${RED}❌ FAILED${NC}"
        echo "  MCP tool not built. Run: cd cmd/uisct-mcp && npm run build"
        ((ERRORS++))
    fi
}

test_permissions() {
    echo -n "Testing permissions... "
    local status=$(curl -s http://localhost:8080/api/v1/status)
    if echo "$status" | grep -q '"canOperate":true'; then
        echo -e "${GREEN}✅ OK${NC}"
        echo "  All permissions granted"
    else
        echo -e "${RED}❌ FAILED${NC}"
        echo "  Missing permissions. Check accessibility settings."
        ((ERRORS++))
    fi
}

# Run tests
echo -e "${BLUE}=== UI Scout System Test ===${NC}"
echo ""

test_service
test_permissions
test_api
test_mcp_tool

echo ""
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed! UI Scout is ready for Claude Desktop.${NC}"
    echo ""
    echo "To configure Claude Desktop:"
    echo "  ./setup-claude-desktop.sh"
    echo ""
    echo "To test manually:"
    echo "  curl -X POST http://localhost:8080/api/v1/find \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"appBundleId\": \"com.apple.finder\", \"elementType\": \"input\"}'"
else
    echo -e "${RED}❌ $ERRORS test(s) failed. Please fix the issues above.${NC}"
fi

exit $ERRORS
