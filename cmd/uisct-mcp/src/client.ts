import axios, { AxiosInstance, AxiosResponse } from 'axios';
import { z } from 'zod';

// Zod schemas for type safety
const ElementTypeSchema = z.enum(['reply', 'input', 'session']);

const PolicySchema = z.object({
  allowPeek: z.boolean().default(true),
  minConfidence: z.number().min(0).max(1).default(0.8),
  maxPeekMs: z.number().positive().default(250),
  rateLimitPeekSeconds: z.number().positive().default(10),
});

const ElementSignatureSchema = z.object({
  appBundleId: z.string(),
  elementType: ElementTypeSchema,
  role: z.string(),
  subroles: z.array(z.string()).default([]),
  frameHash: z.string(),
  pathHint: z.array(z.string()).default([]),
  siblingRoles: z.array(z.string()).default([]),
  readOnly: z.boolean().default(false),
  scrollable: z.boolean().default(false),
  attrs: z.record(z.any()).default({}),
  stability: z.number().min(0).max(1),
  lastVerifiedAt: z.number(),
});

const EvidenceSchema = z.object({
  method: z.enum(['passive', 'ocr', 'peek']),
  heuristicScore: z.number().min(0).max(1),
  diffScore: z.number().min(0).max(1),
  ocrChange: z.boolean().default(false),
  notifications: z.array(z.string()).default([]),
  confidence: z.number().min(0).max(1),
  timestamp: z.number(),
});

const ElementResultSchema = z.object({
  elementSignature: ElementSignatureSchema,
  confidence: z.number().min(0).max(1),
  evidence: EvidenceSchema,
  needsPermissions: z.array(z.string()).default([]),
  success: z.boolean(),
});

const ElementSnapshotSchema = z.object({
  elementId: z.string(),
  role: z.string(),
  frame: z.object({
    x: z.number(),
    y: z.number(),
    width: z.number(),
    height: z.number(),
  }),
  value: z.string().nullable(),
  childCount: z.number(),
  textLength: z.number(),
  timestamp: z.number(),
});

const StatusResponseSchema = z.object({
  permissions: z.object({
    accessibility: z.boolean(),
    screenRecording: z.boolean(),
    needsPrompt: z.array(z.string()),
    canOperate: z.boolean(),
  }),
  environment: z.object({
    isInTerminal: z.boolean(),
    isInXcode: z.boolean(),
    isSandboxed: z.boolean(),
    bundleIdentifier: z.string(),
    description: z.string(),
  }),
  store: z.object({
    signatureCount: z.number(),
    evidenceCount: z.number(),
    averageStability: z.number(),
    pinnedSignatureCount: z.number(),
  }),
  canOperate: z.boolean(),
});

// Type exports
export type ElementType = z.infer<typeof ElementTypeSchema>;
export type Policy = z.infer<typeof PolicySchema>;
export type ElementSignature = z.infer<typeof ElementSignatureSchema>;
export type Evidence = z.infer<typeof EvidenceSchema>;
export type ElementResult = z.infer<typeof ElementResultSchema>;
export type ElementSnapshot = z.infer<typeof ElementSnapshotSchema>;
export type StatusResponse = z.infer<typeof StatusResponseSchema>;

export interface ObservationEvent {
  timestamp: number;
  notification: string;
  appBundleId: string;
  type: 'event' | 'complete';
  total_events?: number;
}

export class UIScoutClient {
  private http: AxiosInstance;

  constructor(baseURL: string) {
    this.http = axios.create({
      baseURL: `${baseURL}/api/v1`,
      timeout: 30000,
      headers: {
        'Content-Type': 'application/json',
      },
    });
  }

  // Health check
  async checkHealth(): Promise<boolean> {
    try {
      const response = await this.http.get('/health', { timeout: 5000 });
      return response.status === 200;
    } catch {
      return false;
    }
  }

  // Find element
  async findElement(
    appBundleId: string,
    elementType: ElementType,
    policy?: Partial<Policy>
  ): Promise<ElementResult> {
    const requestData = {
      appBundleId,
      elementType,
      policy: policy ? PolicySchema.parse(policy) : undefined,
    };

    const response: AxiosResponse<ElementResult> = await this.http.post('/find', requestData);
    return ElementResultSchema.parse(response.data);
  }

