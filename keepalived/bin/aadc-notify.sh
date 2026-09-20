#!/usr/bin/env bash
# =============================================================================
# /usr/local/bin/aadc-notify.sh — keepalived 상태 전이 훅
#   인자: MASTER | BACKUP | FAULT | STOP
#
# 안전장치 ④ 의 나머지 절반이다.
#   my.cnf 는 전 노드 read_only=ON 으로 고정해 두고,
#   **VIP 를 잡은 노드만** 여기서 그것을 푼다.
#   리부팅된 노드가 혼자 깨어나 쓰기를 받는 사고가 원천 차단된다.
#
# root 로 실행되며 MariaDB unix_socket 인증을 쓴다 (별도 비밀번호 불필요).
# =============================================================================
set -uo pipefail
STATE="${1:-UNKNOWN}"
TAG="aadc-keepalived"
LOG=/var/log/aadc-keepalived.log

log() { echo "$(date -Is) [${STATE}] $*" | tee -a "${LOG}" | logger -t "${TAG}"; }
alarm() { /usr/local/bin/aadc-alarm-send.sh "$1" "$2" 2>/dev/null || log "ALARM: $1 — $2"; }

mysql_do() { mysql -N -B -e "$1" 2>>"${LOG}"; }

case "${STATE}" in
  MASTER)
    log "VIP 획득 — 쓰기를 연다"
    # 죽은 구 master 를 계속 따라가지 않도록 복제 스레드를 끊는다.
    mysql_do "STOP SLAVE;" || true
    mysql_do "SET GLOBAL rpl_semi_sync_slave_enabled  = OFF;"
    mysql_do "SET GLOBAL rpl_semi_sync_master_enabled = ON;"
    mysql_do "SET GLOBAL read_only = OFF;"
    RO=$(mysql_do "SELECT @@read_only;")
    HOST=$(mysql_do "SELECT @@hostname;")
    log "read_only=${RO} on ${HOST}"
    if [ "${RO}" != "0" ]; then
      alarm "CRITICAL" "VIP 를 잡았으나 read_only 해제 실패 (${HOST}). 쓰기 불가 상태."
    else
      alarm "INFO" "DB writer 전환: ${HOST} 가 VIP 를 잡고 쓰기를 시작함"
    fi
    # nopreempt 이므로 이 상태가 그대로 정상 운영 상태가 된다.
    log "주의: nopreempt. 구 master 는 복귀해도 VIP 를 되찾지 않는다."
    log "     구 master 를 다시 슬레이브로 붙이려면 reattach-slave.sh 를 쓸 것."
    ;;

  BACKUP)
    log "VIP 상실 — 쓰기를 닫는다"
    mysql_do "SET GLOBAL read_only = ON;"
    mysql_do "SET GLOBAL rpl_semi_sync_master_enabled = OFF;"
    mysql_do "SET GLOBAL rpl_semi_sync_slave_enabled  = ON;"
    alarm "WARN" "$(hostname) 가 VIP 를 넘겼다. read_only=ON 으로 전환."
    ;;

  FAULT)
    log "track_script 실패 — 로컬 DB 이상 또는 게이트웨이 고립"
    mysql_do "SET GLOBAL read_only = ON;" || true
    alarm "CRITICAL" "$(hostname) FAULT: 로컬 DB 다운 또는 세그먼트 고립 (증인 도달 실패)"
    ;;

  STOP)
    log "keepalived 정지"
    mysql_do "SET GLOBAL read_only = ON;" || true
    alarm "WARN" "$(hostname) keepalived 정지. read_only=ON."
    ;;
esac
exit 0
