/* =============================================================================
 * AADC PoC 검증 화면
 *
 * 브라우저가 직접 두드리는 것은 자기 WEB 하나뿐이다. 나머지(점검 VS, 반대편 DC)는
 * nginx 가 /checkvs/, /peer/ 로 대신 물어본다. CORS 를 피하려는 것도 있지만,
 * 더 중요한 이유는 **실제 서비스 경로와 같은 곳에서 본 결과**여야 의미가 있기 때문이다.
 * ============================================================================= */
'use strict';

const $  = (s) => document.querySelector(s);
const el = (t, c, txt) => { const e = document.createElement(t); if (c) e.className = c; if (txt != null) e.textContent = txt; return e; };

const state = { last: {}, timer: null };

/* ---------- 유틸 ---------- */
async function probe(url, opts = {}) {
  const t0 = performance.now();
  try {
    const res = await fetch(url, { cache: 'no-store', ...opts });
    const ms = Math.round(performance.now() - t0);
    let body = null;
    try { body = await res.json(); } catch { body = { raw: await res.text().catch(() => '') }; }
    return { ok: res.ok, status: res.status, ms, body };
  } catch (e) {
    return { ok: false, status: 0, ms: Math.round(performance.now() - t0),
             body: { error: String(e && e.message || e) } };
  }
}

function logEvent(msg) {
  const pre = $('#eventLog');
  pre.textContent = new Date().toISOString() + '  ' + msg + '\n' + pre.textContent;
}

/* 상태가 바뀐 순간만 기록한다. 전환 소요 시간을 여기서 읽는다. */
function track(key, value, label) {
  if (state.last[key] !== undefined && state.last[key] !== value) {
    logEvent(`${label}: ${state.last[key]}  ->  ${value}`);
  }
  state.last[key] = value;
}

/* ---------- 1. 경로 ---------- */
function renderPath(r) {
  const banner = $('#pathBanner');
  const kv = $('#pathKv');
  kv.replaceChildren();

  if (!r.ok) {
    banner.className = 'banner fail';
    banner.textContent = `경로 확인 실패 — HTTP ${r.status} ${JSON.stringify(r.body)}`;
    track('path', 'FAIL', '요청 경로');
    return;
  }
  const b = r.body;
  const cross = b.cross_dc === true;
  banner.className = 'banner ' + (cross ? 'warn' : 'ok');
  banner.textContent = cross
    ? `교차 경유 (degraded) — ${b.l4_dc} 의 L4 가 ${b.was_dc} 의 WAS 로 넘기고 있다. 사람이 WAS 를 고쳐야 한다.`
    : `로컬 경유 (정상) — ${b.l4_dc} L4 → ${b.was_dc} WAS`;
  track('path', cross ? 'CROSS' : 'LOCAL', '요청 경로');

  const fields = [
    ['client_ip',  b.client_ip,   '고객 IP. FortiADC 주소로 보이면 XFF 삽입 누락(R5)'],
    ['via_l4',     b.via_l4,      'SNAT 된 L4 주소 (C12)'],
    ['l4_dc',      b.l4_dc,       '경유한 L4 의 DC'],
    ['was_dc',     b.was_dc,      '처리한 WAS 의 DC'],
    ['was_host',   b.was_host,    'R3 / C13 판정'],
    ['web_host',   b.web_host,    '요청을 받은 nginx'],
    ['app_version', b.app_version, '카나리 배포 확인(8절)'],
    ['req_id',     b.req_id,      'nginx 로그와 이어 붙이는 키'],
  ];
  for (const [k, v, hint] of fields) {
    const item = el('div', 'item');
    item.appendChild(el('div', 'k', k));
    item.appendChild(el('div', 'v', v == null || v === '' ? '—' : String(v)));
    item.title = hint;
    kv.appendChild(item);
  }
}

