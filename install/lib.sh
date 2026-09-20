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
#   kv   "label" "value"    →      label        value   (라벨은 ASCII 만!
#                                한글은 printf 폭 계산이 어긋나 정렬이 깨진다)
#
# 역할(AADC_ROLE)은 네 군데서 올 수 있고, 앞이 이긴다.
#   1) 첫 번째 인자      ./30-web.sh WEB-DC1
#   2) 환경변수          AADC_ROLE=WEB-DC1 ./30-web.sh
#   3) 이 호스트의 IP    ← 평소에는 이것만으로 충분하다. 인자 불필요
#   4) config.env        AADC_ROLE="..."   (최후. 7대 중 6대에서 틀린 값이다)
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

# ----- 이 호스트의 IP 로 역할을 알아낸다 --------------------------------------
# config.env 의 AADC_ROLE 은 7대 중 6대에서 틀린 값이다. 기본값 하나를
# 서버마다 고치게 하는 대신, 서버가 자기가 누구인지 스스로 말하게 한다.
detect_role_by_ip() {
  local ips ip
  ips="$( (ip -4 -o addr show scope global 2>/dev/null \
             | awk '{split($4,a,"/"); print a[1]}') \
          || hostname -I 2>/dev/null )"
  for ip in ${ips}; do
    case "${ip}" in
      "${WEB_DC1_IP}")    echo WEB-DC1;      return 0 ;;
      "${WEB_DC2_IP}")    echo WEB-DC2;      return 0 ;;
      "${WAS_DC500_IP}")  echo WAS-APP1-500; return 0 ;;
      "${WAS_DC400_IP}")  echo WAS-DC2;      return 0 ;;
      "${DB_MASTER_IP}")  echo DB-MASTER;    return 0 ;;
      "${DB_BACKUP_IP}")  echo DB-BACKUP;    return 0 ;;
      "${DB_DR_IP}")      echo DB-DR;        return 0 ;;
      # DB_VIP 는 일부러 넣지 않는다. VIP 를 잡은 노드는 자기 실주소로도
      # 잡히므로, VIP 를 보고 역할을 정하면 전환 때마다 역할이 바뀐다.
    esac
  done
  return 1
}

# ----- 역할 결정 (인자 > 환경변수 > IP 자동감지 > config.env) -----------------
AADC_ROLE_SRC="config.env"
if   [ -n "${AADC_ROLE_ARG:-}" ]; then
  AADC_ROLE="${AADC_ROLE_ARG}";  AADC_ROLE_SRC="argument"
elif [ -n "${_env_role}" ]; then
  AADC_ROLE="${_env_role}";      AADC_ROLE_SRC="environment"
elif _detected="$(detect_role_by_ip)"; then
  AADC_ROLE="${_detected}";      AADC_ROLE_SRC="detected from this host's IP"
fi

host_ips() {
  (ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}') \
    || hostname -I 2>/dev/null | tr ' ' '\n'
}

# 이 역할이 원래 가져야 할 주소. 임시 주소로 설치 중인지 판별하는 데 쓴다.
expected_ip_for_role() {
  case "$1" in
    WEB-DC1)      echo "${WEB_DC1_IP}" ;;
    WEB-DC2)      echo "${WEB_DC2_IP}" ;;
    WAS-APP1-500) echo "${WAS_DC500_IP}" ;;
    WAS-DC2)      echo "${WAS_DC400_IP}" ;;
    DB-MASTER)    echo "${DB_MASTER_IP}" ;;
    DB-BACKUP)    echo "${DB_BACKUP_IP}" ;;
    DB-DR)        echo "${DB_DR_IP}" ;;
    *)            echo "" ;;
  esac
}

case "${AADC_ROLE}" in
  WEB-DC1|WAS-APP1-500|DB-MASTER|DB-BACKUP) AADC_DC="DC-500" ;;
  WEB-DC2|WAS-DC2|DB-DR)                    AADC_DC="DC-400" ;;
  MONITOR)                                  AADC_DC="${AADC_DC:-DC-500}" ;;
  *)
    cat <<ROLEERR

