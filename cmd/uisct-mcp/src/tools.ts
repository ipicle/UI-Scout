import { Tool } from '@modelcontextprotocol/sdk/types.js';
import { UIScoutClient, ElementType, Policy, ElementSignature } from './client.js';
import { z } from 'zod';

// Input validation schemas
const FindElementInputSchema = z.object({
  appBundleId: z.string().describe('Application bundle identifier (e.g., "com.raycast.macos")'),
  elementType: z.enum(['reply', 'input', 'session']).describe('Type of UI element to find'),
  policy: z.object({
    allowPeek: z.boolean().optional().describe('Whether to allow polite peek if needed'),
    minConfidence: z.number().min(0).max(1).optional().describe('Minimum confidence threshold'),
    maxPeekMs: z.number().positive().optional().describe('Maximum peek duration in milliseconds'),
    rateLimitPeekSeconds: z.number().positive().optional().describe('Rate limit between peeks'),
  }).optional().describe('Detection policy configuration'),
});

const AfterSendDiffInputSchema = z.object({
  appBundleId: z.string().describe('Application bundle identifier'),
  preSignature: z.any().describe('Element signature from before sending message'),
  policy: z.object({
    allowPeek: z.boolean().optional(),
    minConfidence: z.number().min(0).max(1).optional(),
    maxPeekMs: z.number().positive().optional(),
    rateLimitPeekSeconds: z.number().positive().optional(),
  }).optional().describe('Detection policy configuration'),
});

const ObserveElementInputSchema = z.object({
  appBundleId: z.string().describe('Application bundle identifier'),
  signature: z.any().describe('Element signature to observe'),
  durationSeconds: z.number().positive().max(300).describe('How long to observe (max 300 seconds)'),
  policy: z.object({
    allowPeek: z.boolean().optional(),
    minConfidence: z.number().min(0).max(1).optional(),
    maxPeekMs: z.number().positive().optional(),
    rateLimitPeekSeconds: z.number().positive().optional(),
  }).optional().describe('Detection policy configuration'),
});

const CaptureSnapshotInputSchema = z.object({
  appBundleId: z.string().describe('Application bundle identifier'),
  signature: z.any().describe('Element signature to snapshot'),
});

const LearnSignatureInputSchema = z.object({
  signature: z.any().describe('Element signature to learn'),
  pin: z.boolean().default(false).describe('Pin signature to prevent decay'),
  decay: z.boolean().default(false).describe('Decay signature stability'),
});

const ListSignaturesInputSchema = z.object({
  appBundleId: z.string().optional().describe('Filter by application bundle ID'),
  elementType: z.enum(['reply', 'input', 'session']).optional().describe('Filter by element type'),
});

export class UIScoutTools {
  constructor(private client: UIScoutClient) {}

