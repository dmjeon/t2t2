-- =============================================================================
-- 계정 — DB-MASTER 에서 실행 (복제로 BACKUP/DR 까지 전파된다)
-- 비밀번호는 config.env 값으로 치환해서 쓴다.
--   sed -e "s/__APP_PASS__/$DB_APP_PASS/" ... | mysql -uroot -p
-- =============================================================================

-- 애플리케이션 (WAS 에서 DB VIP 로 직접 들어온다)
-- ★ SUPER 를 주지 않는다. MariaDB 에는 super_read_only 가 없으므로,
--   read_only=ON 을 우회할 수 있는 권한을 애초에 주지 않는 것이 유일한 대체 수단이다.
-- 호스트를 WAS 대역으로 한정한다. '%' 는 방화벽보다 넓어 의미가 없다.
CREATE USER IF NOT EXISTS 'aadc_app'@'10.3.21.%' IDENTIFIED BY '__APP_PASS__';
CREATE USER IF NOT EXISTS 'aadc_app'@'10.7.21.%' IDENTIFIED BY '__APP_PASS__';
GRANT SELECT, INSERT, UPDATE, DELETE ON aadc.* TO 'aadc_app'@'10.3.21.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON aadc.* TO 'aadc_app'@'10.7.21.%';

-- 복제 심장박동 (DB-MASTER / DB-BACKUP 의 로컬 데몬)
-- ★ 이 계정에 SUPER 가 없어야 한다. 있으면 read_only=ON 인 BACKUP 에서도
--   UPDATE 가 성공해 복제본에 로컬 쓰기가 남고, gtid_strict_mode=ON 에서
--   GTID 가 갈라진다. "writer 에서만 박동이 찍힌다"는 전제가 여기에 달려 있다.
CREATE USER IF NOT EXISTS 'aadc_hb'@'127.0.0.1' IDENTIFIED BY '__HB_PASS__';
CREATE USER IF NOT EXISTS 'aadc_hb'@'localhost' IDENTIFIED BY '__HB_PASS__';
GRANT SELECT, UPDATE ON aadc.repl_heartbeat TO 'aadc_hb'@'127.0.0.1';
GRANT SELECT, UPDATE ON aadc.repl_heartbeat TO 'aadc_hb'@'localhost';

-- 초기 적재용 덤프 계정
-- ★ repl 계정으로는 mysqldump 를 뜰 수 없다. REPLICATION SLAVE 는 바이너리 로그를
--   읽을 권한일 뿐이라 --all-databases 가 'Access denied' 로 실패한다.
--   --single-transaction + --master-data 는 FLUSH TABLES WITH READ LOCK 을 쓰므로
--   RELOAD 도 필요하다. SUPER 는 주지 않는다(읽기 전용 계정).
CREATE USER IF NOT EXISTS 'aadc_dump'@'10.3.31.%' IDENTIFIED BY '__DUMP_PASS__';
CREATE USER IF NOT EXISTS 'aadc_dump'@'10.7.31.%' IDENTIFIED BY '__DUMP_PASS__';
GRANT SELECT, RELOAD, LOCK TABLES, SHOW VIEW, EVENT, REPLICATION CLIENT
  ON *.* TO 'aadc_dump'@'10.3.31.%';
GRANT SELECT, RELOAD, LOCK TABLES, SHOW VIEW, EVENT, REPLICATION CLIENT
  ON *.* TO 'aadc_dump'@'10.7.31.%';

-- 복제
CREATE USER IF NOT EXISTS 'repl'@'10.3.31.%'  IDENTIFIED BY '__REPL_PASS__';
CREATE USER IF NOT EXISTS 'repl'@'10.7.31.%'  IDENTIFIED BY '__REPL_PASS__';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'10.3.31.%';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'10.7.31.%';

-- keepalived chk_db + 알람 헬스체크
CREATE USER IF NOT EXISTS 'monitor'@'127.0.0.1'   IDENTIFIED BY '__MON_PASS__';
CREATE USER IF NOT EXISTS 'monitor'@'10.3.%'      IDENTIFIED BY '__MON_PASS__';
CREATE USER IF NOT EXISTS 'monitor'@'10.7.%'      IDENTIFIED BY '__MON_PASS__';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'127.0.0.1';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'10.3.%';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'10.7.%';
GRANT SELECT ON aadc.repl_heartbeat TO 'monitor'@'127.0.0.1';
GRANT SELECT ON aadc.repl_heartbeat TO 'monitor'@'10.3.%';
GRANT SELECT ON aadc.repl_heartbeat TO 'monitor'@'10.7.%';

FLUSH PRIVILEGES;