/* ---------- 2. 계층 ---------- */
const LAYERS = [
  { id: 'web',   name: 'WEB (nginx)', url: '/health/web',
    desc: '1:1 구조에서 유일하게 흡수 주체가 없는 계층. 죽으면 GSLB 전환뿐이다.',
    detail: (b) => `${b.web_host || '?'} ${b.web_addr || ''}` },

  { id: 'deep',  name: '/health/deep', url: '/health/deep',
    desc: 'GSLB 가 보는 것. 실트래픽과 같은 경로(로컬 L4 VIP)를 탄다.',
    detail: (b) => b.status === 'ok'
      ? `writer=${b.writer_hostname} ro=${b.writer_read_only} ${b.writer_rtt_ms}ms`
      : `${b.reason || ''} ${b.error || ''}` },

  { id: 'local', name: '/health/local', url: '/health/local',
    desc: '알람 전용. GSLB 는 보지 않는다. 실패 = backup 으로 넘어가 있다.',
    detail: (b) => `${b.was_host || '?'} (${b.dc || '?'})` },

  { id: 'checkvs', name: '점검 VS (교차 멤버)', url: '/checkvs/api/info',
    desc: 'backup 멤버는 평시 트래픽 0 이라 검증되지 않는다. C13.',
    detail: (b) => `${b.was_host || '?'} / ${b.was_dc || '?'}` },

  { id: 'db',    name: 'DB writer', url: '/api/db/status',
    desc: 'semi-sync 가 OFF 면 RPO 가 깨진 채로 조용히 돌고 있는 것이다.',
    detail: (b) => b.writer
      ? `${b.writer.hostname} ro=${b.writer.read_only} semi=${b.semi_sync && b.semi_sync.Rpl_semi_sync_master_status || '?'}`
      : JSON.stringify(b).slice(0, 80),
    grade: (r) => !r.ok ? 'fail' : (r.body.rpo_zero ? 'ok' : 'warn') },

  { id: 'peer',  name: '반대편 DC', url: '/peer/health/deep',
    desc: 'GSLB 가 넘길 수 있는 곳이 살아 있는가. 죽어 있으면 전환 카드가 없다.',
    detail: (b) => b.status === 'ok'
      ? `${b.was_host} (${b.dc}) v${b.app_version}`
      : `${b.reason || b.error || 'fail'}` },
];

async function refreshLayers() {
  const box = $('#layers');
  const results = await Promise.all(LAYERS.map((L) => probe(L.url)));
  box.replaceChildren();

  let worst = 'ok';
  results.forEach((r, i) => {
    const L = LAYERS[i];
    let grade = L.grade ? L.grade(r) : (r.ok ? 'ok' : 'fail');
    if (grade === 'fail') worst = 'fail';
    else if (grade === 'warn' && worst !== 'fail') worst = 'warn';

    track(L.id, grade.toUpperCase() + '/' + r.status, L.name);

    const card = el('div', 'layer ' + grade);
    const name = el('div', 'name');
    name.appendChild(el('span', 'dot ' + grade));
    name.appendChild(el('span', null, L.name));
    const ms = el('span', 'ms', `${r.status || '-'} · ${r.ms}ms`);
    name.appendChild(ms);
    card.appendChild(name);
    card.appendChild(el('div', 'desc', L.desc));
    let det = '';
    try { det = L.detail(r.body || {}) || ''; } catch { det = ''; }
    card.appendChild(el('div', 'det', det));
    box.appendChild(card);
  });

  $('#overallDot').className = 'dot ' + worst;
}

/* ---------- 3. 분포 ---------- */
async function measureDistribution() {
  const n = Math.max(1, Math.min(500, +$('#distN').value || 30));
  const btn = $('#distBtn'); btn.disabled = true;
  const tbody = $('#distTable').querySelector('tbody');
  tbody.replaceChildren();
  $('#distResult').textContent = `${n}회 호출 중…`;

  const tally = {}, rows = [];
  for (let i = 0; i < n; i++) {
    const r = await probe('/api/info');
    const b = r.ok ? r.body : {};
    const host = r.ok ? (b.was_host || '?') : `ERR(${r.status})`;
    tally[host] = (tally[host] || 0) + 1;
    rows.push({ i: i + 1, host, was_dc: b.was_dc || '-', via_l4: b.via_l4 || '-',
                l4_dc: b.l4_dc || '-', ms: r.ms, cross: b.cross_dc === true });
  }

  const total = rows.length;
  const summary = Object.entries(tally)
    .sort((a, b) => b[1] - a[1])
    .map(([h, c]) => `${h}: ${c}건 (${(c / total * 100).toFixed(1)}%)`)
    .join('\n');
  const crossN = rows.filter((r) => r.cross).length;
  $('#distResult').textContent =
    summary + `\n교차 경유: ${crossN}/${total} (${(crossN / total * 100).toFixed(1)}%)` +
    (crossN === 0 ? '  ← 평시 정상' : '  ← degraded. /health/local 알람이 떠 있어야 한다');

  for (const r of rows.slice(-50)) {
    const tr = el('tr', r.cross ? 'cross' : null);
    for (const v of [r.i, r.host, r.was_dc, r.via_l4, r.l4_dc, r.ms]) tr.appendChild(el('td', null, String(v)));
    tbody.appendChild(tr);
  }
  $('#distTable').classList.add('show');
  btn.disabled = false;
  logEvent(`분포 측정 ${total}회 — 교차 ${crossN}건`);
}

