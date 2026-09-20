#!/usr/bin/env bash
# =============================================================================
# 내부 L4 VIP 탐색 — AADC-POC.md 13-2절 회신 대기 4번을 스캔으로 대신 확인한다
#
#   실행 위치: ★ WEB-DC1 (10.3.11.51) 또는 WEB-DC2 (10.7.11.52) ★
#
#   FW-09/10 은 **WEB → 로컬 L4 VIP:8000** 만 허용한다. 점프서버(FW-16)는
#   "미적용 — 확인됨"이고 WAS 는 L4 의 목적지이지 출발지가 아니다. 다른 곳에서
#   돌리면 대역 전체가 filtered 로 나오는데, 그건 VIP 가 없다는 뜻이 아니라
#   **스캔을 틀린 자리에서 했다는 뜻**이다. 그래서 아래에서 위치를 먼저 막는다.
#
# 이 스캔의 값어치는 "찾았다"가 아니라 **못 찾았을 때 왜 못 찾았는지**에 있다.
#   open      : 8000 이 열려 있다 → 후보. /api/info 로 정체를 확인한다
#   refused   : RST 가 돌아왔다  → **경로는 뚫려 있고** 그 주소에 리슨이 없다
#   filtered  : 무응답(타임아웃) → 방화벽 drop. 도달 자체가 안 된다
#
#   refused 가 하나라도 있으면 FW-09 가 대역으로 열려 있다는 증거다. 그런데도
#   open 이 0 이면 결론은 "VIP 를 못 찾았다"가 아니라 **"가상 서버가 아직
#   안 만들어졌다"** 이다. 전부 filtered 면 반대로 규칙이 단일 목적지로만
#   적용됐거나 미적용이라는 뜻이고, 그때는 스캔으로는 절대 못 찾는다.
#   이 둘을 섞으면 Viettel 에 틀린 질문을 하게 된다.
#
# 사용법
#   ./90-scan-l4-vip.sh                    # 이 호스트의 DC 로 대역 자동 결정
#   ./90-scan-l4-vip.sh 10.3.20.0/24       # 대역 지정
#   ./90-scan-l4-vip.sh 10.3.20.0/24 8000  # 포트까지 지정
#
# 환경변수
#   SCAN_TIMEOUT=1   연결 타임아웃(초). 늘리면 느려지고 filtered 오판은 준다
#   SCAN_PAR=32      동시 프로브 수
#   SCAN_FROM=1      시작 호스트 옥텟
#   SCAN_TO=253      끝 호스트 옥텟 (.254 게이트웨이는 기본 제외)
#   SCAN_PING=1      ICMP 스윕도 같이 (보조 신호. FW-17 밖이라 무응답이 정상)
#   SCAN_FORCE=1     실행 위치 검사를 무시한다
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${AADC_CONF:-${HERE}/../config.env}"
if [ ! -f "${CONF}" ]; then
  echo "config.env 가 없다. cp config.env.example config.env 후 값을 채울 것." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${CONF}"

[ -n "${BASH_VERSION:-}" ] || { echo "ERROR: sh 말고 bash 로 실행할 것"; exit 2; }
command -v timeout >/dev/null 2>&1 || {
  echo "ERROR: timeout(coreutils) 이 없다. 이게 없으면 filtered 와 refused 를"
  echo "       구분할 수 없고, 그 구분이 이 스크립트의 전부다."; exit 2; }

C_OK=$'\033[32m'; C_NG=$'\033[31m'; C_SK=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_NG=""; C_SK=""; C_B=""; C_0=""; }
hdr()  { printf '\n%s== %s ==%s\n' "${C_B}" "$*" "${C_0}"; }
note() { printf '   %s\n' "$*"; }

SCAN_TIMEOUT="${SCAN_TIMEOUT:-1}"
SCAN_PAR="${SCAN_PAR:-32}"
SCAN_FROM="${SCAN_FROM:-1}"
SCAN_TO="${SCAN_TO:-253}"
SCAN_PING="${SCAN_PING:-0}"
SCAN_FORCE="${SCAN_FORCE:-0}"

host_ips() {
  (ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}') \
    || hostname -I 2>/dev/null | tr ' ' '\n'
}

