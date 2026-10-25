#!/usr/bin/env node
/**
 * tests/mock-panel.mjs - tiny in-memory mock of the Pterodactyl Application API
 * for offline integration testing of scripts/30-connect-node.sh.
 * Listens on 127.0.0.1:0 and prints the chosen port as the first stdout line.
 */
import { createServer } from 'node:http';

const state = { locations: [], nodes: [], allocations: [], nextLocationId: 1, nextNodeId: 1 };

const json = (res, code, payload) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(payload === undefined ? '' : JSON.stringify(payload));
};

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;

    if (req.headers.authorization !== 'Bearer ptla_test') {
      return json(res, 401, { errors: [{ detail: 'bad token' }] });
    }

    // GET /nodes (list)
    if (req.method === 'GET' && path === '/api/application/nodes') {
      return json(res, 200, { data: state.nodes.map((n) => ({ attributes: n })) });
    }
    // GET /locations
    if (req.method === 'GET' && path === '/api/application/locations') {
      return json(res, 200, { data: state.locations.map((l) => ({ attributes: l })) });
    }
    // POST /locations
    if (req.method === 'POST' && path === '/api/application/locations') {
      const attrs = JSON.parse(body);
      const loc = { id: state.nextLocationId++, ...attrs };
      state.locations.push(loc);
      return json(res, 201, { attributes: loc });
    }
    // POST /nodes
    if (req.method === 'POST' && path === '/api/application/nodes') {
      const attrs = JSON.parse(body);
      const node = { id: state.nextNodeId++, ...attrs };
      state.nodes.push(node);
      return json(res, 201, { attributes: node });
    }
    // POST /nodes/:id/allocations
    let m = path.match(/^\/api\/application\/nodes\/(\d+)\/allocations$/);
    if (req.method === 'POST' && m) {
      state.allocations.push({ node: Number(m[1]), ...JSON.parse(body) });
      res.writeHead(204);
      return res.end();
    }
    // GET /nodes/:id/configuration
    m = path.match(/^\/api\/application\/nodes\/(\d+)\/configuration$/);
    if (req.method === 'GET' && m) {
      return json(res, 200, {
        debug: false,
        uuid: '11111111-2222-4333-8444-555555555555',
        token_id: 'ptla-mock-token-id',
        token: 'mock-daemon-token',
        api: { host: '0.0.0.0', port: 8080, ssl: { enabled: false, cert: '', key: '' }, upload_limit: 100 },
        system: { data: '/var/lib/pterodactyl/volumes', sftp: { bind_port: 2022 } },
        allowed_mounts: [],
        remote: `http://127.0.0.1:${server.address().port}`,
      });
    }
    // GET /nodes/:id
    m = path.match(/^\/api\/application\/nodes\/(\d+)$/);
    if (req.method === 'GET' && m) {
      const node = state.nodes.find((n) => n.id === Number(m[1]));
      return json(res, 200, { attributes: node });
    }

    json(res, 404, { errors: [{ detail: `no mock route for ${req.method} ${path}` }] });
  });
});

server.listen(0, '127.0.0.1', () => {
  console.log(server.address().port);
});