ERROR: unknown role '${AADC_ROLE}'  /  알 수 없는 역할

  FIX: pass the role as the first argument
       ./$(basename "${BASH_SOURCE[1]}") WEB-DC1

  valid roles / 쓸 수 있는 역할
      DC-500 : WEB-DC1  WAS-APP1-500  DB-MASTER  DB-BACKUP
      DC-400 : WEB-DC2  WAS-DC2       DB-DR
      other  : MONITOR

  this host's IPs / 이 호스트의 IP
      $(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')
  (none of them matched config.env, so the role could not be detected)
  (config.env 의 어느 주소와도 맞지 않아 자동 감지에 실패했다)
ROLEERR
    exit 2 ;;
esac
export AADC_ROLE AADC_DC

# ----- 임시 주소로 설치 중인가 -----------------------------------------------
# 방화벽이 안 열려 패키지를 못 받는 세그먼트에서, 인터넷이 되는 대역의 주소를
# 임시로 붙여 설치만 먼저 하는 경우가 있다. 그 상태에서는 **주소에 묶인 구성이
# 전부 틀어진다** — keepalived unicast, VIP 서브넷, 게이트웨이 증인 같은 것들.
# 설치 스크립트가 그걸 알고 건너뛸 수 있게 여기서 판정해 둔다.
ROLE_EXPECTED_IP="$(expected_ip_for_role "${AADC_ROLE}")"
TEMP_ADDRESS="no"
if [ -n "${ROLE_EXPECTED_IP}" ] && ! host_ips | grep -qx "${ROLE_EXPECTED_IP}"; then
  TEMP_ADDRESS="yes"
fi
export ROLE_EXPECTED_IP TEMP_ADDRESS

warn_temp_address() {
  [ "${TEMP_ADDRESS}" = "yes" ] || return 0
  cat <<TEMPADDR

  ---------------------------------------------------------------------------
  ★ 임시 주소로 설치 중이다 / INSTALLING ON A TEMPORARY ADDRESS

    이 역할의 주소 / expected : ${ROLE_EXPECTED_IP}
    이 호스트의 주소 / actual : $(host_ips | tr '\n' ' ')

    주소에 묶인 구성은 건너뛴다. 정식 주소로 옮긴 뒤 같은 스크립트를 다시
    돌리면 그때 구성된다 (스크립트는 여러 번 돌려도 된다).
    Address-bound configuration is skipped. Re-run this script after moving
    the host to its real address; these scripts are safe to run repeatedly.
  ---------------------------------------------------------------------------
TEMPADDR
}

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
  printf ' role source: %s\n' "${AADC_ROLE_SRC}"
  printf '===============================================================\n'
}

# 역할이 이 스크립트 대상이 맞는지. 아니면 무엇을 실행해야 하는지 알려 준다.
#
# 탈출구: AADC_SKIP_ROLE_CHECK=1 로 검사를 건너뛸 수 있다.
#   ★ 다만 이건 대개 원하는 결과를 주지 않는다. 검사만 꺼질 뿐
#     AADC_ROLE 값 자체는 그대로이므로, 스크립트 안의 역할별 분기가
#     아무것도 고르지 못하고 **조용히 넘어간다.** 설치가 된 것처럼
#     끝나고 실제로는 아무 일도 일어나지 않는다.
#   제대로 된 방법은 역할을 맞게 주는 것이다:  ./10-db.sh DB-MASTER
#   지금 무엇이 어떻게 정해졌는지는 ./whoami.sh 가 보여 준다.
require_role() {                 # require_role <glob> [<glob> ...]
  local pat
  if [ "${AADC_SKIP_ROLE_CHECK:-}" = "1" ]; then
    warn "역할 검사를 건너뛴다 (AADC_SKIP_ROLE_CHECK=1). 현재 역할=${AADC_ROLE}" \
         "Role check bypassed. Current role is still '${AADC_ROLE}'."
    msg  "역할이 틀리면 설치는 조용히 아무것도 하지 않는다. ./whoami.sh 로 확인할 것." \
         "If the role is wrong this installs nothing, silently. Run ./whoami.sh."
    return 0
  fi
  for pat in "$@"; do
    # shellcheck disable=SC2254
    case "${AADC_ROLE}" in ${pat}) return 0 ;; esac
  done
  cat <<ROLEMISMATCH

ERROR: role '${AADC_ROLE}' is not handled by $(basename "${BASH_SOURCE[1]}")
       역할 '${AADC_ROLE}' 은 이 스크립트의 대상이 아니다

  FIX: pass the role as the first argument
       ./$(basename "${BASH_SOURCE[1]}") $(echo "$1" | tr -d '*')...

       ./10-db.sh   DB-MASTER | DB-BACKUP | DB-DR
       ./20-was.sh  WAS-APP1-500 | WAS-DC2
       ./30-web.sh  WEB-DC1 | WEB-DC2

  this script handles / 이 스크립트 대상 :  $*
  role came from / 역할 출처            :  ${AADC_ROLE_SRC}

  this host's IPs / 이 호스트의 IP
      $(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')

  IP 자동 감지가 됐다면 인자는 필요 없다. 위 주소가 config.env 의
  WEB_DC1_IP / WAS_DC500_IP / DB_MASTER_IP ... 와 맞는지 확인할 것.
  If auto-detection had worked you would not need the argument. Check that the
  address above matches WEB_DC1_IP / WAS_DC500_IP / DB_MASTER_IP in config.env.
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
