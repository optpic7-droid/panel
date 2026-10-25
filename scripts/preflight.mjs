#!/usr/bin/env node
/**
 * scripts/preflight.mjs - zero-dependency readiness check for the Petro Panel.
 * Runs on any machine with Node.js 18+ (no npm install needed).
 *
 * Usage: node scripts/preflight.mjs [--json]
 */

import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { createServer } from 'node:net';
import { resolve4, resolve6 } from 'node:dns/promises';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

const ROOT = path.resolve(new URL('..', import.meta.url).pathname);
const asJson = process.argv.includes('--json');
const results = [];

const c = asJson ? {} : {
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m', blue: '\x1b[34m', bold: '\x1b[1m', reset: '\x1b[0m',
};

function record(status, check, detail = '') {
  results.push({ status, check, detail });
  if (asJson) return;
  const tag = { ok: `${c.green}  OK  ${c.reset}`, warn: `${c.yellow} WARN ${c.reset}`, fail: `${c.red} FAIL ${c.reset}` }[status];
  console.log(`${tag} ${check.padEnd(34)} ${detail}`);
}

function loadEnv() {
  const env = { ...process.env };
  const file = path.join(ROOT, '.env');
  if (!existsSync(file)) return env;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    env[m[1]] ??= v;
  }
  return env;
}

const env = loadEnv();

function which(bin) {
  try {
    return execFileSync('bash', ['-lc', `command -v ${bin}`], { encoding: 'utf8' }).trim() || null;
  } catch {
    return null;
  }
}

function versionOf(bin, args = ['--version']) {
  try {
    return execFileSync(bin, args, { encoding: 'utf8' }).trim().split('\n')[0];
  } catch {
    return null;
  }
}

function readOsRelease() {
  try {
    return Object.fromEntries(
      readFileSync('/etc/os-release', 'utf8').split('\n')
        .map((l) => l.match(/^([A-Z0-9_]+)=(.*)$/))
        .filter(Boolean)
        .map(([, k, v]) => [k, v.replaceAll('"', '')]),
    );
  } catch {
    return {};
  }
}

function portFree(port) {
  return new Promise((resolve) => {
    const srv = createServer();
    srv.once('error', () => resolve(false));
    srv.once('listening', () => srv.close(() => resolve(true)));
    srv.listen(port, '0.0.0.0');
  });
}

async function dnsResolves(host) {
  if (!host || /^\d+\.\d+\.\d+\.\d+$/.test(host)) return true;
  try {
    await Promise.any([resolve4(host), resolve6(host)]);
    return true;
  } catch {
    return false;
  }
}

async function main() {
  // Privileges
  record(process.getuid && process.getuid() === 0 ? 'ok' : 'fail', 'running as root',
    process.getuid ? `uid=${process.getuid()}` : 'uid unknown');

  // OS
  const osr = readOsRelease();
  const supported = (osr.ID === 'debian' && /^1[12]$/.test(osr.VERSION_ID || ''))
    || (osr.ID === 'ubuntu' && /^(20.04|22.04|24.04)$/.test(osr.VERSION_ID || ''));
  record(supported ? 'ok' : 'fail', 'supported OS',
    osr.PRETTY_NAME || 'unknown (need Debian 11/12 or Ubuntu 20.04+)');

  // Resources
  const memGb = os.totalmem() / 1024 ** 3;
  record(memGb >= 2 ? 'ok' : 'warn', 'memory >= 2 GiB', `${memGb.toFixed(1)} GiB`);
  const gb = 1024 ** 3;
  let freeGb = 0;
  try {
    const out = execFileSync('df', ['-PB1', '/'], { encoding: 'utf8' }).trim().split('\n')[1].split(/\s+/);
    freeGb = Number(out[3]) / gb;
  } catch { /* ignore */ }
  record(freeGb >= 15 ? 'ok' : 'warn', 'free disk on / >= 15 GiB', `${freeGb.toFixed(1)} GiB`);

  // Required tooling
  for (const bin of ['curl', 'tar', 'gzip', 'bash', 'systemctl']) {
    record(which(bin) ? 'ok' : 'fail', `command: ${bin}`, which(bin) || 'missing');
  }

  // Existing stack (informational)
  for (const [bin, label, args] of [
    ['php', 'php (panel)', ['--version']],
    ['mysql', 'mariadb client', ['--version']],
    ['redis-server', 'redis', ['--version']],
    ['nginx', 'nginx', ['-v']],
    ['docker', 'docker', ['--version']],
    ['wings', 'wings (node)', ['version']],
    ['composer', 'composer', ['--version']],
  ]) {
    const p = which(bin);
    record(p ? 'ok' : 'warn', label, p ? versionOf(p, args) ?? 'installed' : 'not installed yet');
  }

  // Ports needed by panel + node
  for (const port of [80, 443, Number(env.NODE_DAEMON_PORT) || 8080, Number(env.NODE_SFTP_PORT) || 2022]) {
    record(await portFree(port) ? 'ok' : 'warn', `port ${port} free`, await portFree(port) ? 'available' : 'in use');
  }

  // DNS
  if (env.PANEL_FQDN) {
    record(await dnsResolves(env.PANEL_FQDN) ? 'ok' : 'warn', 'PANEL_FQDN resolves', env.PANEL_FQDN);
  }
  if (env.NODE_FQDN && env.NODE_FQDN !== env.PANEL_FQDN) {
    record(await dnsResolves(env.NODE_FQDN) ? 'ok' : 'warn', 'NODE_FQDN resolves', env.NODE_FQDN);
  }

  // Panel reachability (only meaningful when connecting a node)
  if (env.PANEL_URL) {
    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 6000);
      const res = await fetch(`${env.PANEL_URL.replace(/\/$/, '')}/`, { signal: ctrl.signal });
      clearTimeout(t);
      record(res.ok || res.status < 500 ? 'ok' : 'warn', 'panel URL reachable', `${env.PANEL_URL} -> HTTP ${res.status}`);
    } catch {
      record('warn', 'panel URL reachable', `${env.PANEL_URL} not reachable from here`);
    }
  }

  if (env.APPLICATION_API_KEY && !env.APPLICATION_API_KEY.startsWith('ptla_')) {
    record('warn', 'APPLICATION_API_KEY format', 'node keys start with ptla_');
  }

  if (asJson) {
    console.log(JSON.stringify({ generatedAt: new Date().toISOString(), results }, null, 2));
  } else {
    const fails = results.filter((r) => r.status === 'fail').length;
    const warns = results.filter((r) => r.status === 'warn').length;
    console.log(`\n${c.bold}Summary:${c.reset} ${results.length} checks, ${fails} failures, ${warns} warnings.`);
    process.exit(fails ? 1 : 0);
  }
}

main().catch((err) => {
  console.error('preflight crashed:', err);
  process.exit(2);
});