# ----- 대역·포트 결정 --------------------------------------------------------
# 인자가 없으면 이 호스트가 어느 WEB 인지 보고 **로컬** 대역을 고른다.
# 교차 대역(WEB-DC1 에서 10.7.20.x)은 일부러 기본값에 두지 않는다 — FW-09 는
# 로컬 L4 만 허용하므로 결과가 전부 filtered 로 나와 판정만 흐려진다.
CIDR="${1:-}"; PORT="${2:-${L4_PORT:-8000}}"
WHERE="unknown"
for ip in $(host_ips); do
  case "${ip}" in
    "${WEB_DC1_IP}") WHERE="WEB-DC1"; [ -n "${CIDR}" ] || CIDR="${L4_PREFIX_DC500}0/24" ;;
    "${WEB_DC2_IP}") WHERE="WEB-DC2"; [ -n "${CIDR}" ] || CIDR="${L4_PREFIX_DC400}0/24" ;;
    "${WAS_DC500_IP}"|"${WAS_DC400_IP}") WHERE="WAS" ;;
  esac
done

if [ "${WHERE}" != "WEB-DC1" ] && [ "${WHERE}" != "WEB-DC2" ]; then
  printf '\n%s실행 위치가 WEB 서버가 아니다 (감지: %s)%s\n' "${C_NG}" "${WHERE}" "${C_0}"
  cat <<'WRONGPLACE'

   FW-09/10 은 WEB → 로컬 L4 VIP:8000 만 허용한다. 여기서 돌리면 대역 전체가
   filtered 로 나오고, 그건 "VIP 가 없다"가 아니라 "여기선 원래 안 보인다"는
   뜻이다. 그 결과로 Viettel 에 "대역이 안 열렸다"고 회신하면 틀린 말이 된다.

   WEB-DC1 (10.3.11.51) 또는 WEB-DC2 (10.7.11.52) 에서 돌릴 것.
   현재 접속 수단이 포털 VM 콘솔뿐이면 콘솔에서 돌려야 한다 (AADC-POC.md 14절).

   그래도 돌리려면:  SCAN_FORCE=1 ./verify/90-scan-l4-vip.sh <대역>
WRONGPLACE
  [ "${SCAN_FORCE}" = "1" ] || exit 2
  printf '\n%sSCAN_FORCE=1 — 위치 검사를 무시하고 진행한다. 판정을 믿지 말 것.%s\n' "${C_SK}" "${C_0}"
  [ -n "${CIDR}" ] || { echo "대역을 인자로 줄 것: ./90-scan-l4-vip.sh 10.3.20.0/24"; exit 2; }
fi

case "${CIDR}" in
  */24) PREFIX="${CIDR%0/24}" ;;
  *)    echo "ERROR: /24 대역만 받는다. 예: 10.3.20.0/24"; exit 2 ;;
esac

# ----- 이미 알고 있는 주소 ---------------------------------------------------
# 이 주소들이 스캔에 걸려도 VIP 가 아니다. FW-11 의 **출발지**이거나 게이트웨이다.
# 라벨을 붙여 두지 않으면 .231 을 VIP 로 착각해서 nginx proxy_pass 에 박게 된다.
label_of() {
  case "$1" in
    "${PREFIX}231") echo "internal-fortiadc-01 관리 IP (VIP 아님, FW-11 출발지)" ;;
    "${PREFIX}232") echo "internal-fortiadc-02 관리 IP (VIP 아님, 만료·정지 상태)" ;;
    "${PREFIX}254") echo "세그먼트 게이트웨이 (VIP 아님)" ;;
    "${DC500_L4_VIP}"|"${DC400_L4_VIP}")         echo "config.env 의 <<TBD>> 더미값" ;;
    "${DC500_CHECK_VS_VIP}"|"${DC400_CHECK_VS_VIP}") echo "config.env 의 <<TBD>> 더미값 (점검 VS)" ;;
    *) echo "" ;;
  esac
}

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ----- 프로브 ---------------------------------------------------------------
# bash 의 /dev/tcp 로 connect 만 해본다. 서버에 nmap 이 없고 dnf 도 막혀 있어서
# (14절 블로커 0-a) 외부 도구를 전제할 수 없다.
#
#   rc=0    연결됨            → open
#   rc=124  timeout 이 죽임   → filtered (drop)
#   그 외   즉시 실패         → stderr 문구로 refused / unreachable 구분
probe() {
  local ip="$1" err rc
  err="$(timeout "${SCAN_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${ip}/${PORT}" 2>&1)"; rc=$?
  if   [ "${rc}" -eq 0 ];   then echo "open"     > "${TMP}/${ip}"
  elif [ "${rc}" -eq 124 ]; then echo "filtered" > "${TMP}/${ip}"
  else
    case "${err}" in
      *"refused"*|*"거부"*)        echo "refused"     > "${TMP}/${ip}" ;;
      *"No route"*|*"unreachable"*|*"루트"*) echo "unreachable" > "${TMP}/${ip}" ;;
      *)                           echo "filtered"    > "${TMP}/${ip}" ;;
    esac
  fi
}

