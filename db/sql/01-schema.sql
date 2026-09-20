-- =============================================================================
-- AADC PoC 스키마  (DB-MASTER 에서만 실행. BACKUP/DR 로는 복제로 흘러간다)
--   mysql -h127.0.0.1 -uroot -p < 01-schema.sql
-- =============================================================================
CREATE DATABASE IF NOT EXISTS aadc
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE aadc;

-- 쓰기 경로 검증용. DR 전환 2단계 전에는 여기 INSERT 가 실패해야 정상이다.
CREATE TABLE IF NOT EXISTS write_log (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  dc         VARCHAR(16)  NOT NULL,          -- 쓴 WAS 의 DC
  was_host   VARCHAR(64)  NOT NULL,
  via_l4     VARCHAR(45)  NOT NULL DEFAULT '',
  note       VARCHAR(200) NOT NULL DEFAULT '',
  created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  KEY idx_created (created_at)
) ENGINE=InnoDB;

-- /api/info?log=true 로 남기는 경로 추적. 평시에는 쌓이지 않는다.
CREATE TABLE IF NOT EXISTS access_trace (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  req_id      VARCHAR(64),
  client_ip   VARCHAR(45),
  via_l4      VARCHAR(45),
  l4_dc       VARCHAR(16),                   -- 경유한 L4 의 DC
  was_dc      VARCHAR(16),                   -- 처리한 WAS 의 DC
  was_host    VARCHAR(64),
  web_host    VARCHAR(64),
  app_version VARCHAR(32),
  created_at  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  KEY idx_created (created_at),
  KEY idx_cross (l4_dc, was_dc)              -- 교차 경유 건수 집계
) ENGINE=InnoDB;

-- AADC_DEEP_WRITER_PROBE=write 일 때 /health/deep 이 쓰는 테이블.
-- 노드당 1행만 유지되므로 무한정 커지지 않는다.
CREATE TABLE IF NOT EXISTS health_probe (
  node      VARCHAR(64) PRIMARY KEY,
  dc        VARCHAR(16) NOT NULL,
  n         BIGINT      NOT NULL DEFAULT 1,
  probed_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                         ON UPDATE CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;

-- 복제 지연 측정. Seconds_Behind_Master 는 idle 구간에서 0 으로 보이는
-- 함정이 있어, 쓰기가 없어도 지연이 드러나도록 심장박동을 따로 둔다.
CREATE TABLE IF NOT EXISTS repl_heartbeat (
  id      TINYINT PRIMARY KEY,
  source  VARCHAR(64) NOT NULL,
  beat_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;
INSERT IGNORE INTO repl_heartbeat (id, source) VALUES (1, 'init');

-- DR 전환 흔적. 2단계 게이트를 누가 언제 열었는지 남긴다.
CREATE TABLE IF NOT EXISTS failover_log (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  step       VARCHAR(32)  NOT NULL,          -- was_env_switch | read_only_off | failback
  actor      VARCHAR(64)  NOT NULL,
  detail     VARCHAR(255) NOT NULL DEFAULT '',
  created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;
