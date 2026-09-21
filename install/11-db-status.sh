#!/usr/bin/env bash
# =============================================================================
# DB 상태 점검 — 읽기 전용 (기본). DB-MASTER / BACKUP / DR 에서 실행.
#
#   ./11-db-status.sh                 상태만 본다
#   ./11-db-status.sh --open-writes   read_only=OFF 까지 한다 (임시 조치)
#
# 왜 있는가: "스키마가 있는가 / 계정이 있는가 / 쓰기가 열려 있는가" 세 가지를
# 매번 손으로 치고 있었다. 이 셋이 WAS 의 /health/deep 이 200 이 되는 조건
# 전부다. 하나라도 틀리면 writer_unreachable 이 되고, 그러면 GSLB 가 그 DC 를
# 빼 버린다 (GSLB.md §0-3).
#
# ★ read_only=ON 은 고장이 아니다. 쓰기는 keepalived 가 VIP 를 잡은 노드에서만
#   열리는 설계다(db/init-01-master.sh). keepalived 가 아직 없는 동안에만
#   --open-writes 로 손으로 연다. **mariadb 를 재시작하면 다시 잠긴다.**
# =============================================================================
set -uo pipefail

OPEN_WRITES="no"
ARGS=()
for a in "$@"; do
  case "${a}" in
    --open-writes) OPEN_WRITES="yes" ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) ARGS+=("${a}") ;;
  esac
done
AADC_ROLE_ARG="${ARGS[0]:-}"

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_bash
require_role 'DB-MASTER' 'DB-BACKUP' 'DB-DR'

banner "DB 상태 점검" "DB status"

FAIL=0
q() { mysql -N -B -e "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
step "접속" "Connect"
if ! mysql -e "SELECT 1" >/dev/null 2>&1; then
  warn "로컬 소켓으로 mysql 접속이 안 된다. mariadb 가 떠 있는가?" \
       "Cannot connect over the local socket. Is mariadb running?"
  say "systemctl status mariadb"
  exit 1
fi
say "ok (local socket, root)"

# ---------------------------------------------------------------------------
step "서버 정체" "Server identity"
kv "hostname"   "$(q 'SELECT @@hostname')"
kv "server_id"  "$(q 'SELECT @@server_id')"
kv "version"    "$(q 'SELECT @@version')"
kv "bind/port"  "$(q 'SELECT @@bind_address'):$(q 'SELECT @@port')"
RO="$(q 'SELECT @@global.read_only')"
kv "read_only"  "${RO}   $( [ "${RO}" = "0" ] && echo '(쓰기 열림 / writable)' || echo '(잠김 / locked)' )"

# ---------------------------------------------------------------------------
step "스키마" "Schema"
if [ "$(q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${DB_NAME}'")" = "1" ]; then
  kv "database"  "${DB_NAME}  있음 / present"
  TBLS="$(q "SELECT GROUP_CONCAT(table_name ORDER BY table_name) FROM information_schema.tables WHERE table_schema='${DB_NAME}'")"
  kv "tables"    "${TBLS:-(없음 / none)}"
  [ -z "${TBLS}" ] && FAIL=1
else
  warn "데이터베이스 '${DB_NAME}' 이 없다." "Database '${DB_NAME}' is missing."
  FAIL=1
fi

# ---------------------------------------------------------------------------
step "계정" "Accounts"
# WAS 는 dc-app / dr-app 대역에서 붙는다. 두 줄이 다 있어야 DC-400 WAS 가 붙는다.
for u in "${DB_APP_USER}@10.3.21.%" "${DB_APP_USER}@10.7.21.%" \
         "${DB_REPL_USER}@10.3.31.%" "${DB_HB_USER}@127.0.0.1"; do
  n="${u%@*}"; h="${u#*@}"
  if [ "$(q "SELECT COUNT(*) FROM mysql.user WHERE user='${n}' AND host='${h}'")" = "1" ]; then
    kv "${u}" "있음 / present"
  else
    kv "${u}" "!! 없음 / MISSING"
    FAIL=1
  fi
done

# ---------------------------------------------------------------------------
step "판정" "Verdict"
if [ "${FAIL}" != "0" ]; then
  warn "스키마 또는 계정이 갖춰지지 않았다." "Schema or accounts are incomplete."
  say  "  다음 / next:   sudo ./db/init-01-master.sh"
  say  "  (재실행 안전. 단 my.cnf 를 다시 깔고 mariadb 를 재시작하므로"
  say  "   끝나면 read_only 가 다시 ON 이 된다 — 그 뒤 --open-writes 로 연다)"
elif [ "${RO}" != "0" ]; then
  say  "스키마·계정은 갖춰졌다. 쓰기만 잠겨 있다 (설계상 정상)."
  say  "The schema and accounts are fine; only writes are locked (by design)."
  say  "  다음 / next:   sudo ./install/11-db-status.sh --open-writes"
else
  say  "DB 쪽 준비 완료. WAS 에서 다음을 확인한다:"
  say  "The DB side is ready. From a WAS host:"
  say  "  mysql -h ${DB_MASTER_IP} -u ${DB_APP_USER} -p'<DB_APP_PASS>' ${DB_NAME} \\"
  say  "        -e \"SELECT @@hostname,@@global.read_only\""
  say  "  -> DC-400 WAS(${WAS_DC400_IP})에서만 실패하면 방화벽 13번 미적용이다"
fi

# ---------------------------------------------------------------------------
if [ "${OPEN_WRITES}" = "yes" ]; then
  step "쓰기 열기 (임시)" "Open writes (temporary)"
  if [ "${AADC_ROLE}" != "DB-MASTER" ]; then
    warn "이 노드는 ${AADC_ROLE} 다. MASTER 가 아닌 노드의 쓰기는 열지 않는다." \
         "This node is ${AADC_ROLE}, not the master - refusing to open writes."
    exit 1
  fi
  mysql -e "SET GLOBAL read_only=OFF"
  kv "read_only" "$(q 'SELECT @@global.read_only')"
  msg "★ 임시 조치다. mariadb 를 재시작하면 my.cnf 의 read_only=ON 으로 되돌아간다." \
      "TEMPORARY. A mariadb restart reverts to read_only=ON from my.cnf."
  msg "  정식으로는 keepalived 가 VIP 를 잡을 때 notify_master 가 연다." \
      "  Properly, keepalived opens it via notify_master when it takes the VIP."
fi

echo
