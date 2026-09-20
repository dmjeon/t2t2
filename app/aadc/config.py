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