  getToolDefinitions(): Tool[] {
    return [
      {
        name: 'findElement',
        description: 'Find UI elements in macOS applications using intelligent heuristics and confidence scoring',
        inputSchema: {
          type: 'object',
          properties: {
            appBundleId: {
              type: 'string',
              description: 'Application bundle identifier (e.g., "com.raycast.macos", "com.microsoft.VSCode")',
            },
            elementType: {
              type: 'string',
              enum: ['reply', 'input', 'session'],
              description: 'Type of UI element: reply (LLM response area), input (message input field), session (conversation sidebar)',
            },
            policy: {
              type: 'object',
              properties: {
                allowPeek: {
                  type: 'boolean',
                  description: 'Whether to allow brief app activation for better accuracy (default: true)',
                },
                minConfidence: {
                  type: 'number',
                  minimum: 0,
                  maximum: 1,
                  description: 'Minimum confidence threshold to accept result (default: 0.8)',
                },
                maxPeekMs: {
                  type: 'number',
                  description: 'Maximum duration for app activation in milliseconds (default: 250)',
                },
                rateLimitPeekSeconds: {
                  type: 'number',
                  description: 'Minimum time between app activations in seconds (default: 10)',
                },
              },
              description: 'Detection policy configuration',
            },
          },
          required: ['appBundleId', 'elementType'],
        },
      },
      {
        name: 'afterSendDiff',
        description: 'Detect changes in UI elements after sending a message, useful for confirming message delivery',
        inputSchema: {
          type: 'object',
          properties: {
            appBundleId: {
              type: 'string',
              description: 'Application bundle identifier',
            },
            preSignature: {
              type: 'object',
              description: 'Element signature captured before sending message',
            },
            policy: {
              type: 'object',
              properties: {
                allowPeek: { type: 'boolean' },
                minConfidence: { type: 'number', minimum: 0, maximum: 1 },
                maxPeekMs: { type: 'number' },
                rateLimitPeekSeconds: { type: 'number' },
              },
              description: 'Detection policy configuration',
            },
          },
          required: ['appBundleId', 'preSignature'],
        },
      },
      {
        name: 'observeElement',
        description: 'Monitor UI element for changes over a specified duration, returning notable events',
        inputSchema: {
          type: 'object',
          properties: {
            appBundleId: {
              type: 'string',
              description: 'Application bundle identifier',
            },
            signature: {
              type: 'object',
              description: 'Element signature to monitor',
            },
            durationSeconds: {
              type: 'number',
              minimum: 1,
              maximum: 300,
              description: 'How long to observe in seconds (max 300)',
            },
            policy: {
              type: 'object',
              properties: {
                allowPeek: { type: 'boolean' },
                minConfidence: { type: 'number', minimum: 0, maximum: 1 },
                maxPeekMs: { type: 'number' },
                rateLimitPeekSeconds: { type: 'number' },
              },
              description: 'Detection policy configuration',
            },
          },
          required: ['appBundleId', 'signature', 'durationSeconds'],
        },
      },
      {
        name: 'captureSnapshot',
        description: 'Capture a diagnostic snapshot of a UI element for debugging or analysis',
        inputSchema: {
          type: 'object',
          properties: {
            appBundleId: {
              type: 'string',
              description: 'Application bundle identifier',
            },
            signature: {
              type: 'object',
              description: 'Element signature to snapshot',
            },
          },
          required: ['appBundleId', 'signature'],
        },
      },
      {
        name: 'learnSignature',
        description: 'Store, pin, or decay an element signature for improved future recognition',
        inputSchema: {
          type: 'object',
          properties: {
            signature: {
              type: 'object',
              description: 'Element signature to learn',
            },
            pin: {
              type: 'boolean',
              description: 'Pin signature to prevent automatic decay (default: false)',
            },
            decay: {
              type: 'boolean',
              description: 'Reduce signature stability score (default: false)',
            },
          },
          required: ['signature'],
        },
      },
      {
        name: 'getStatus',
        description: 'Get UIScout system status, permissions, and statistics',
        inputSchema: {
          type: 'object',
          properties: {},
        },
      },
      {
        name: 'listSignatures',
        description: 'List stored element signatures, optionally filtered by app or element type',
        inputSchema: {
          type: 'object',
          properties: {
            appBundleId: {
              type: 'string',
              description: 'Filter signatures by application bundle ID',
            },
            elementType: {
              type: 'string',
              enum: ['reply', 'input', 'session'],
              description: 'Filter signatures by element type',
            },
          },
        },
      },
    ];
  }

