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
    try {
      body = await res.json();
    } catch {
      // JSON 이 아니면 대개 nginx 가 만든 에러 페이지다. 통째로 들고 다니면
      // 배너가 HTML 로 도배되므로 요약만 남긴다.
      const txt = await res.text().catch(() => '');
      body = /^\s*</.test(txt)
        ? { raw: '(HTML error page)', bytes: txt.length }
        : { raw: txt.slice(0, 200) };
    }
    if (body === null || typeof body !== 'object') body = { value: body };
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
    // 상태 코드가 곧 어느 계층이 끊겼는지를 말해 준다. 그래서 그대로 보여 준다.
    const hint = {
      502: '로컬 L4 VIP 에 닿지 못했다. L4 미기동 / VIP 주소 오기입 / SELinux 순으로 볼 것.',
      504: 'L4 는 응답했으나 WAS 가 시간 안에 답하지 않았다.',
      403: '접근 제어에 막혔다. ADMIN_ALLOW 에 없고 basic 인증도 안 된 상태다.',
      404: '경로가 없다. nginx location 설정을 볼 것.',
      0:   '네트워크 또는 CORS 문제로 요청 자체가 실패했다.',
    }[r.status] || '';
    banner.textContent =
      `경로 확인 실패 — HTTP ${r.status}${hint ? '  ·  ' + hint : ''}`;
    track('path', 'FAIL/' + r.status, '요청 경로');
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
    detail: (b) => `${b.web_host || '?'} ${b.web_addr || ''}`
                 + (b.upstream_mode ? `  ->  ${b.upstream_target || '?'} (${b.upstream_mode})` : ''),
    after: (b) => showBypass(b) },

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
    detail: (b) => {
      if (!b || !b.writer) return JSON.stringify(b || {}).slice(0, 80);
      if (b.temporary_backend) return `sqlite  ${b.db_target || ''}  (임시 · 공유 DB 아님)`;
      const semi = (b.semi_sync && b.semi_sync.Rpl_semi_sync_master_status) || '?';
      return `${b.writer.hostname} ro=${b.writer.read_only} semi=${semi}`;
    },
    // sqlite 는 항상 warn 이다. 초록으로 두면 "DB 계층이 검증됐다"로 읽힌다.
    grade: (r) => {
      if (!r.ok) return 'fail';
      if (r.body && r.body.temporary_backend) return 'warn';
      return (r.body && r.body.rpo_zero) ? 'ok' : 'warn';
    },
    after: (b) => showSqlite(b) },

  { id: 'peer',  name: '반대편 DC', url: '/peer/health/deep',
    desc: 'GSLB 가 넘길 수 있는 곳이 살아 있는가. 죽어 있으면 전환 카드가 없다.',
    detail: (b) => b.status === 'ok'
      ? `${b.was_host} (${b.dc}) v${b.app_version}`
      : `${b.reason || b.error || 'fail'}` },
];

/* 카드 하나를 그린다. 여기서 던지는 예외는 호출자가 잡아 카드 하나만 망가뜨린다.
 *
 * 이 함수가 분리돼 있는 이유: 예전 구현은 6개를 한 루프에서 그려서, 두 번째
 * 카드에서 예외가 나면 나머지 4개가 통째로 사라졌다. 화면에는 첫 카드만 남고
 * 아무 설명도 없었다. 진단 화면에서 그건 최악의 실패 방식이다 —
 * "무엇이 고장났는지" 대신 "화면이 고장났다"를 보게 된다. */
function renderLayerCard(L, r) {
  const grade = L.grade ? L.grade(r) : (r.ok ? 'ok' : 'fail');

  const card = el('div', 'layer ' + grade);
  const name = el('div', 'name');
  name.appendChild(el('span', 'dot ' + grade));
  name.appendChild(el('span', null, L.name));
  name.appendChild(el('span', 'ms', `${r.status || '-'} · ${r.ms}ms`));
  card.appendChild(name);
  card.appendChild(el('div', 'desc', L.desc));

  let det = '';
  try { det = L.detail(r.body || {}) || ''; } catch (e) { det = `detail error: ${e.message}`; }
  card.appendChild(el('div', 'det', det));

  // 카드가 자기 말고 다른 것도 갱신해야 할 때 (예: L4 우회 배너)
  if (L.after) { try { L.after(r.body || {}); } catch (e) { /* 카드는 그대로 둔다 */ } }

  return { card, grade };
}

