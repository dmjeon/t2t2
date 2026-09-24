"""/l4test — 내부 L4 VIP 구성용 테스트 페이지 (AADC-POC.md 3-3절 / 5-1절).

네트워크 팀이 내부 L4 FortiADC 의 VIP 를 잡는 동안, **브라우저로 VIP 를 직접
열어** 지금 그 구성이 되는지 아닌지를 한 화면에서 보려고 만든 것이다.

  http://<L4 VIP>:8000/l4test        → 로컬 멤버(이 DC 의 WAS)가 받아야 정상
  http://<점검 VS VIP>:8000/l4test   → 반대편 DC 의 WAS 가 받아야 정상 (C13)

판정 근거는 /api/info 와 완전히 동일하다 — req.client.host 가 SNAT 된 L4
주소인가, WEB 주소인가. 같은 값을 사람이 읽는 모양으로 바꿔 놓았을 뿐이라
화면과 curl 결과가 어긋날 일이 없다.

★ 이 페이지는 nginx 를 거치지 않는다(WAS:8000 직결). 그래서 ADMIN_ALLOW /
  basic 인증이 걸리지 않는다. 내부 대역에서만 닿는 포트라 그렇게 두었지만,
  PoC 가 끝나면 8000 을 밖에 열어 둔 채로 남기지 말 것.
"""
import datetime as dt
import html
import json

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from ..config import settings
from ..tracing import trace

router = APIRouter(tags=["l4test"])


def _js(obj) -> str:
    """<script> 안에 박을 JSON.

    xff·web_host 는 **요청 헤더에서 온 값**이라 `</script>` 가 들어올 수 있다.
    그 한 줄이면 페이지가 거기서 끊기고 화면이 통째로 빈다. 꺾쇠를 유니코드
    이스케이프로 바꿔 둔다 — JSON 문법상 같은 문자열이라 값은 변하지 않는다.
    """
    return (json.dumps(obj, ensure_ascii=False)
            .replace("<", "\\u003c").replace(">", "\\u003e")
            .replace("&", "\\u0026"))


def _config_view() -> dict:
    """이 WAS 가 알고 있는 L4 구성. 화면에 "무엇을 때려야 하는가"를 띄운다."""
    return {
        "was_host": settings.node,
        "was_dc": settings.dc,
        "peer_dc": settings.peer_dc,
        "app_version": settings.app_version,
        # config.env 의 UPSTREAM_MODE. **기대값**이지 관측값이 아니다.
        "upstream_mode": settings.upstream_mode,
        "l4_vip": settings.l4_vip,
        "backup_member": settings.backup_member,
        "l4_port": settings.l4_port,
        "app_port": settings.app_port,
        "l4_prefix_dc500": settings.l4_prefix_dc500,
        "l4_prefix_dc400": settings.l4_prefix_dc400,
        "web_prefix_dc500": settings.web_prefix_dc500,
        "web_prefix_dc400": settings.web_prefix_dc400,
    }


@router.get("/l4test", response_class=HTMLResponse)
def l4test(request: Request):
    t = trace(request)
    t["server_time"] = dt.datetime.now(dt.timezone.utc).isoformat()
    return HTMLResponse(
        _PAGE
        .replace("__TRACE__", _js(t))
        .replace("__CONFIG__", _js(_config_view()))
        # JS 가 꺼져 있어도 판정 근거는 보여야 한다. <noscript> 안이라 JS 로는
        # 못 채운다 — 서버가 지금 찍어 넣는다.
        .replace("__TRACE_PRE__", html.escape(json.dumps(t, ensure_ascii=False, indent=2)))
    )