hdr "스캔 ${PREFIX}${SCAN_FROM}~${PREFIX}${SCAN_TO} : ${PORT}/tcp"
note "실행 위치   ${WHERE}  ($(host_ips | tr '\n' ' '))"
note "타임아웃    ${SCAN_TIMEOUT}s / 동시 ${SCAN_PAR}"
note ""

n=0
for i in $(seq "${SCAN_FROM}" "${SCAN_TO}"); do
  probe "${PREFIX}${i}" &
  n=$((n+1))
  if [ "$((n % SCAN_PAR))" -eq 0 ]; then wait; printf '.'; fi
done
wait; printf '.\n'

# ----- 집계 -----------------------------------------------------------------
OPEN=(); REFUSED=(); UNREACH=(); n_filtered=0
for i in $(seq "${SCAN_FROM}" "${SCAN_TO}"); do
  ip="${PREFIX}${i}"; st="$(cat "${TMP}/${ip}" 2>/dev/null || echo filtered)"
  case "${st}" in
    open)        OPEN+=("${ip}") ;;
    refused)     REFUSED+=("${ip}") ;;
    unreachable) UNREACH+=("${ip}") ;;
    *)           n_filtered=$((n_filtered+1)) ;;
  esac
done

hdr "결과"
printf '   %sopen%s        %d\n' "${C_OK}" "${C_0}" "${#OPEN[@]}"
printf '   refused     %d   (경로는 열려 있고 리슨이 없다)\n' "${#REFUSED[@]}"
printf '   unreachable %d\n' "${#UNREACH[@]}"
printf '   filtered    %d   (무응답)\n' "${n_filtered}"

if [ "${#REFUSED[@]}" -gt 0 ]; then
  note ""
  note "RST 가 돌아온 주소 (방화벽이 이 대역을 통과시킨다는 증거):"
  printf '      %s\n' "${REFUSED[@]}" | head -20
  [ "${#REFUSED[@]}" -gt 20 ] && note "      ... 외 $(( ${#REFUSED[@]} - 20 ))개"
fi

# ----- open 포트의 정체 확인 -------------------------------------------------
# 8000 이 열렸다고 곧장 VIP 가 아니다. 우리 앱이 응답하는지까지 봐야 한다.
jqv() { printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" | head -1; }
FOUND=()
if [ "${#OPEN[@]}" -gt 0 ]; then
  hdr "open 포트 정체 확인  /api/info"
  for ip in "${OPEN[@]}"; do
    lbl="$(label_of "${ip}")"
    body="$(curl -sf --max-time 5 "http://${ip}:${PORT}/api/info" 2>/dev/null)"
    if [ -z "${body}" ]; then
      printf '   %s%-16s%s 8000 은 열렸으나 /api/info 무응답 — 우리 앱이 아니다  %s\n' \
             "${C_SK}" "${ip}" "${C_0}" "${lbl}"
      continue
    fi
    wh="$(jqv "${body}" was_host)"; vl="$(jqv "${body}" via_l4)"; wd="$(jqv "${body}" was_dc)"
    printf '   %s%-16s%s was_host=%s  was_dc=%s  via_l4=%s\n' \
           "${C_OK}" "${ip}" "${C_0}" "${wh:-?}" "${wd:-?}" "${vl:-?}"
    [ -n "${lbl}" ] && note "                 ※ ${lbl}"
    FOUND+=("${ip}")
    # via_l4 가 이 대역이면 Full NAT 가 걸린 진짜 L4 경유다 (C12 와 같은 근거).
    case "${vl}" in
      "${PREFIX}"*) note "                 via_l4 가 L4 대역 — Full NAT 경유 확인" ;;
      "") ;;
      *)  note "                 ${C_SK}via_l4=${vl} 가 L4 대역이 아니다. WAS 직결일 수 있다${C_0}" ;;
    esac
  done
fi

# ----- ICMP 보조 스윕 --------------------------------------------------------
if [ "${SCAN_PING}" = "1" ]; then
  hdr "ICMP 스윕 (보조 신호)"
  note "FW-17 은 '위 서버들 상호간' ICMP 다. VIP 는 그 목록에 없으므로"
  note "무응답이 정상이고, 응답이 오면 그건 추가 정보일 뿐 판정 근거가 아니다."
  for i in $(seq "${SCAN_FROM}" "${SCAN_TO}"); do
    ip="${PREFIX}${i}"
    ping -c1 -W1 "${ip}" >/dev/null 2>&1 && printf '   응답 %s  %s\n' "${ip}" "$(label_of "${ip}")"
  done
fi