/* L4 우회 배너. /health/web 이 upstream_mode 를 알려 준다.
 * 우회 상태를 화면 맨 위에 계속 띄워 두는 것이 목적이다 —
 * 임시 구성은 잊히고, 잊힌 임시 구성은 본설계로 둔갑한다. */
function showBypass(b) {
  const card = $('#bypassCard');
  if (!card) return;
  if (b && b.upstream_mode === 'direct') {
    card.style.display = '';
    $('#bypassBanner').textContent =
      `WEB → ${b.upstream_target || '?'} (로컬 WAS 직결). 내부 L4 를 거치지 않는다.`;
    track('upstream', 'direct', '업스트림 모드');
  } else {
    card.style.display = 'none';
    if (b && b.upstream_mode) track('upstream', b.upstream_mode, '업스트림 모드');
  }
}

/* SQLite 임시 백엔드 배너. L4 우회와 같은 이유로 화면 위에 계속 띄운다. */
function showSqlite(b) {
  const card = $('#sqliteCard');
  if (!card) return;
  if (b && b.temporary_backend) {
    card.style.display = '';
    $('#sqliteBanner').textContent =
      `${b.db_target || 'local file'} — WAS 로컬 SQLite. DB 서버·VIP·복제가 존재하지 않는다.`;
    track('dbmode', 'sqlite', 'DB 백엔드');
  } else {
    card.style.display = 'none';
    if (b && b.backend) track('dbmode', b.backend, 'DB 백엔드');
  }
}

function renderBrokenCard(L, err) {
  const card = el('div', 'layer fail');
  const name = el('div', 'name');
  name.appendChild(el('span', 'dot fail'));
  name.appendChild(el('span', null, L.name));
  name.appendChild(el('span', 'ms', 'render error'));
  card.appendChild(name);
  card.appendChild(el('div', 'desc', L.desc));
  card.appendChild(el('div', 'det', `${err && err.name}: ${err && err.message}`));
  return card;
}

async function refreshLayers() {
  const box = $('#layers');
  const results = await Promise.all(LAYERS.map((L) => probe(L.url)));
  box.replaceChildren();

  // 경로도가 같은 응답을 쓴다. 그림이 자기 요청을 따로 내면 카드와 다른
  // 순간을 보게 되고, 둘이 어긋나는 순간 진단 화면으로서 값이 없어진다.
  const byId = {};
  let worst = 'ok';
  for (let i = 0; i < LAYERS.length; i++) {
    const L = LAYERS[i];
    const r = results[i];
    try {
      const { card, grade } = renderLayerCard(L, r);
      if (grade === 'fail') worst = 'fail';
      else if (grade === 'warn' && worst !== 'fail') worst = 'warn';
      track(L.id, String(grade).toUpperCase() + '/' + r.status, L.name);
      byId[L.id] = r;
      box.appendChild(card);
    } catch (e) {
      // 카드 하나가 깨져도 나머지는 계속 그린다.
      worst = 'fail';
      box.appendChild(renderBrokenCard(L, e));
      logEvent(`카드 렌더 실패 [${L.id}] ${e && e.name}: ${e && e.message}`);
    }
  }

  $('#overallDot').className = 'dot ' + worst;
  return byId;
}

