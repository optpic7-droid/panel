#!/usr/bin/env node
/**
 * demo/server.mjs - runnable Petro Panel preview for restricted environments.
 *
 * This is NOT the production Pterodactyl binary (that needs PHP + MariaDB +
 * Redis and can only run on a real server). It is a zero-dependency Node
 * server that:
 *   - serves a small dashboard (login, nodes, locations, allocations, logs)
 *   - implements the SAME Application API contract that scripts/30-connect-
 *     node.sh talks to (locations, nodes, allocations, /configuration)
 * so the entire node-connection flow can be demonstrated end-to-end on any
 * machine with Node 18+, including this sandbox.
 *
 * Run:   node demo/server.mjs            # random free port
 *        PORT=8791 node demo/server.mjs  # fixed port
 * State persists in demo/data.json. First stdout line reports the port.
 */
import http from 'node:http';
import { randomUUID, randomBytes } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(HERE, 'public');
const DATA_FILE = path.join(HERE, 'data.json');
const PORT = Number(process.env.PORT || 0);
const HOST = process.env.HOST || '0.0.0.0';

// ---------------------------------------------------------------------------
// Persistent demo state
// ---------------------------------------------------------------------------
function defaultState() {
  return {
    apiKey: 'ptla_demo_' + randomBytes(12).toString('hex'),
    users: [{ username: 'admin', password: 'petro-demo' }],
    locations: [],
    nodes: [],
    allocations: [],
    counters: { location: 0, node: 0 },
    activity: [],
  };
}

let state = defaultState();
if (existsSync(DATA_FILE)) {
  try {
    state = { ...defaultState(), ...JSON.parse(await readFile(DATA_FILE, 'utf8')) };
  } catch {
    console.error('warning: demo/data.json unreadable, starting fresh');
  }
}

let saveTimer = null;
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => writeFile(DATA_FILE, JSON.stringify(state, null, 2)), 150);
}

// In-memory browser sessions for the dashboard (not part of the real API).
const sessions = new Map();

function logActivity(method, urlPath, status, auth) {
  state.activity.unshift({
    ts: new Date().toISOString(),
    method, path: urlPath, status,
    auth: auth ? (auth.slice(0, 14) + '...') : 'dashboard',
  });
  state.activity = state.activity.slice(0, 100);
  persist();
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function sendJson(res, code, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      if (raw.length > 1_000_000) reject(new Error('body too large'));
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch { reject(new Error('invalid JSON')); }
    });
    req.on('error', reject);
  });
}

