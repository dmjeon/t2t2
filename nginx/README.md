# WEB (nginx)

**WEB 은 로컬 L4 VIP 하나만 호출한다. WAS 선택에 관여하지 않는다.**
교차(backup) 멤버로 넘길지 말지는 전적으로 L4 가 정한다. 그래서 WAS 장애가
GSLB 전환으로 번지지 않는다.

---

## 파일

| 파일 | 설치 위치 |
|---|---|
| `nginx.conf` | `/etc/nginx/nginx.conf` |
| `conf.d/00-realip.conf` | 그대로 |
| `conf.d/proxy-headers.inc` | 그대로 (`include` 전용) |
| `conf.d/10-upstream.conf.template` | 치환 후 `10-upstream.conf` |
| `conf.d/20-aadc-web.conf.template` | 치환 후 `20-aadc-web.conf` |

`install/30-web.sh` 가 `__L4_VIP__` 등 플레이스홀더를 `config.env` 값으로
치환한다. DC-500 / DC-400 에 같은 스크립트를 돌리면 `AADC_DC` 에 따라
로컬/교차 값이 자동으로 뒤집힌다.

---

## 경로 4개가 서로 다른 곳을 본다

```
/api/           → was_pool          로컬 L4 VIP:8000     실서비스
/health/deep    → was_pool          로컬 L4 VIP:8000     GSLB 전용
/health/local   → was_local_direct  로컬 WAS:8000        알람 전용 (L4 우회)
/peer/          → peer_web          반대편 WEB:80        검증 화면 전용
```

`/health/deep` 이 **실트래픽과 같은 경로**를 타는 것이 핵심이다. backup 전환이
일어나면 체크도 자동으로 backup 을 타므로, 별도 로직 없이 "WAS 장애로는 DC 가
넘어가지 않는다"는 의도가 그대로 구현된다.

`/health/local` 은 반대로 **L4 를 우회해 로컬 WAS 를 직접** 본다. 실패 =
"backup 으로 넘어가 있다" 이며, 반응하는 주체는 GSLB 가 아니라 **사람**이다.

| 엔드포인트 | 실패 시 | 누가 반응 |
|---|---|---|
| `/health/local` | 알람 발생 | 사람이 WAS 를 고침 |
| `/health/deep` | GSLB 에서 이탈 | 자동 |

---

## `set_real_ip_from` 이 없으면

모든 로그가 FortiADC IP(`10.3.10.241` / `10.7.10.241`)로 찍힌다.

다만 **전제가 하나 더 있다.** DMZ FortiADC 가 X-Forwarded-For 를 삽입해야
복원할 원본이 존재한다. 삽입이 없으면 고객 IP 는 nginx 에 닿기 전에 이미
소실돼 있고, 서버 쪽에서 고칠 수 없다.

판정: R5 에서 `client_ip` 가 `10.3.10.241` 로 나오면 FortiADC 설정 누락이다.

Viettel 요청 문구:

> The external FortiADC must preserve the original client IP — either by using an
> HTTP profile with **X-Forwarded-For insertion**, or by operating in transparent
> mode. Otherwise the customer source IP is lost before it reaches our web servers.

---

## 흔한 함정

| 증상 | 원인 |
|---|---|
| 전부 502, 설정은 맞음 | **SELinux `httpd_can_network_connect`** — `30-web.sh` 가 켠다 |
| 업스트림 keepalive 가 안 먹음 | `proxy_http_version 1.1` + `Connection ""` 누락 (`proxy-headers.inc` 에 있음) |
| `default.conf` 와 충돌 | `30-web.sh` 가 `.disabled` 로 치운다 |
| `/health/deep` 이 항상 성공 | deep 이 L4 VIP 가 아니라 WAS 를 직접 보고 있다. C18 이 잡아낸다 |

---

## WEB 계층의 성질

**1:1 구조에서 유일하게 흡수 주체가 없는 계층이다.** WEB-DC1 이 죽으면 DC-500
에서 할 수 있는 것이 없고 GSLB 전환뿐이다. 감지 6초 + TTL 20초 ≈ 26초.
이것이 이 설계의 최장 장애 구간이며 **수용 항목**이다. C10 이 실측한다.