# ----- 판정 -----------------------------------------------------------------
# 여기가 이 스크립트의 목적이다. 같은 "못 찾음"이라도 Viettel 에 할 질문이 다르다.
hdr "판정"
if [ "${#FOUND[@]}" -gt 0 ]; then
  printf '   %s후보 %d개.%s\n\n' "${C_OK}" "${#FOUND[@]}" "${C_0}"
  printf '      %s\n' "${FOUND[@]}"
  cat <<JUDGE

   was_host 가 WAS-APP1 / WAS-APP-500 이면 그것이 실서비스 VIP 다.
   2개가 나왔다면 하나는 교차 멤버만 담은 **점검 전용 VS** 일 가능성이 높다
   (AADC-POC.md 3-3절). was_dc 가 DC-400 으로 나오는 쪽이 점검 VS 다.

   config.env 에 반영하고 30-web.sh 를 다시 돌린다:
JUDGE
  note ""
  VAR="DC500_L4_VIP"; [ "${WHERE}" = "WEB-DC2" ] && VAR="DC400_L4_VIP"
  note "      ${VAR}=\"${FOUND[0]}\"        # <<TBD>> 제거"
  note "      UPSTREAM_MODE=\"l4\"                # direct 에서 되돌린다"
  note "      ./install/30-web.sh"
  note ""
  note "   그 다음 ./verify/02-path-r1-r6.sh 로 R3/C12/C13 을 확인한다."
elif [ "${#OPEN[@]}" -gt 0 ]; then
  printf '   %s%s 를 리슨하는 주소는 있는데 /api/info 가 안 온다.%s\n' "${C_SK}" "${PORT}" "${C_0}"
  cat <<'JUDGE'

   둘 중 하나다. 구분해야 한다.

   (a) 가상 서버는 있는데 **멤버가 전부 죽어 있다.** L4 는 TCP 를 먼저 받고
       멤버로 넘기므로, 멤버가 없으면 connect 는 되고 HTTP 만 안 온다.
       현재 UPSTREAM_MODE=direct 이고 WAS 에 앱이 떠 있다면 이쪽이 유력하다
       — VS 의 멤버 주소가 10.3.21.51:8000 로 맞게 들어갔는지 확인할 것.

   (b) 그냥 8000 을 쓰는 다른 장비다. 이 경우는 VIP 와 무관하다.

   확인:
JUDGE
  for ip in "${OPEN[@]}"; do
    note "      curl -v --max-time 5 http://${ip}:${PORT}/api/info"
  done
  note ""
  note "   빈 응답으로 끊기면 (a), 우리 것이 아닌 HTTP 응답이 오면 (b) 다."
elif [ "${#REFUSED[@]}" -gt 0 ] || [ "${#UNREACH[@]}" -gt 0 ]; then
  printf '   %s경로는 열려 있다. 그런데 %s 을 리슨하는 주소가 없다.%s\n' "${C_NG}" "${PORT}" "${C_0}"
  cat <<'JUDGE'

   → 방화벽 문제가 아니다. **가상 서버가 아직 안 만들어진 것**이다.
      FortiADC 에 VS 를 만들어 달라고 요청해야 한다 (회신 대기 4번이 아니라
      13-1절 신규 요청에 가깝다). dc-internal-fortiadc-01 은 켜져 있으므로
      장비 문제도 아니다.

   → 관리 계정을 같이 요청할 것 (회신 대기 2번과 같은 항목이다).
      계정이 있으면 VS 생성 여부·backup server 지원을 한 번에 확인한다.
JUDGE
else
  printf '   %s대역 전체가 무응답이다. 스캔으로는 찾을 수 없다.%s\n' "${C_NG}" "${C_0}"
  cat <<'JUDGE'

   → RST 가 하나도 없다는 것은 방화벽이 이 대역을 통째로 drop 한다는 뜻이다.
      FW-09 를 `<DC500_L4_VIP>` 플레이스홀더로 신청했으므로(FIREWALL-REQUEST.md
      45행), 상대가 특정 주소 하나로만 열었거나 아예 보류한 것이다.

   → 이 경우 물어볼 것은 "VIP 주소가 무엇인가"가 아니라
      **"규칙 9번을 어떤 목적지로 적용했는가"** 다. 그 답이 곧 VIP 주소다.
      VIETTEL-EMAIL.md 의 L4 VIP 항목에 이 문장을 덧붙일 것.

   ※ 실행 위치가 WEB 이 맞는지 다시 확인할 것. 위치가 틀리면 결과가 이것과
      똑같이 나오고, 그 상태로 회신하면 없는 문제를 만들어 낸다.
JUDGE
fi

hdr "요약 한 줄"
printf '   %s:%s  open %d / refused %d / unreachable %d / filtered %d  (from %s)\n\n' \
       "${CIDR}" "${PORT}" "${#OPEN[@]}" "${#REFUSED[@]}" "${#UNREACH[@]}" "${n_filtered}" "${WHERE}"
