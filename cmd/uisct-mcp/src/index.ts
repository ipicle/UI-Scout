#!/usr/bin/env node

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError,
} from '@modelcontextprotocol/sdk/types.js';
import { UIScoutClient } from './client.js';
import { UIScoutTools } from './tools.js';
import { program } from 'commander';

// Parse command line arguments
program
  .name('uisct-mcp')
  .description('MCP tool wrapper for UIScout')
  .version('1.0.0')
  .option('-p, --port <port>', 'UIScout service port', '8080')
  .option('-h, --host <host>', 'UIScout service host', '127.0.0.1')
  .option('--debug', 'Enable debug logging')
  .parse();

const options = program.opts();

class UIScoutMCPServer {
  private server: Server;
  private client: UIScoutClient;
  private tools: UIScoutTools;

  constructor() {
    this.server = new Server(
      {
        name: 'ui-scout',
        version: '1.0.0',
        capabilities: {
          tools: {},
        },
      }
    );

    const serviceUrl = `http://${options.host}:${options.port}`;
    this.client = new UIScoutClient(serviceUrl);
    this.tools = new UIScoutTools(this.client);

    this.setupErrorHandling();
    this.setupHandlers();
  }

  private setupErrorHandling(): void {
    this.server.onerror = (error) => {
      console.error('[MCP Server Error]', error);
    };

    process.on('SIGINT', async () => {
      console.log('Shutting down UIScout MCP server...');
      await this.server.close();
      process.exit(0);
    });
  }

  private setupHandlers(): void {
    // List available tools
    this.server.setRequestHandler(ListToolsRequestSchema, async () => {
      const toolDefinitions = this.tools.getToolDefinitions();
      return {
        tools: toolDefinitions,
      };
    });

    // Handle tool calls
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;

      try {
        // Check if UIScout service is available
        const isAvailable = await this.client.checkHealth();
        if (!isAvailable) {
          throw new McpError(
            ErrorCode.InternalError,
            'UIScout service is not available. Please ensure the UIScout HTTP service is running.'
          );
        }

        // Execute the tool
        const result = await this.tools.executeTool(name, args || {});
        
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(result, null, 2),
            },
          ],
        };
      } catch (error) {
        if (error instanceof McpError) {
          throw error;
        }

        const errorMessage = error instanceof Error ? error.message : String(error);
        
        if (options.debug) {
          console.error('[Tool Execution Error]', error);
        }

        throw new McpError(
          ErrorCode.InternalError,
          `Tool execution failed: ${errorMessage}`
        );
      }
    });
  }

  async run(): Promise<void> {
    const transport = new StdioServerTransport();
    
    console.error('UIScout MCP Server starting...');
    console.error(`Connecting to UIScout service at http://${options.host}:${options.port}`);
    
    await this.server.connect(transport);
    console.error('UIScout MCP Server started successfully');
  }
}

// Main execution
async function main(): Promise<void> {
  try {
    const server = new UIScoutMCPServer();
    await server.run();
  } catch (error) {
    console.error('Failed to start UIScout MCP server:', error);
    process.exit(1);
  }
}

// Only run if this is the main module
if (require.main === module) {
  main().catch((error) => {
    console.error('Unhandled error:', error);
    process.exit(1);
  });
}