  // After-send diff
  async afterSendDiff(
    appBundleId: string,
    preSignature: ElementSignature,
    policy?: Partial<Policy>
  ): Promise<ElementResult> {
    const requestData = {
      appBundleId,
      preSignature: ElementSignatureSchema.parse(preSignature),
      policy: policy ? PolicySchema.parse(policy) : undefined,
    };

    const response: AxiosResponse<ElementResult> = await this.http.post('/after-send-diff', requestData);
    return ElementResultSchema.parse(response.data);
  }

  // Observe element (streaming)
  async* observeElement(
    appBundleId: string,
    signature: ElementSignature,
    durationSeconds: number,
    policy?: Partial<Policy>
  ): AsyncGenerator<ObservationEvent, void, unknown> {
    const requestData = {
      appBundleId,
      signature: ElementSignatureSchema.parse(signature),
      durationSeconds,
      policy: policy ? PolicySchema.parse(policy) : undefined,
    };

    const response = await this.http.post('/observe', requestData, {
      responseType: 'stream',
      timeout: (durationSeconds + 5) * 1000, // Add buffer to timeout
    });

    const stream = response.data;
    let buffer = '';

    for await (const chunk of stream) {
      buffer += chunk.toString();
      
      // Process complete SSE messages
      let lineEnd;
      while ((lineEnd = buffer.indexOf('\n\n')) !== -1) {
        const message = buffer.slice(0, lineEnd);
        buffer = buffer.slice(lineEnd + 2);

        if (message.startsWith('data: ')) {
          const data = message.slice(6).trim();
          if (data) {
            try {
              const event: ObservationEvent = JSON.parse(data);
              yield event;
              
              if (event.type === 'complete') {
                return;
              }
            } catch (error) {
              console.error('Failed to parse SSE message:', data, error);
            }
          }
        }
      }
    }
  }

  // Capture snapshot
  async captureSnapshot(
    appBundleId: string,
    signature: ElementSignature
  ): Promise<{ snapshot: ElementSnapshot | null; success: boolean; error?: string }> {
    const requestData = {
      appBundleId,
      signature: ElementSignatureSchema.parse(signature),
    };

    const response = await this.http.post('/snapshot', requestData);
    
    const result = {
      snapshot: response.data.snapshot ? ElementSnapshotSchema.parse(response.data.snapshot) : null,
      success: response.data.success,
      error: response.data.error,
    };

    return result;
  }

  // Learn signature
  async learnSignature(
    signature: ElementSignature,
    pin: boolean = false,
    decay: boolean = false
  ): Promise<{ success: boolean; action: string; signatureId: string }> {
    const requestData = {
      signature: ElementSignatureSchema.parse(signature),
      pin,
      decay,
    };

    const response = await this.http.post('/learn', requestData);
    return response.data;
  }

  // Get status
  async getStatus(): Promise<StatusResponse> {
    const response: AxiosResponse<StatusResponse> = await this.http.get('/status');
    return StatusResponseSchema.parse(response.data);
  }

  // List signatures
  async listSignatures(
    appBundleId?: string,
    elementType?: ElementType
  ): Promise<{ signatures: ElementSignature[]; count: number }> {
    const params = new URLSearchParams();
    if (appBundleId) params.set('app', appBundleId);
    if (elementType) params.set('type', elementType);

    const response = await this.http.get('/signatures', { params });
    
    const signatures = response.data.signatures.map((sig: any) => ElementSignatureSchema.parse(sig));
    return {
      signatures,
      count: response.data.count,
    };
  }
}

export class UIScoutClientError extends Error {
  constructor(
    message: string,
    public statusCode?: number,
    public response?: any
  ) {
    super(message);
    this.name = 'UIScoutClientError';
  }
}

// Add response interceptor for error handling
export function setupClientErrorHandling(client: UIScoutClient): void {
  const httpClient = (client as any).http;
  
  httpClient.interceptors.response.use(
    (response: AxiosResponse) => response,
    (error: any) => {
      if (error.response) {
        // Server responded with error status
        const message = error.response.data?.message || error.response.statusText || 'API request failed';
        throw new UIScoutClientError(message, error.response.status, error.response.data);
      } else if (error.request) {
        // Request was made but no response received
        throw new UIScoutClientError('No response from UIScout service. Is it running?');
      } else {
        // Something else happened
        throw new UIScoutClientError(`Request setup failed: ${error.message}`);
      }
    }
  );
}
