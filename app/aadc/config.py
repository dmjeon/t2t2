"""환경 변수 기반 설정. 파일은 /etc/aadc/was.env (systemd EnvironmentFile)."""
import os
import socket


def _int(key: str, default: int) -> int:
    try:
        return int(os.getenv(key, default))
    except (TypeError, ValueError):
        return default


def _float(key: str, default: float) -> float:
    try:
        return float(os.getenv(key, default))
    except (TypeError, ValueError):
        return default


class Settings:
    # 이 WAS가 속한 DC. /api/info 와 카나리 배포 식별에 쓴다.
    dc = os.getenv("AADC_DC", "DC-500")
    node = os.getenv("AADC_NODE", socket.gethostname())
    app_version = os.getenv("AADC_APP_VERSION", "0.0.0")

    # SNAT 된 L4 주소로 "어느 DC의 L4를 경유했는가"를 판정한다 (AADC-POC.md 5-1절).
    l4_prefix_dc500 = os.getenv("AADC_L4_PREFIX_DC500", "10.3.20.")
    l4_prefix_dc400 = os.getenv("AADC_L4_PREFIX_DC400", "10.7.20.")

    # L4 우회(direct) 모드에서는 클라이언트가 L4 가 아니라 WEB 자신이다.
    # 그 경우를 "알 수 없음"으로 뭉뚱그리지 않고 명시적으로 구분한다 —
    # 우회 중이라는 사실 자체가 검증 결과를 해석할 때 가장 중요한 정보다.
    web_prefix_dc500 = os.getenv("AADC_WEB_PREFIX_DC500", "10.3.11.")
    web_prefix_dc400 = os.getenv("AADC_WEB_PREFIX_DC400", "10.7.11.")

    # ----- 내부 L4 (FortiADC) -----------------------------------------------
    # 관측이 아니라 **기대값**이다. /l4test 화면이 "설치는 이렇게 됐는데 실제로
    # 지나온 길은 저렇다"를 나란히 보여 주는 데만 쓴다. 판정 자체는 언제나
    # req.client.host(= 앞 홉 주소) 로만 한다.
    upstream_mode = os.getenv("AADC_UPSTREAM_MODE", "l4").lower()
    l4_vip = os.getenv("AADC_L4_VIP", "")
    # 이 DC L4 풀의 원격(backup) 멤버 주소. 점검 전용 VS 대신 직접 부른다.
    backup_member = os.getenv("AADC_BACKUP_MEMBER", "")
    l4_port = _int("AADC_L4_PORT", 8000)
    app_port = _int("AADC_APP_PORT", 8000)

    # mariadb | sqlite
    #   mariadb  본설계. DB VIP 직결.
    #   sqlite   임시. DB 서버에 접근할 수 없는 동안 WAS 로컬 파일로 대신한다.
    #            ★ 공유 DB 가 아니다. 두 WAS 가 서로 다른 데이터를 본다.
    db_mode = os.getenv("AADC_DB_MODE", "mariadb").lower()
    sqlite_path = os.getenv("AADC_SQLITE_PATH", "/opt/aadc/data/aadc.sqlite")

    # DB VIP 에 직접 붙는다 (AADC-POC.md 3-4절). 평시 10.3.31.50, DR 전환 시
    # 사람이 was.env 를 고쳐 10.7.31.52 로 바꾸고 앱을 재시작한다.
    db_host = os.getenv("AADC_DB_HOST", "10.3.31.50")
    db_port = _int("AADC_DB_PORT", 3306)
    db_user = os.getenv("AADC_DB_USER", "aadc_app")
    db_pass = os.getenv("AADC_DB_PASS", "")
    db_name = os.getenv("AADC_DB_NAME", "aadc")
    db_connect_timeout = _int("AADC_DB_CONNECT_TIMEOUT", 2)
    db_read_timeout = _int("AADC_DB_READ_TIMEOUT", 3)
    db_pool_size = _int("AADC_DB_POOL_SIZE", 8)

    # select | write
    deep_writer_probe = os.getenv("AADC_DEEP_WRITER_PROBE", "select").lower()
    health_cache_ttl = _float("AADC_HEALTH_CACHE_TTL", 1.0)

    @property
    def peer_dc(self) -> str:
        return "DC-400" if self.dc == "DC-500" else "DC-500"

    @property
    def db_dc(self) -> str:
        """지금 붙어 있는 DB 가 어느 DC 에 있는가.

        평시 10.3.31.x(DC-500), DR 전환 후 10.7.31.x(DC-400).
        고정값으로 두면 DR 전환 뒤에 지연 계측 해석이 뒤집힌다.
        """
        if self.db_host.startswith("10.3."):
            return "DC-500"
        if self.db_host.startswith("10.7."):
            return "DC-400"
        return "unknown"


settings = Settings()
