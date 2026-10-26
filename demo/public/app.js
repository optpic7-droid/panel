/* Petro Panel demo dashboard - vanilla JS, relative URLs (works behind proxies) */
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

async function api(path, opts = {}) {
  const res = await fetch(path, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) },
    ...opts,
  });
  const data = view401(res, path) ? null : await res.json().catch(() => ({}));
  if (!res.ok && data) throw new Error((data.errors || []).map((e) => e.detail).join(', ') || res.status);
  return data;
}
function view401(res, path) {
  if (res.status === 401 && !path.startsWith('/api/demo/login')) {
    showLogin();
    return true;
  }
  return false;
}

/* ---- login ---------------------------------------------------------------- */
$('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    await api('/api/demo/login', {
      method: 'POST',
      body: JSON.stringify({ username: $('login-username').value, password: $('login-password').value }),
    });
    await boot();
  } catch (err) {
    const el = $('login-error');
    el.textContent = err.message;
    el.classList.remove('hidden');
  }
});

$('logout').addEventListener('click', async () => {
  await api('/api/demo/logout', { method: 'POST' });
  showLogin();
});

/* ---- views --------------------------------------------------------------- */
const TITLES = {
  overview: 'Overview', nodes: 'Nodes', locations: 'Locations',
  allocations: 'Allocations', connect: 'Connect a node', activity: 'Activity log',
};
document.querySelectorAll('.nav-item').forEach((btn) => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.nav-item').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    document.querySelectorAll('.view').forEach((v) => v.classList.add('hidden'));
    $('view-title').textContent = TITLES[btn.dataset.view];
    $('view-' + btn.dataset.view).classList.remove('hidden');
    refresh();
  });
});

/* ---- data rendering ------------------------------------------------------ */
function statusHtml(node) {
  return node.configured
    ? '<span class="dot dot-ok"></span><span class="status-ok">connected</span>'
    : '<span class="dot dot-off"></span><span class="status-off">awaiting configuration</span>';
}

function renderState(s) {
  $('c-nodes').textContent = s.counts.nodes;
  $('c-connected').textContent = s.counts.connected;
  $('c-locations').textContent = s.counts.locations;
  $('c-allocations').textContent = s.counts.allocations;

  $('nodes-body').innerHTML = s.nodes.length ? s.nodes.map((n) => `
    <tr>
      <td>${n.id}</td><td><strong>${esc(n.name)}</strong></td><td>${esc(n.fqdn)}</td>
      <td>${esc(n.scheme)}</td><td>${n.daemon_listen}</td><td>${n.daemon_sftp}</td>
      <td>${Number(n.memory).toLocaleString()} MiB</td><td>${Number(n.disk).toLocaleString()} MiB</td>
      <td>${statusHtml(n)}</td>
    </tr>`).join('') : '<tr><td colspan="9" class="dim">No nodes yet — run the connect command.</td></tr>';

  $('locations-body').innerHTML = s.locations.length ? s.locations.map((l) => `
    <tr><td>${l.id}</td><td>${esc(l.short)}</td><td>${esc(l.long)}</td></tr>`).join('')
    : '<tr><td colspan="3" class="dim">No locations yet.</td></tr>';

  const nodeName = (id) => (s.nodes.find((n) => n.id === id) || {}).name || `#${id}`;
  $('allocations-body').innerHTML = s.allocations.length ? s.allocations.map((a) => `
    <tr><td>${a.id}</td><td>${esc(nodeName(a.node_id))}</td><td>${esc(a.ip)}</td>
    <td>${esc(a.alias || '—')}</td><td>${a.port}</td></tr>`).join('')
    : '<tr><td colspan="5" class="dim">No allocations yet.</td></tr>';
}

function renderActivity(entries) {
  $('activity-body').innerHTML = entries.length ? entries.map((e) => {
    const cls = String(e.status).startsWith('2') ? 'h-20x' : 'h-4xx';
    return `<tr>
      <td class="dim">${new Date(e.ts).toLocaleTimeString()}</td>
      <td class="method-${esc(e.method)}">${esc(e.method)}</td>
      <td><code>${esc(e.path)}</code></td>
      <td class="${cls}">${e.status}</td>
      <td class="dim">${esc(e.auth)}</td>
    </tr>`;
  }).join('') : '<tr><td colspan="5" class="dim">No API calls yet.</td></tr>';
}

async function refresh() {
  try {
    const [s, a] = await Promise.all([api('/api/demo/state'), api('/api/demo/activity')]);
    renderState(s);
    renderActivity(a.activity);
  } catch { /* transient poll error; next tick retries */ }
}

async function boot() {
  const me = await api('/api/demo/me').catch(() => null);
  if (!me) return showLogin();
  $('whoami').textContent = '@' + me.username;
  $('api-key').textContent = me.apiKey;
  const origin = location.origin;
  $('connect-cmd').textContent =
    `sudo -n env \\\n  PANEL_URL=${origin} \\\n  APPLICATION_API_KEY=${me.apiKey} \\\n  NODE_NAME=node-1 NODE_FQDN=node.local NODE_SCHEME=http \\\n  LOCATION_SHORT=loc1 ALLOCATION_IP=127.0.0.1 ALLOCATION_PORTS=25565,25570-25572 \\\n  WINGS_CONFIG_PATH=/tmp/petro-demo-wings \\\n  bash scripts/30-connect-node.sh`;
  $('login-view').classList.add('hidden');
  $('app-view').classList.remove('hidden');
  await refresh();
}

function showLogin() {
  $('app-view').classList.add('hidden');
  $('login-view').classList.remove('hidden');
}

boot();
setInterval(() => { if (!$('app-view').classList.contains('hidden')) refresh(); }, 3000);
