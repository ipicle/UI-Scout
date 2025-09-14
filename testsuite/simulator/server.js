#!/usr/bin/env node
/*
  UIScout Mock Service (no dependencies)
  Implements minimal endpoints to simulate the real HTTP API for E2E tests.
*/

const http = require('http');
const url = require('url');

const args = process.argv.slice(2);
let port = 18080;
let scenarioPath = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port') port = Number(args[++i] || port);
  else if (args[i] === '--scenario') scenarioPath = args[++i] || null;
}

let scenario = {
  appBundleId: 'com.example.app',
  elementType: 'reply',
  role: 'Group',
  frameHash: 'w400-h300-x0-y0@sha1'
};

if (scenarioPath) {
  try {
    scenario = JSON.parse(require('fs').readFileSync(scenarioPath, 'utf8'));
  } catch (e) {
    console.error('[sim] Failed to load scenario, using defaults:', e.message);
  }
}

function json(res, code, body) {
  const s = JSON.stringify(body);
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(s)
  });
  res.end(s);
}

function readJson(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (chunk) => (data += chunk));
    req.on('end', () => {
      try { resolve(JSON.parse(data || '{}')); }
      catch { resolve({}); }
    });
  });
}

const server = http.createServer(async (req, res) => {
  const { pathname } = url.parse(req.url, true);

  if (req.method === 'GET' && pathname === '/health') {
    return json(res, 200, { status: 'ok', timestamp: Date.now() / 1000 });
  }

  if (req.method === 'POST' && pathname === '/api/v1/find') {
    const body = await readJson(req);
    const elementType = body.elementType || scenario.elementType;
    const appBundleId = body.appBundleId || scenario.appBundleId;
    const result = mockElementResult(appBundleId, elementType, 0.87, 'passive');
    return json(res, 200, elementResultResponse(result));
  }

  if (req.method === 'POST' && pathname === '/api/v1/after-send-diff') {
    const body = await readJson(req);
    const pre = body.preSignature || mockSignature();
    const result = mockElementResult(pre.appBundleId, pre.elementType, 0.76, 'ocr');
    return json(res, 200, elementResultResponse(result));
  }

  if (req.method === 'POST' && pathname === '/api/v1/snapshot') {
    return json(res, 200, { success: true, snapshot: mockSnapshot(), error: null });
  }

  if (req.method === 'POST' && pathname === '/api/v1/learn') {
    return json(res, 200, { success: true, action: 'stored', signatureId: scenario.appBundleId + '-reply' });
  }

  if (req.method === 'GET' && pathname === '/api/v1/status') {
    return json(res, 200, {
      permissions: { accessibility: true, screenRecording: false, needsPrompt: [], canOperate: true },
      environment: { isInTerminal: true, isInXcode: false, isSandboxed: false, bundleIdentifier: 'sim', description: 'Simulator' },
      store: { signatureCount: 1, evidenceCount: 2, averageStability: 0.82, pinnedSignatureCount: 0 },
      canOperate: true
    });
  }

  if (req.method === 'GET' && pathname === '/api/v1/signatures') {
    return json(res, 200, { signatures: [mockSignature()], count: 1 });
  }

  if (req.method === 'POST' && pathname === '/api/v1/observe') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive'
    });

    const send = (obj) => res.write('data: ' + JSON.stringify(obj) + '\n\n');
    send({ type: 'event', timestamp: Date.now() / 1000, notification: 'kAXChildrenChangedNotification', appBundleId: scenario.appBundleId });
    setTimeout(() => send({ type: 'event', timestamp: Date.now() / 1000, notification: 'kAXValueChangedNotification', appBundleId: scenario.appBundleId }), 150);
    setTimeout(() => res.end(), 300);
    return;
  }

  res.writeHead(404); res.end();
});

server.listen(port, () => {
  console.log(`[sim] UIScout mock service listening on http://127.0.0.1:${port}`);
});

// Helpers
function mockSignature() {
  return {
    appBundleId: scenario.appBundleId,
    elementType: scenario.elementType,
    role: scenario.role,
    subroles: [],
    frameHash: scenario.frameHash,
    pathHint: ['Window[0]', 'Group[1]'],
    siblingRoles: ['Group', 'ScrollArea'],
    readOnly: true,
    scrollable: true,
    attrs: {},
    stability: 0.8,
    lastVerifiedAt: Date.now() / 1000
  };
}

function mockSnapshot() {
  return {
    elementId: 'element-123',
    role: 'Group',
    frame: { x: 0, y: 0, width: 400, height: 300 },
    value: null,
    childCount: 5,
    textLength: 350,
    timestamp: Date.now() / 1000
  };
}

function mockElementResult(appBundleId, elementType, confidence, method) {
  const sig = mockSignature();
  sig.appBundleId = appBundleId;
  sig.elementType = elementType;
  return {
    elementSignature: sig,
    confidence,
    evidence: {
      method,
      heuristicScore: 0.7,
      diffScore: 0.2,
      ocrChange: method === 'ocr',
      notifications: [],
      confidence,
      timestamp: Date.now() / 1000
    },
    needsPermissions: []
  };
}

function elementResultResponse(result) {
  return {
    elementSignature: result.elementSignature,
    confidence: result.confidence,
    evidence: result.evidence,
    needsPermissions: result.needsPermissions,
    success: result.confidence > 0.5
  };
}