/* ---------- 0. 활성 경로도 ---------- */
/* 켤 홉을 고르는 규칙은 세 값이 전부다.
 *   web_addr       — 이 화면을 내려준 WEB 이 어느 DC 인가        (좌/우)
 *   upstream_mode  — VIP 경로(l4)인가 다이렉트(direct)인가        (가운데 갈래)
 *   was_dc         — 실제로 처리한 WAS 가 어느 DC 인가            (교차 여부)
 * 나머지는 라벨이다. 규칙을 늘리지 말 것 — 늘리는 순간 그림과 카드가 갈린다. */
const MAP_IDS = {
  left:  { gslb: 'n-gslb1', fg: 'n-fg1', web: 'n-web1', l4: 'n-l4vip1', fadc: 'n-fadc1a', was: 'n-was1',
           eIn: 'e-inet-gslb1', eGf: 'e-gslb1-fg1', eFw: 'e-fg1-web1',
           eWl: 'e-web1-l4', eLw: 'e-l4-was1', eDirect: 'e-web1-direct',
           eFadc: 'e-fadc1a-vip', eCross: 'e-l4a-was2', eDb: 'e-was1-db' },
  right: { gslb: 'n-gslb2', fg: 'n-fg2', web: 'n-web2', l4: 'n-l4vip2', fadc: 'n-fadc2a', was: 'n-was2',
           eIn: 'e-inet-gslb2', eGf: 'e-gslb2-fg2', eFw: 'e-fg2-web2',
           eWl: 'e-web2-l4', eLw: 'e-l4-was2', eDirect: 'e-web2-direct',
           eFadc: 'e-fadc2a-vip', eCross: 'e-l4b-was1', eDb: 'e-was2-db' },
};

function mapText(id, txt, warn) {
  const t = document.getElementById(id);
  if (!t) return;
  t.textContent = txt == null || txt === '' ? '—' : String(txt);
  if (warn !== undefined) t.classList.toggle('warn', !!warn);
}

