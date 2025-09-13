.PHONY: help build clean test run-cli run-service run-mcp setup example install

# Default target
help: ## Show this help message
	@echo "UIScout - Intelligent UI element discovery for macOS"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Build targets
build: ## Build all components (Swift CLI + Service, Node MCP)
	@echo "🔨 Building UIScout..."
	swift build -c release
	@echo "📦 Building MCP wrapper..."
	cd cmd/uisct-mcp && npm install && npm run build

build-cli: ## Build CLI tool only
	swift build -c release --product UIScoutCLI

build-service: ## Build HTTP service only  
	swift build -c release --product UIScoutService

build-mcp: ## Build MCP wrapper only
	cd cmd/uisct-mcp && npm install && npm run build

# Development
dev-mcp: ## Run MCP wrapper in development mode
	cd cmd/uisct-mcp && npm run dev

clean: ## Clean build artifacts
	swift package clean
	rm -rf .build
	cd cmd/uisct-mcp && rm -rf dist node_modules

test: ## Run Swift tests
	swift test

# Runtime targets
setup: build-cli ## Run interactive permission setup
	.build/release/UIScoutCLI setup

status: build-cli ## Check UIScout system status
	.build/release/UIScoutCLI status

run-cli: build-cli ## Run CLI with example arguments (find input in Raycast)
	.build/release/UIScoutCLI find --app com.raycast.macos --type input

run-service: build-service ## Start HTTP service on localhost:8080
	@echo "🌐 Starting UIScout HTTP service on http://127.0.0.1:8080"
	.build/release/UIScoutService

run-mcp: build-mcp ## Start MCP server for LLM integration
	@echo "🤖 Starting UIScout MCP server..."
	cd cmd/uisct-mcp && npm start

# Examples
example-basic: build ## Run basic element discovery example
	@chmod +x examples/basic-discovery.sh
	@examples/basic-discovery.sh

example-monitor: build-cli ## Example: Monitor Raycast reply area for 10 seconds
	@echo "👀 Monitoring Raycast reply area for changes..."
	@echo "First, let's find the reply area signature:"
	.build/release/UIScoutCLI find --app com.raycast.macos --type reply --json > /tmp/raycast_reply_sig.json
	@echo "Now observing for 10 seconds (send a message in Raycast to see events):"
	.build/release/UIScoutCLI observe --app com.raycast.macos --signature /tmp/raycast_reply_sig.json --duration 10

example-http: build ## Example: Test HTTP API endpoints
	@echo "🌐 Testing HTTP API (make sure to run 'make run-service' first)..."
	@echo "Testing health endpoint:"
	curl -s http://127.0.0.1:8080/health | jq '.' || echo "Service not running or jq not installed"
	@echo ""
	@echo "Testing status endpoint:"
	curl -s http://127.0.0.1:8080/api/v1/status | jq '.canOperate' || echo "Service not running"

# Installation helpers  
install-deps-macos: ## Install dependencies on macOS (requires Homebrew)
	@echo "🍺 Installing dependencies via Homebrew..."
	brew install swift node jq
	@echo "✅ Dependencies installed"

install-cli: build-cli ## Install CLI tool to /usr/local/bin
	@echo "📦 Installing UIScout CLI to /usr/local/bin..."
	sudo cp .build/release/UIScoutCLI /usr/local/bin/uisct
	@echo "✅ UIScout CLI installed as 'uisct'"

uninstall-cli: ## Remove CLI tool from /usr/local/bin
	sudo rm -f /usr/local/bin/uisct
	@echo "🗑️ UIScout CLI uninstalled"

# Development utilities
lint: ## Run Swift linting (requires swift-format)
	@if command -v swift-format >/dev/null 2>&1; then \
		find Sources -name "*.swift" | xargs swift-format --in-place; \
		echo "✅ Swift code formatted"; \
	else \
		echo "⚠️ swift-format not installed. Install with: brew install swift-format"; \
	fi

check-permissions: build-cli ## Check current macOS permissions
	.build/release/UIScoutCLI status --json | jq '.permissions'

list-signatures: build-cli ## List all stored element signatures
	.build/release/UIScoutCLI status --json | jq '.store'
	@echo ""
	@echo "Detailed signature list:"
	.build/release/UIScoutCLI list-signatures || echo "No signatures found"

# Documentation
docs: ## Generate documentation (placeholder)
	@echo "📚 Documentation generation not implemented yet"
	@echo "For now, see README.md and source code comments"

# Release helpers
release-build: clean ## Clean build for release
	@echo "🚀 Building release version..."
	swift build -c release -Xswiftc -O
	cd cmd/uisct-mcp && npm ci --only=production && npm run build
	@echo "✅ Release build complete"

package: release-build ## Create distribution package
	@echo "📦 Creating distribution package..."
	mkdir -p dist/uiscout
	cp .build/release/UIScoutCLI dist/uiscout/
	cp .build/release/UIScoutService dist/uiscout/
	cp -r cmd/uisct-mcp/dist dist/uiscout/mcp
	cp -r cmd/uisct-mcp/package.json dist/uiscout/mcp/
	cp README.md dist/uiscout/
	cp -r examples dist/uiscout/
	@echo "✅ Package created in dist/uiscout/"

# Debugging and diagnostics
debug-app: build-cli ## Debug element discovery for a specific app (requires APP env var)
	@if [ -z "$(APP)" ]; then \
		echo "❌ Please specify APP bundle ID: make debug-app APP=com.raycast.macos"; \
		exit 1; \
	fi
	@echo "🔍 Debugging element discovery for $(APP)..."
	.build/release/UIScoutCLI find --app $(APP) --type input --json | jq '.'
	.build/release/UIScoutCLI find --app $(APP) --type reply --json | jq '.'
	.build/release/UIScoutCLI find --app $(APP) --type session --json | jq '.'

logs: ## Show system logs related to UIScout
	@echo "📋 Recent UIScout-related log entries:"
	log show --predicate 'process CONTAINS "UIScout" OR message CONTAINS "ui-scout"' --last 1h --style compact

# Quick start
quickstart: build setup ## Complete setup for new users
	@echo "🎉 UIScout quick start completed!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Try: make example-basic"
	@echo "  2. Start HTTP service: make run-service"  
	@echo "  3. Start MCP server: make run-mcp"
	@echo "  4. Install CLI globally: make install-cli"
	@echo ""
	@echo "For help: make help"
