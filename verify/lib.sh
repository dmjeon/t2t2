# shellcheck shell=bash
# 검증 스크립트 공통 — source 해서 쓴다.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${AADC_CONF:-${HERE}/../config.env}"
if [ ! -f "${CONF}" ]; then
  echo "config.env 가 없다. cp config.env.example config.env 후 값을 채울 것." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${CONF}"

PASS=0; FAIL=0; SKIP=0
C_OK=$'\033[32m'; C_NG=$'\033[31m'; C_SK=$'\033[33m'; C_0=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_NG=""; C_SK=""; C_0=""; }

hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

ok()   { PASS=$((PASS+1)); printf '%s PASS%s %-10s %s\n' "${C_OK}" "${C_0}" "$1" "$2"; }
ng()   { FAIL=$((FAIL+1)); printf '%s FAIL%s %-10s %s\n' "${C_NG}" "${C_0}" "$1" "$2"; }
sk()   { SKIP=$((SKIP+1)); printf '%s SKIP%s %-10s %s\n' "${C_SK}" "${C_0}" "$1" "$2"; }

# assert <ID> <기대> <실제> <설명>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1" "$4  ($3)"; else ng "$1" "$4  기대=$2 실제=$3"; fi
}
assert_match() {
  if printf '%s' "$3" | grep -q "$2"; then ok "$1" "$4"; else ng "$1" "$4  '$2' 없음: $3"; fi
}

# jqget <json> <key>  — jq 가 없어도 동작하도록 fallback
# ★ `.k // empty` 를 쓰지 않는다. jq 의 // 는 false 도 "없음"으로 취급하므로
#   cross_dc:false 가 빈 문자열이 되어 "값을 못 읽음"과 구분되지 않는다.
#   cross_dc 는 degraded 판정의 핵심 값이라 이 구분이 중요하다.
jqget() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r "if has(\"$2\") then .$2 else empty end" 2>/dev/null
  else
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" | head -1
  fi
}

get() { curl -sf --max-time "${2:-5}" "$1" 2>/dev/null; }

summary() {
  printf '\n\033[1m----- 결과: PASS %d / FAIL %d / SKIP %d -----\033[0m\n' "${PASS}" "${FAIL}" "${SKIP}"
  [ "${FAIL}" -eq 0 ]
}

# 값이 비어 있으면 건너뛴다.
#
# ★ 2026-09-24 — 예전 자리표시자였던 10.3.20.100 이 **실제 VIP 로 확인됐다**
#   (두 DC 모두 .100). 그래서 그 주소를 "미확정"으로 거르던 가드를 뺐다.
#   그대로 두면 모든 L4 검증이 영원히 SKIP 되는데, 결과는 PASS 0 / FAIL 0
#   이라 문제가 없어 보인다 — 조용히 아무것도 검증하지 않는다.
need_l4() {
  case "${DC500_L4_VIP}" in
    "") sk "$1" "내부 L4 VIP 미설정. config.env 의 DC500_L4_VIP 를 채운 뒤 재실행."; return 1;;
  esac
  return 0
}