function renderPathMap(infoR, layers) {
  const svg = $('#pathMap');
  if (!svg) return;

  const web  = (layers.web && layers.web.ok) ? (layers.web.body || {}) : null;
  const info = (infoR && infoR.ok) ? (infoR.body || {}) : null;
  const db   = (layers.db && layers.db.ok) ? (layers.db.body || {}) : null;

  const addr = (web && web.web_addr) || '';
  const dc = addr.startsWith('10.7.') ? 'DC-400'
           : addr.startsWith('10.3.') ? 'DC-500'
           : (info && info.l4_dc) || 'DC-500';
  const left   = dc !== 'DC-400';
  const me     = left ? MAP_IDS.left : MAP_IDS.right;
  const other  = left ? MAP_IDS.right : MAP_IDS.left;
  const direct = !!((web && web.upstream_mode === 'direct') || (info && info.path_mode === 'direct'));
  const wasDc  = (info && info.was_dc) || dc;
  const cross  = !!(info && info.cross_dc === true) || wasDc !== dc;

  const on  = ['n-inet', me.eIn, me.gslb, me.eGf, me.fg, me.eFw, me.web];
  const hot = [];
  const steps = [left ? 'WEB-DC1' : 'WEB-DC2'];

  if (!info) {
    // WAS 응답이 없다. WEB 까지만 켜고 거기서 끊어 보여 준다.
    hot.push(me.web);
    steps.push('WAS 응답 없음');
  } else {
    if (direct) {
      on.push(me.eDirect, cross ? other.was : me.was);
      hot.push(cross ? other.was : me.was);
      steps.push('다이렉트(L4 우회)');
    } else {
      on.push(me.eWl, me.l4, me.eFadc, me.fadc);
      steps.push('L4 VIP ' + ((web && web.upstream_target) || '?'));
      if (cross) { on.push(me.eCross, other.was); hot.push(other.was); }
      else       { on.push(me.eLw, me.was); }
    }
    steps.push((info.was_host || 'WAS') + ' / ' + wasDc);

    const wasLeft = wasDc !== 'DC-400';
    on.push(wasLeft ? MAP_IDS.left.eDb : MAP_IDS.right.eDb, 'n-dbvip', 'e-vip-writer', 'n-writer');
    if (!db || db.temporary_backend) hot.push('n-dbvip', 'n-writer');
    steps.push('DB ' + ((db && db.db_target) || '?'));
  }

  svg.querySelectorAll('g.n, g.e-g').forEach((g) => g.classList.remove('on', 'hot'));
  on.forEach((id)  => { const g = document.getElementById(id); if (g) g.classList.add('on'); });
  hot.forEach((id) => { const g = document.getElementById(id); if (g) g.classList.add('hot'); });

  /* 살아 있는 값으로 라벨을 바꾼다. 고정 문구를 두면 실제와 다른 주소를
   * 읽고 그대로 믿게 된다. */
  mapText('t-web1', left && addr ? addr : '10.3.11.51');
  mapText('t-web2', !left && addr ? addr : '10.7.11.52');
  const vipTxt = (web && web.upstream_target) ? String(web.upstream_target).split(':')[0] : null;
  mapText('t-l4vip1', (left && !direct && vipTxt) ? vipTxt : '10.3.20.x · 미회신', !(left && !direct && vipTxt));
  mapText('t-l4vip2', (!left && !direct && vipTxt) ? vipTxt : '10.7.20.x · 미회신', !(!left && !direct && vipTxt));
  if (info && info.was_host) mapText(wasDc === 'DC-400' ? 't-was2' : 't-was1', info.was_host);
  mapText('t-dbtarget', db ? (db.db_target || '?') + (db.temporary_backend ? ' · 임시' : ' · VIP') : '—', !db || !!db.temporary_backend);
  mapText('t-writer', (db && db.writer && db.writer.hostname) || 'DB writer');
  mapText('t-writer-sub',
    !db ? '응답 없음'
        : db.backend === 'sqlite' ? 'sqlite — 공유 DB 아님'
        : Number(db.writer && db.writer.read_only) !== 0 ? 'read_only — 쓰기 불가'
        : 'rw · semi=' + ((db.semi_sync && db.semi_sync.Rpl_semi_sync_master_status) || '?'),
    !db || db.backend === 'sqlite' || Number(db.writer && db.writer.read_only) !== 0);

  const legend = $('#mapLegend');
  const notes = [];
  if (direct) notes.push('L4 우회 — Full NAT·backup 흡수·L4 장애 감지가 미검증이다');
  if (cross)  notes.push('교차 경유 — 본문과 쿼리가 전부 DCI 를 건넌다');
  if (db && db.temporary_backend) notes.push('DB 가 임시 SQLite — 공유 DB 가 아니다');
  if (db && db.backend === 'mariadb' && !db.rpo_zero) notes.push('semi-sync 강등 — RPO 0 이 아니다');
  if (web && !web.xff) notes.push('XFF 없음 — 고객 IP 가 앞단에서 소실됐다');

  legend.className = 'banner ' + (!info ? 'fail' : (notes.length ? 'warn' : 'ok'));
  legend.textContent = steps.join('  →  ') + (notes.length ? '   ·   ' + notes.join(' / ') : '');
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
  const [info, layers] = await Promise.all([probe('/api/info'), refreshLayers()]);
  renderPath(info);
  // 경로도가 깨져도 나머지 화면은 살려 둔다.
  try { renderPathMap(info, layers || {}); }
  catch (e) { logEvent(`경로도 렌더 실패: ${e && e.message}`); }
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

/* 조용히 죽지 않게 한다. 진단 화면이 아무 말 없이 멈추는 것이 최악이다. */
window.addEventListener('error', (e) => {
  logEvent(`JS 오류: ${e.message}  (${e.filename}:${e.lineno})`);
});
window.addEventListener('unhandledrejection', (e) => {
  const r = e.reason;
  logEvent(`처리되지 않은 오류: ${(r && (r.stack || r.message)) || r}`);
});

logEvent('검증 화면 시작');
refreshAll().catch((e) => logEvent(`refreshAll 실패: ${e && e.message}`));
setAuto(true);