function parseCookies(req) {
  const out = {};
  for (const part of (req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function requireDashboardSession(req, res) {
  const sid = parseCookies(req).petro_demo_sid;
  if (!sid || !sessions.has(sid)) {
    sendJson(res, 401, { errors: [{ detail: 'login required' }] });
    return null;
  }
  return sessions.get(sid);
}

async function serveStatic(req, res, urlPath) {
  const rel = urlPath === '/' ? '/index.html' : urlPath;
  const file = path.normalize(path.join(PUBLIC_DIR, rel));
  if (!file.startsWith(PUBLIC_DIR)) { res.writeHead(403); return res.end(); }
  try {
    const data = await readFile(file);
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404); res.end('not found');
  }
}

// ---------------------------------------------------------------------------
// Real Pterodactyl Application API contract (used by scripts/30-connect-node)
// ---------------------------------------------------------------------------
function applicationApi(req, res, urlPath, method) {
  const auth = req.headers.authorization || '';
  if (auth !== `Bearer ${state.apiKey}`) {
    logActivity(method, urlPath, 401, auth);
    return sendJson(res, 401, { errors: [{ detail: 'The provided authorization token is invalid.' }] });
  }

  // GET /nodes, GET /locations
  if (method === 'GET' && urlPath === '/api/application/nodes') {
    logActivity(method, urlPath, 200, auth);
    return sendJson(res, 200, { data: state.nodes.map((n) => ({ attributes: n })) });
  }
  if (method === 'GET' && urlPath === '/api/application/locations') {
    logActivity(method, urlPath, 200, auth);
    return sendJson(res, 200, { data: state.locations.map((l) => ({ attributes: l })) });
  }

  // POST /locations
  if (method === 'POST' && urlPath === '/api/application/locations') {
    const attrs = req.body;
    const loc = { id: ++state.counters.location, short: attrs.short, long: attrs.long || '' };
    state.locations.push(loc);
    logActivity(method, urlPath, 201, auth); persist();
    return sendJson(res, 201, { attributes: loc });
  }

  // POST /nodes
  if (method === 'POST' && urlPath === '/api/application/nodes') {
    const attrs = req.body;
    const node = {
      id: ++state.counters.node,
      uuid: randomUUID(),
      daemon_token_id: 'ptla_demo_' + randomBytes(6).toString('hex'),
      daemon_token: randomBytes(24).toString('hex'),
      configured: false,
      heartbeat_at: null,
      created_at: new Date().toISOString(),
      ...attrs,
    };
    state.nodes.push(node);
    logActivity(method, urlPath, 201, auth); persist();
    return sendJson(res, 201, { attributes: node });
  }

  let m = urlPath.match(/^\/api\/application\/nodes\/(\d+)\/allocations$/);
  if (method === 'POST' && m) {
    const nodeId = Number(m[1]);
    const node = state.nodes.find((n) => n.id === nodeId);
    if (!node) { logActivity(method, urlPath, 404, auth); return sendJson(res, 404, { errors: [{ detail: 'node not found' }] }); }
    for (const port of req.body.ports || []) {
      state.allocations.push({ id: state.allocations.length + 1, node_id: nodeId, ip: req.body.ip, alias: req.body.alias || null, port: Number(port) });
    }
    logActivity(method, urlPath, 204, auth); persist();
    res.writeHead(204);
    return res.end();
  }

  // GET /nodes/:id/configuration - mirrors Node::getConfiguration()
  m = urlPath.match(/^\/api\/application\/nodes\/(\d+)\/configuration$/);
  if (method === 'GET' && m) {
    const node = state.nodes.find((n) => n.id === Number(m[1]));
    if (!node) { logActivity(method, urlPath, 404, auth); return sendJson(res, 404, { errors: [{ detail: 'node not found' }] }); }
    node.configured = true;
    node.heartbeat_at = new Date().toISOString();
    const origin = `${req.headers['x-forwarded-proto'] || 'http'}://${req.headers.host}`;
    logActivity(method, urlPath, 200, auth); persist();
    return sendJson(res, 200, {
      debug: false,
      uuid: node.uuid,
      token_id: node.daemon_token_id,
      token: node.daemon_token,
      api: {
        host: '0.0.0.0',
        port: node.daemon_listen,
        ssl: {
          enabled: !node.behind_proxy && node.scheme === 'https',
          cert: `/etc/letsencrypt/live/${node.fqdn}/fullchain.pem`,
          key: `/etc/letsencrypt/live/${node.fqdn}/privkey.pem`,
        },
        upload_limit: node.upload_size,
      },
      system: { data: node.daemon_base, sftp: { bind_port: node.daemon_sftp } },
      allowed_mounts: [],
      remote: origin,
    });
  }

  // GET /nodes/:id
  m = urlPath.match(/^\/api\/application\/nodes\/(\d+)$/);
  if (method === 'GET' && m) {
    const node = state.nodes.find((n) => n.id === Number(m[1]));
    if (!node) { logActivity(method, urlPath, 404, auth); return sendJson(res, 404, { errors: [{ detail: 'node not found' }] }); }
    logActivity(method, urlPath, 200, auth);
    return sendJson(res, 200, { attributes: node });
  }

  logActivity(method, urlPath, 404, auth);
  sendJson(res, 404, { errors: [{ detail: `no mock route for ${method} ${urlPath}` }] });
}

// ---------------------------------------------------------------------------
// Dashboard-only endpoints (browser session, not part of Pterodactyl API)
// ---------------------------------------------------------------------------
async function dashboardApi(req, res, urlPath, method) {
  if (method === 'POST' && urlPath === '/api/demo/login') {
    const { username, password } = req.body;
    const user = state.users.find((u) => u.username === username && u.password === password);
    if (!user) { logActivity(method, urlPath, 401); return sendJson(res, 401, { errors: [{ detail: 'invalid credentials' }] }); }
    const sid = randomBytes(24).toString('hex');
    sessions.set(sid, { username });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Set-Cookie': `petro_demo_sid=${sid}; HttpOnly; Path=/; SameSite=Lax`,
    });
    logActivity(method, urlPath, 200);
    return res.end(JSON.stringify({ ok: true, username }));
  }

  if (method === 'POST' && urlPath === '/api/demo/logout') {
    const sid = parseCookies(req).petro_demo_sid;
    sessions.delete(sid);
    res.writeHead(200, { 'Content-Type': 'application/json', 'Set-Cookie': 'petro_demo_sid=; Max-Age=0; Path=/' });
    return res.end(JSON.stringify({ ok: true }));
  }

  const session = requireDashboardSession(req, res);
  if (!session) return;

  if (method === 'GET' && urlPath === '/api/demo/me') {
    return sendJson(res, 200, { username: session.username, apiKey: state.apiKey });
  }
  if (method === 'GET' && urlPath === '/api/demo/state') {
    return sendJson(res, 200, {
      locations: state.locations,
      nodes: state.nodes,
      allocations: state.allocations,
      counts: {
        locations: state.locations.length,
        nodes: state.nodes.length,
        allocations: state.allocations.length,
        connected: state.nodes.filter((n) => n.configured).length,
      },
    });
  }
  if (method === 'GET' && urlPath === '/api/demo/activity') {
    return sendJson(res, 200, { activity: state.activity.slice(0, 50) });
  }

  sendJson(res, 404, { errors: [{ detail: 'unknown dashboard route' }] });
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, `http://${req.headers.host}`);
  const urlPath = u.pathname;
  const method = req.method;

  try {
    if (urlPath === '/healthz' || urlPath === '/api/system') {
      return sendJson(res, 200, { name: 'petro-panel-demo', version: '1.11.10-demo', status: 'operational' });
    }

    if (urlPath.startsWith('/api/application/')) {
      req.body = await readBody(req);
      return applicationApi(req, res, urlPath, method);
    }
    if (urlPath.startsWith('/api/demo/')) {
      req.body = await readBody(req);
      return dashboardApi(req, res, urlPath, method);
    }
    if (urlPath.startsWith('/api/')) {
      return sendJson(res, 404, { errors: [{ detail: 'demo server: only Application API endpoints are emulated' }] });
    }
    return serveStatic(req, res, urlPath);
  } catch (err) {
    return sendJson(res, 400, { errors: [{ detail: err.message }] });
  }
});

server.listen(PORT, HOST, () => {
  const actual = server.address().port;
  // First line is machine-readable for test harnesses.
  console.log(`PETRO_DEMO_PORT=${actual}`);
  console.log(`Petro Panel demo listening on http://${HOST}:${actual}`);
  console.log(`Dashboard login: admin / petro-demo`);
  console.log(`Application API key: ${state.apiKey}`);
  console.log(`State file: ${DATA_FILE}`);
});