/* ---------- 4. 지연 ---------- */
async function measureLatency() {
  const n = Math.max(1, Math.min(200, +$('#loadN').value || 10));
  const rep = Math.max(1, Math.min(100, +$('#loadRep').value || 10));
  const btn = $('#loadBtn'); btn.disabled = true;
  $('#loadResult').textContent = `N=${n} × ${rep}회 측정 중…`;

  const e2e = [], server = [];
  let dc = '?', host = '?';
  for (let i = 0; i < rep; i++) {
    const r = await probe(`/api/load?queries=${n}`);
    if (!r.ok) { $('#loadResult').textContent = `실패: HTTP ${r.status} ${JSON.stringify(r.body)}`; btn.disabled = false; return; }
    e2e.push(r.ms);
    server.push(r.body.total_ms);
    dc = r.body.dc; host = r.body.was_host;
  }
  const pct = (a, p) => { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.ceil(s.length * p) - 1)]; };
  const avg = (a) => (a.reduce((x, y) => x + y, 0) / a.length);

  $('#loadResult').textContent =
`처리: ${host} (${dc})   쿼리 N=${n}, ${rep}회

브라우저 → WEB → L4 → WAS → DB → 되돌아오기 (end-to-end)
  avg ${avg(e2e).toFixed(1)}ms   p50 ${pct(e2e, .5)}ms   p95 ${pct(e2e, .95)}ms   max ${Math.max(...e2e)}ms

WAS 안에서 DB 왕복만 (서버 측정)
  avg ${avg(server).toFixed(1)}ms   p50 ${pct(server, .5)}ms   p95 ${pct(server, .95)}ms

쿼리 1건당 ${(avg(server) / n).toFixed(2)}ms
  → 이 값이 DCI RTT 에 그대로 곱해진다. degraded 상태에서 다시 재서 증가폭을 볼 것.`;
  btn.disabled = false;
  logEvent(`지연 측정 N=${n}×${rep} — e2e p95 ${pct(e2e, .95)}ms / server p95 ${pct(server, .95)}ms`);
}

/* ---------- 5. 쓰기 ---------- */
async function doWrite() {
  const note = encodeURIComponent($('#writeNote').value || '');
  const r = await probe(`/api/db/write?note=${note}`, { method: 'POST' });
  const out = $('#writeResult');
  out.replaceChildren();
  if (r.ok) {
    out.appendChild(el('span', 'ok', `쓰기 성공 — id=${r.body.id}, ${r.body.elapsed_ms}ms, ${r.body.was_host} (${r.body.dc})`));
    logEvent(`쓰기 성공 id=${r.body.id} (${r.body.dc})`);
  } else {
    out.appendChild(el('span', 'fail',
      `쓰기 실패 — HTTP ${r.status}\n${JSON.stringify(r.body)}\n` +
      `※ DR 전환 1단계만 실행한 상태라면 이 실패가 정상이다.`));
    logEvent(`쓰기 실패 HTTP ${r.status}`);
  }
}

async function doRead() {
  const r = await probe('/api/db/read?limit=10');
  const tbody = $('#writeTable').querySelector('tbody');
  tbody.replaceChildren();
  if (!r.ok) { $('#writeResult').textContent = `읽기 실패 — HTTP ${r.status}`; return; }
  for (const row of r.body.rows) {
    const tr = el('tr');
    for (const v of [row.id, row.dc, row.was_host, row.note, row.created_at]) tr.appendChild(el('td', null, String(v ?? '')));
    tbody.appendChild(tr);
  }
  $('#writeTable').classList.add('show');
  $('#writeResult').textContent = `읽기 ${r.body.rows.length}건 — ${r.body.elapsed_ms}ms (${r.body.was_host})`;
}

/* ---------- 갱신 루프 ---------- */
async function refreshAll() {
  const [info] = await Promise.all([probe('/api/info'), refreshLayers()]);
  renderPath(info);
  $('#pageMeta').textContent = '마지막 갱신 ' + new Date().toLocaleTimeString();
}

function setAuto(on) {
  if (state.timer) { clearInterval(state.timer); state.timer = null; }
  if (on) state.timer = setInterval(refreshAll, 5000);
}

/* ---------- 바인딩 ---------- */
$('#refreshBtn').addEventListener('click', refreshAll);
$('#autoRefresh').addEventListener('change', (e) => setAuto(e.target.checked));
$('#distBtn').addEventListener('click', measureDistribution);
$('#loadBtn').addEventListener('click', measureLatency);
$('#writeBtn').addEventListener('click', doWrite);
$('#readBtn').addEventListener('click', doRead);
$('#clearLog').addEventListener('click', () => { $('#eventLog').textContent = ''; });

logEvent('검증 화면 시작');
refreshAll();
setAuto(true);
