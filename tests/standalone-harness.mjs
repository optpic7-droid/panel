/**
 * tests/standalone-harness.mjs - functional test for the in-browser mock API
 * embedded in docs/petro-demo.html. Minimal browser globals are stubbed, the
 * page script is evaluated, and the same node-connect sequence is exercised.
 */
import { readFile, writeFile, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

const html = await readFile('docs/petro-demo.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

const storage = () => {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)),
           removeItem: (k) => m.delete(k), clear: () => m.clear(), _m: m };
};

const fakeEl = () => new Proxy({
  classList: { add() {}, remove() {}, contains: () => false },
  addEventListener() {}, appendChild() {}, querySelector: () => ({ innerHTML: '' }),
  style: {}, disabled: false, innerHTML: '', textContent: '',
}, { get(t, k) { return k in t ? t[k] : (typeof k === 'string' ? (t[k] = t[k] ?? fakeEl()) : undefined); },
     set(t, k, v) { t[k] = v; return true; } });

const sandbox = {
  console,
  localStorage: storage(),
  sessionStorage: storage(),
  document: { getElementById: () => fakeEl(), querySelectorAll: () => [], createElement: () => fakeEl() },
  crypto,
  Blob: class { constructor(parts) { this.parts = parts; } },
  URL: { createObjectURL: () => 'blob:demo', revokeObjectURL() {} },
  confirm: () => true,
  setTimeout,
};
sandbox.window = sandbox;

const vm = await import('node:vm');
const ctx = vm.createContext(sandbox);
// const/let bindings stay lexical; expose what the test needs explicitly.
vm.runInContext(script + '\nglobalThis.__test = { MockApi, state, renderConfigYml };', ctx);

const api = sandbox.__test.MockApi;
assert.ok(api, 'MockApi exposed');
const H = { Authorization: 'Bearer ' + sandbox.__test.state.apiKey, 'Content-Type': 'application/json' };

// auth rejection
assert.throws(() => api.call('GET', '/api/application/nodes', null, {}),
  (e) => e.status === 401, 'bad token rejected');

// full sequence, mirroring 30-connect-node.sh
assert.equal(api.call('GET', '/api/application/nodes', null, H).data.length, 0, 'starts with no nodes');
const loc = api.call('POST', '/api/application/locations', { short: 'loc1', long: 'Default location' }, H);
assert.equal(loc.attributes.id, 1, 'location created');
const node = api.call('POST', '/api/application/nodes', {
  public: true, name: 'node-1', location_id: 1, fqdn: 'node.local', scheme: 'http',
  behind_proxy: false, maintenance_mode: false, memory: 8192, memory_overallocate: 0,
  disk: 20480, disk_overallocate: 0, upload_size: 100, daemon_listen: 8080,
  daemon_sftp: 2022, daemon_base: '/var/lib/pterodactyl/volumes',
}, H);
assert.equal(node.attributes.id, 1, 'node created');
assert.equal(api.call('POST', '/api/application/nodes/1/allocations',
  { ip: '127.0.0.1', ports: ['25565', '25570', '25571', '25572'] }, H), null, 'allocations 204');
const cfg = api.call('GET', '/api/application/nodes/1/configuration', null, H);
assert.equal(cfg.api.port, 8080);
assert.equal(cfg.system.sftp.bind_port, 2022);
assert.ok(cfg.token_id.startsWith('ptla_'));
assert.equal(cfg.allowed_mounts.length, 0);

// node now connected + allocations counted
assert.equal(sandbox.__test.state.nodes[0].configured, true, 'node marked connected');
assert.equal(sandbox.__test.state.allocations.length, 4, 'four allocations stored');

// persistence round-trip through localStorage
const raw = sandbox.localStorage.getItem('petro-standalone-demo');
assert.ok(raw.includes('"configured":true'), 'state persisted to localStorage');

// 404 for unknown routes
assert.throws(() => api.call('GET', '/api/application/nodes/999', null, H),
  (e) => e.status === 404, 'unknown route 404');

console.log('standalone mock API: all assertions passed');
