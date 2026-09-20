# shellcheck shell=bash
# =============================================================================
# 설치 스크립트 공통 — source 해서 쓴다.
#
# 화면 출력은 **한글과 영어를 나란히** 낸다. 서버 VM 콘솔에서 한글이 깨지는
# 경우가 있어서, 한 줄이 깨져도 바로 옆/아랫줄로 읽을 수 있게 한다.
# 주석은 한국어만 쓴다 — 읽는 사람과 읽는 장소가 다르다.
#
#   step "한글" "English"   →   == 1. 한글 | English ==
#   msg  "한글" "English"   →      한글
#                                  English
#   say  "ascii"            →      ascii            (값·경로 등 번역 불필요)
#   kv   "label" "value"    →      label        value
#
# 역할(AADC_ROLE)은 세 군데서 올 수 있고, 앞이 이긴다.
#   1) 첫 번째 인자      ./30-web.sh WEB-DC1
#   2) 환경변수          AADC_ROLE=WEB-DC1 ./30-web.sh
#   3) config.env        AADC_ROLE="..."
#
# ★ AADC_DC 는 역할에서 유도한다. 사람이 따로 적지 않는다.
#   역할과 DC 를 각각 적게 하면 둘이 어긋난 채로 설치되는 사고가 난다.
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

[ -f "${ROOT}/config.env" ] || {
  echo "ERROR: config.env 가 없다 / config.env not found"
  echo "       ${ROOT}/config.env"
  echo "       cp config.env.example config.env"
  exit 1
}

# ★ config.env 를 source 하면 AADC_ROLE 이 덮어써진다.
#   환경변수로 넘긴 값을 먼저 붙잡아 둬야 우선순위가 성립한다.
_env_role="${AADC_ROLE:-}"

# shellcheck disable=SC1091
. "${ROOT}/config.env"

# ----- 역할 결정 (인자 > 환경변수 > config.env) ------------------------------
if   [ -n "${AADC_ROLE_ARG:-}" ]; then AADC_ROLE="${AADC_ROLE_ARG}"
elif [ -n "${_env_role}" ];       then AADC_ROLE="${_env_role}"
fi

case "${AADC_ROLE}" in
  WEB-DC1|WAS-APP1-500|DB-MASTER|DB-BACKUP) AADC_DC="DC-500" ;;
  WEB-DC2|WAS-DC2|DB-DR)                    AADC_DC="DC-400" ;;
  MONITOR)                                  AADC_DC="${AADC_DC:-DC-500}" ;;
  *)
    cat <<ROLEERR
ERROR: 알 수 없는 역할 '${AADC_ROLE}'
       unknown role '${AADC_ROLE}'

  역할을 첫 번째 인자로 넘기면 config.env 를 고칠 필요가 없다.
  Pass the role as the first argument - no need to edit config.env:

      ./$(basename "${BASH_SOURCE[1]}") WEB-DC1

  쓸 수 있는 역할 / valid roles:
      DC-500 : WEB-DC1  WAS-APP1-500  DB-MASTER  DB-BACKUP
      DC-400 : WEB-DC2  WAS-DC2       DB-DR
      기타   : MONITOR  (점프서버·모니터링 호스트 / jump or monitoring host)
ROLEERR
    exit 2 ;;
esac
export AADC_ROLE AADC_DC

# ----- 출력 헬퍼 -------------------------------------------------------------
_step=0
step() { _step=$((_step+1)); printf '\n== %d. %s | %s ==\n' "${_step}" "$1" "$2"; }
msg()  { printf '   %s\n   %s\n' "$1" "$2"; }
say()  { printf '   %s\n' "$*"; }
kv()   { printf '   %-22s %s\n' "$1" "$2"; }
warn() { printf '   !! %s\n   !! %s\n' "$1" "$2"; }
die()  { printf '\nERROR: %s\n       %s\n' "$1" "${2:-}" >&2; exit 1; }

banner() {
  printf '\n'
  printf '===============================================================\n'
  printf ' %s\n' "$1"
  printf ' %s\n' "$2"
  printf ' role=%s  dc=%s  host=%s\n' "${AADC_ROLE}" "${AADC_DC}" "$(hostname)"
  printf '===============================================================\n'
}

# 역할이 이 스크립트 대상이 맞는지. 아니면 무엇을 실행해야 하는지 알려 준다.
require_role() {                 # require_role <glob> [<glob> ...]
  local pat
  for pat in "$@"; do
    # shellcheck disable=SC2254
    case "${AADC_ROLE}" in ${pat}) return 0 ;; esac
  done
  cat <<ROLEMISMATCH

ERROR: 역할 '${AADC_ROLE}' 은 $(basename "${BASH_SOURCE[1]}") 의 대상이 아니다.
       role '${AADC_ROLE}' is not handled by $(basename "${BASH_SOURCE[1]}")

  이 스크립트 대상 / this script handles:  $*

  이 호스트에 맞는 것을 역할과 함께 실행할 것.
  Run the right one for this host, passing the role explicitly:

      ./10-db.sh   DB-MASTER | DB-BACKUP | DB-DR
      ./20-was.sh  WAS-APP1-500 | WAS-DC2
      ./30-web.sh  WEB-DC1 | WEB-DC2

  (config.env 의 AADC_ROLE 기본값은 WAS-APP1-500 이다. 인자로 넘기는 쪽이 낫다.)
  (config.env defaults AADC_ROLE to WAS-APP1-500; the argument overrides it.)
ROLEMISMATCH
  exit 2
}

# 이 DC 기준의 로컬/교차 값.
resolve_dc_vars() {
  if [ "${AADC_DC}" = "DC-500" ]; then
    L4_VIP="${DC500_L4_VIP}";      CHECK_VS="${DC500_CHECK_VS_VIP}"
    WAS_LOCAL="${WAS_DC500_IP}";   PEER_WEB="${WEB_DC2_IP}"
    WEB_FQDN="${WEB1_FQDN}"
  else
    L4_VIP="${DC400_L4_VIP}";      CHECK_VS="${DC400_CHECK_VS_VIP}"
    WAS_LOCAL="${WAS_DC400_IP}";   PEER_WEB="${WEB_DC1_IP}"
    WEB_FQDN="${WEB2_FQDN}"
  fi
}

# `sh script.sh` 로 돌리면 shebang 이 무시돼 bash 확장이 깨진다.
require_bash() {
  [ -n "${BASH_VERSION:-}" ] || {
    echo "ERROR: sh 말고 bash 로 실행할 것 / run with bash, not sh"
    echo "       bash $(basename "${BASH_SOURCE[1]}") <role>"
    echo "       ./$(basename "${BASH_SOURCE[1]}") <role>"
    exit 2
  }
}