  async executeTool(name: string, args: Record<string, any>): Promise<any> {
    switch (name) {
      case 'findElement':
        return this.findElement(args);
      case 'afterSendDiff':
        return this.afterSendDiff(args);
      case 'observeElement':
        return this.observeElement(args);
      case 'captureSnapshot':
        return this.captureSnapshot(args);
      case 'learnSignature':
        return this.learnSignature(args);
      case 'getStatus':
        return this.getStatus(args);
      case 'listSignatures':
        return this.listSignatures(args);
      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  }

  private async findElement(args: Record<string, any>) {
    const input = FindElementInputSchema.parse(args);
    
    const result = await this.client.findElement(
      input.appBundleId,
      input.elementType as ElementType,
      input.policy
    );

    // Add human-readable summary
    return {
      success: result.success,
      confidence: result.confidence,
      element: {
        type: result.elementSignature.elementType,
        role: result.elementSignature.role,
        app: result.elementSignature.appBundleId,
        stability: result.elementSignature.stability,
      },
      detection: {
        method: result.evidence.method,
        heuristicScore: result.evidence.heuristicScore,
        diffScore: result.evidence.diffScore,
        ocrUsed: result.evidence.ocrChange,
      },
      signature: result.elementSignature,
      needsPermissions: result.needsPermissions,
      summary: result.success 
        ? `Successfully found ${input.elementType} element with ${Math.round(result.confidence * 100)}% confidence using ${result.evidence.method} method`
        : `Failed to find ${input.elementType} element. Confidence: ${Math.round(result.confidence * 100)}%. Missing: ${result.needsPermissions.join(', ')}`,
    };
  }

  private async afterSendDiff(args: Record<string, any>) {
    const input = AfterSendDiffInputSchema.parse(args);
    
    const result = await this.client.afterSendDiff(
      input.appBundleId,
      input.preSignature as ElementSignature,
      input.policy
    );

    const changesDetected = result.evidence.diffScore > 0.1 || result.evidence.ocrChange;

    return {
      success: result.success,
      confidence: result.confidence,
      changesDetected,
      detection: {
        method: result.evidence.method,
        diffScore: result.evidence.diffScore,
        ocrChange: result.evidence.ocrChange,
        notifications: result.evidence.notifications,
      },
      signature: result.elementSignature,
      summary: changesDetected
        ? `Changes detected after message send (${Math.round(result.confidence * 100)}% confidence)`
        : `No clear changes detected after message send`,
    };
  }

  private async observeElement(args: Record<string, any>) {
    const input = ObserveElementInputSchema.parse(args);
    
    const events: any[] = [];
    const startTime = Date.now();

    try {
      for await (const event of this.client.observeElement(
        input.appBundleId,
        input.signature as ElementSignature,
        input.durationSeconds,
        input.policy
      )) {
        if (event.type === 'event') {
          events.push({
            timestamp: new Date(event.timestamp * 1000).toISOString(),
            notification: event.notification,
            timeOffset: Math.round((event.timestamp * 1000 - startTime) / 1000 * 10) / 10, // seconds
          });
        } else if (event.type === 'complete') {
          break;
        }
      }
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : String(error),
        eventsCollected: events.length,
        events,
      };
    }

    return {
      success: true,
      duration: input.durationSeconds,
      eventsCollected: events.length,
      events,
      summary: `Observed ${events.length} events over ${input.durationSeconds} seconds`,
    };
  }

  private async captureSnapshot(args: Record<string, any>) {
    const input = CaptureSnapshotInputSchema.parse(args);
    
    const result = await this.client.captureSnapshot(
      input.appBundleId,
      input.signature as ElementSignature
    );

    if (!result.success) {
      return {
        success: false,
        error: result.error || 'Failed to capture snapshot',
      };
    }

    return {
      success: true,
      snapshot: result.snapshot,
      summary: result.snapshot 
        ? `Captured snapshot: ${result.snapshot.role} with ${result.snapshot.childCount} children, ${result.snapshot.textLength} chars`
        : 'Snapshot captured but no data available',
    };
  }

  private async learnSignature(args: Record<string, any>) {
    const input = LearnSignatureInputSchema.parse(args);
    
    const result = await this.client.learnSignature(
      input.signature as ElementSignature,
      input.pin,
      input.decay
    );

    return {
      success: result.success,
      action: result.action,
      signatureId: result.signatureId,
      summary: `Signature ${result.action} for ${input.signature.appBundleId}/${input.signature.elementType}`,
    };
  }

  private async getStatus(args: Record<string, any>) {
    const status = await this.client.getStatus();
    
    return {
      ...status,
      summary: status.canOperate 
        ? `UIScout is operational. ${status.store.signatureCount} signatures stored.`
        : `UIScout cannot operate. Missing permissions: ${status.permissions.needsPrompt.join(', ')}`,
    };
  }

  private async listSignatures(args: Record<string, any>) {
    const input = ListSignaturesInputSchema.parse(args);
    
    const result = await this.client.listSignatures(
      input.appBundleId,
      input.elementType as ElementType | undefined
    );

    // Group by app for better readability
    const byApp = result.signatures.reduce((acc, sig) => {
      if (!acc[sig.appBundleId]) {
        acc[sig.appBundleId] = [];
      }
      acc[sig.appBundleId].push({
        elementType: sig.elementType,
        role: sig.role,
        stability: Math.round(sig.stability * 100) / 100,
        lastVerified: new Date(sig.lastVerifiedAt * 1000).toISOString(),
      });
      return acc;
    }, {} as Record<string, any[]>);

    return {
      total: result.count,
      byApplication: byApp,
      signatures: result.signatures,
      summary: `Found ${result.count} signatures${input.appBundleId ? ` for ${input.appBundleId}` : ''}${input.elementType ? ` of type ${input.elementType}` : ''}`,
    };
  }
}