# 자산 파일을 따로 두지 않는다. 이 페이지는 L4 VIP 로 직접 열리므로 nginx 의
# /assets 를 못 탄다 — 한 파일 안에 전부 들어 있어야 어디서 열어도 같다.
_PAGE = r"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AADC PoC — 내부 L4 VIP 테스트</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin:0; font:15px/1.6 -apple-system,"Noto Sans KR",Segoe UI,Roboto,sans-serif;
         background:#f4f6f8; color:#1b2430; }
  header { background:#1b2430; color:#fff; padding:14px 20px; }
  header h1 { margin:0; font-size:17px; font-weight:600; }
  header .sub { font-size:12px; opacity:.72; margin-top:3px; }
  main { max-width:960px; margin:0 auto; padding:18px 16px 60px; }
  .verdict { border-radius:10px; padding:18px 20px; margin:0 0 18px; color:#fff; }
  .verdict .big { font-size:26px; font-weight:700; letter-spacing:-.4px; }
  .verdict .en  { font-size:13px; opacity:.85; margin-top:2px; }
  .verdict .why { font-size:13px; margin-top:10px; opacity:.95; }
  .v-l4      { background:#1f7a46; }
  .v-direct  { background:#b06a05; }
  .v-unknown { background:#8b2f2f; }
  .card { background:#fff; border:1px solid #dde3ea; border-radius:10px;
          padding:14px 18px; margin:0 0 14px; }
  .card h2 { margin:0 0 10px; font-size:14px; font-weight:700; color:#41505f;
             text-transform:uppercase; letter-spacing:.4px; }
  table { width:100%; border-collapse:collapse; }
  td { padding:6px 4px; border-bottom:1px solid #eef1f4; vertical-align:top; }
  td.k { width:200px; color:#5c6b7a; font-size:13px; }
  td.v { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px;
         word-break:break-all; }
  .hint { font-size:12px; color:#5c6b7a; margin:8px 0 0; }
  .urls a { display:block; font-family:ui-monospace,Menlo,monospace; font-size:13px;
            padding:7px 9px; margin:5px 0; background:#f4f6f8; border-radius:6px;
            border:1px solid #e2e7ec; color:#12507f; text-decoration:none; }
  .urls a:hover { background:#eaf1f7; }
  .urls .note { font-size:12px; color:#5c6b7a; font-family:inherit; }
  .bar { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin:0 0 14px; }
  button { font:inherit; padding:6px 13px; border-radius:6px; border:1px solid #c3ccd6;
           background:#fff; cursor:pointer; }
  button:hover { background:#f0f3f6; }
  label { font-size:13px; color:#41505f; }
  #spread td.v { font-variant-numeric:tabular-nums; }
  .warn { background:#fff6e5; border-color:#f0d6a0; }
  @media (prefers-color-scheme: dark) {
    body { background:#161b22; color:#e6edf3; }
    .card { background:#1c232c; border-color:#2c353f; }
    .card h2 { color:#9aa8b6; }
    td { border-bottom-color:#262e37; } td.k { color:#9aa8b6; }
    .urls a { background:#222a33; border-color:#2f3944; color:#79b8ff; }
    button { background:#222a33; border-color:#3a444f; color:#e6edf3; }
    .warn { background:#332a12; border-color:#5a4a1e; }
  }
</style>
</head>
<body>
<header>
  <h1>AADC PoC — 내부 L4 VIP 테스트 / internal L4 VIP test</h1>
  <div class="sub">이 페이지를 연 주소가 곧 시험 대상이다. VIP 로 열면 VIP 를, WAS 주소로 열면 직결을 본다.</div>
</header>
<main>

<div id="verdict" class="verdict v-unknown">
  <div class="big">확인 중…</div>
</div>

<div class="bar">
  <button id="refresh">지금 갱신 / refresh</button>
  <label><input type="checkbox" id="auto"> 3초 자동 갱신</label>
  <button id="spreadBtn">20회 연속 호출 — 멤버 분산 보기</button>
  <span id="url" class="hint"></span>
</div>

<div class="card">
  <h2>관측값 / observed</h2>
  <table id="obs"></table>
  <p class="hint">
    판정은 <b>앞 홉 주소</b> 하나로 한다. L4 가 Full NAT(SNAT) 이면 WAS 가 보는
    출발지는 L4 의 주소다. 그 주소가 <code id="pfx"></code> 로 시작하면 VIP 를 탔다는 뜻이다.
  </p>
</div>

<div class="card">
  <h2>때려야 할 주소 / what to test</h2>
  <div class="urls" id="urls"></div>
  <p class="hint">
    로컬 VIP 는 <b>이 DC 의 WAS</b> 가, 점검 VS 는 <b>반대편 DC 의 WAS</b> 가 받아야 정상이다
    (AADC-POC.md 3-3절 · C13). 받은 쪽이 바뀌어 있으면 멤버 구성이 반대다.
  </p>
</div>

<div class="card" id="spreadCard" style="display:none">
  <h2>멤버 분산 / member spread</h2>
  <table id="spread"></table>
  <p class="hint">한 멤버로만 몰리면 weight 또는 persistence(세션 고정) 설정을 볼 것.</p>
</div>

<div class="card">
  <h2>설정값 / configured</h2>
  <table id="cfg"></table>
  <p class="hint">
    <b>UPSTREAM_MODE</b> 는 WEB(nginx)이 어디로 보내도록 설치됐는지를 말한다.
    이 페이지를 VIP 로 직접 열었다면 그 값과 관측값은 달라도 이상한 것이 아니다 —
    위의 관측값이 지금 이 요청이 실제로 지나온 길이다.
  </p>
</div>

<noscript>
  <div class="card warn">
    <h2>JavaScript 없이 보는 값 / without JavaScript</h2>
    <p class="hint">서버가 이 요청을 받으며 그 자리에서 판정한 값이다. 갱신하려면 새로고침.</p>
    <pre>__TRACE_PRE__</pre>
  </div>
</noscript>
</main>

<script>
var CFG = __CONFIG__;
var BOOT = __TRACE__;

function esc(s){ return String(s===null||s===undefined?"-":s)
  .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }

function rows(el, pairs){
  document.getElementById(el).innerHTML = pairs.map(function(p){
    return "<tr><td class='k'>"+esc(p[0])+"</td><td class='v'>"+esc(p[1])+"</td></tr>";
  }).join("");
}

function render(t){
  var v = document.getElementById("verdict");
  var mode = t.path_mode;
  if (mode === "l4") {
    v.className = "verdict v-l4";
    v.innerHTML = "<div class='big'>VIP 경유 확인 &#10004;</div>"
      + "<div class='en'>Request came through the internal L4 VIP.</div>"
      + "<div class='why'>앞 홉 " + esc(t.via_l4) + " = " + esc(t.l4_dc)
      + " 의 L4. 받은 WAS = " + esc(t.was_host) + " (" + esc(t.was_dc) + ")."
      + (t.cross_dc ? " <b>교차 경유다 — backup 멤버가 흡수하고 있다.</b>" : "")
      + "</div>";
  } else if (mode === "direct") {
    v.className = "verdict v-direct";
    v.innerHTML = "<div class='big'>VIP 미경유 — WEB 직결</div>"
      + "<div class='en'>L4 is bypassed; the WEB tier called this WAS directly.</div>"
      + "<div class='why'>앞 홉 " + esc(t.via_l4) + " 는 " + esc(t.l4_dc)
      + " 의 WEB 주소다. VIP 로 열었는데 이 화면이 나오면 VIP 가 아직 트래픽을"
      + " 넘기지 않는 것이고, WAS 주소로 직접 열었다면 정상이다.</div>";
  } else {
    v.className = "verdict v-unknown";
    v.innerHTML = "<div class='big'>판정 불가 / unknown hop</div>"
      + "<div class='en'>The previous hop matches no known prefix.</div>"
      + "<div class='why'>앞 홉 " + esc(t.via_l4) + " 가 config.env 의 L4/WEB"
      + " 프리픽스 어디에도 없다. VIP 의 SNAT 풀 주소가 예상과 다르거나, 장비가"
      + " Full NAT 이 아니라 DNAT 만 하고 있을 수 있다.</div>";
  }

  rows("obs", [
    ["앞 홉 주소 / previous hop", t.via_l4],
    ["앞 홉 판정 / hop mode",     t.path_mode + (t.l4_bypassed ? "  (L4 bypassed)" : "")],
    ["앞 홉 DC / hop DC",         t.l4_dc],
    ["응답한 WAS / answered by",  t.was_host + "  (" + t.was_dc + ")"],
    ["교차 경유 / cross DC",      t.cross_dc ? "YES — backup 멤버 흡수 중" : "no"],
    ["고객 IP / client_ip",       t.client_ip],
    ["X-Forwarded-For",           t.xff || "(없음 / none)"],
    ["WEB 호스트 / web_host",     t.web_host],
    ["req_id",                    t.req_id],
    ["app_version",               t.app_version],
    ["서버 시각 / server time",   t.server_time]
  ]);

  document.getElementById("pfx").textContent =
    CFG.was_dc === "DC-500" ? CFG.l4_prefix_dc500 : CFG.l4_prefix_dc400;
}

function renderCfg(){
  rows("cfg", [
    ["UPSTREAM_MODE (WEB 설치값)", CFG.upstream_mode],
    ["이 DC / this DC",            CFG.was_dc],
    ["이 WAS / this WAS",          CFG.was_host],
    ["로컬 L4 VIP",                CFG.l4_vip + ":" + CFG.l4_port],
    ["backup 멤버 / backup member", CFG.backup_member + ":" + CFG.app_port],
    ["WAS 포트 / app port",        CFG.app_port],
    ["L4 프리픽스 DC-500",         CFG.l4_prefix_dc500],
    ["L4 프리픽스 DC-400",         CFG.l4_prefix_dc400],
    ["WEB 프리픽스 DC-500",        CFG.web_prefix_dc500],
    ["WEB 프리픽스 DC-400",        CFG.web_prefix_dc400]
  ]);

  var u = [
    [CFG.l4_vip + ":" + CFG.l4_port, "로컬 L4 VIP — " + CFG.was_dc + " 의 WAS 가 받아야 정상"],
    [CFG.backup_member + ":" + CFG.app_port, "backup 멤버 직접 — " + CFG.peer_dc + " 의 WAS 가 받아야 정상 (C13, L4 미경유)"]
  ];
  document.getElementById("urls").innerHTML = u.map(function(x){
    var href = "http://" + x[0] + "/l4test";
    return "<a href='" + esc(href) + "'>" + esc(href)
         + "<span class='note'><br>" + esc(x[1]) + "</span></a>";
  }).join("");
  document.getElementById("url").textContent = "지금 이 창: " + location.origin + location.pathname;
}

function load(){
  fetch("/api/info", {cache:"no-store"})
    .then(function(r){ return r.json(); })
    .then(render)
    .catch(function(e){
      document.getElementById("verdict").className = "verdict v-unknown";
      document.getElementById("verdict").innerHTML =
        "<div class='big'>갱신 실패</div><div class='en'>" + esc(e) + "</div>";
    });
}

/* 멤버 분산: 같은 주소로 연달아 호출해 어느 WAS 가 몇 번 받았는지 센다.
   persistence(세션 고정)가 걸려 있으면 한 쪽으로만 몰리므로 바로 보인다. */
function spread(){
  var n = 20, seen = {}, hops = {}, done = 0;
  document.getElementById("spreadCard").style.display = "";
  document.getElementById("spread").innerHTML = "<tr><td class='k'>진행</td><td class='v'>0/" + n + "</td></tr>";
  function one(){
    fetch("/api/info", {cache:"no-store"})
      .then(function(r){ return r.json(); })
      .then(function(t){
        seen[t.was_host] = (seen[t.was_host]||0) + 1;
        hops[t.via_l4]   = (hops[t.via_l4]||0) + 1;
      })
      .catch(function(){ seen["(실패)"] = (seen["(실패)"]||0) + 1; })
      .then(function(){
        if (++done < n) { one(); return; }
        var out = [];
        Object.keys(seen).forEach(function(k){ out.push(["WAS  " + k, seen[k] + " / " + n]); });
        Object.keys(hops).forEach(function(k){ out.push(["앞 홉  " + k, hops[k] + " / " + n]); });
        rows("spread", out);
      });
  }
  one();
}

var timer = null;
document.getElementById("refresh").onclick = load;
document.getElementById("spreadBtn").onclick = spread;
document.getElementById("auto").onchange = function(){
  if (timer) { clearInterval(timer); timer = null; }
  if (this.checked) timer = setInterval(load, 3000);
};

renderCfg();
render(BOOT);   /* 서버가 방금 판정한 값. fetch 가 막혀도 한 번은 보인다 */
load();
</script>
</body>
</html>
"""
