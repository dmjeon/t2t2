# keepalived — DB VIP (DC-500 내부)

```
VIP 10.3.31.50   ·   MASTER 10.3.31.51 (priority 100)  ·  BACKUP 10.3.31.53 (priority 90)
```

**이 VIP 는 DC 를 건너지 않는다.** 그래서 split-brain 이 구조적으로 성립하지
않는다. DC 간 VIP 는 기각된 설계다 (AADC-POC.md 부록 B) — DCI 단절 시 VIP 가
양쪽에서 동시에 활성화되고, L2 가 안전해도 파티션은 별개 문제이며 2 DC 는
쿼럼이 없기 때문이다.

---

## 파일

| 파일 | 설치 위치 |
|---|---|
| `keepalived.conf.master` | DB-MASTER `/etc/keepalived/keepalived.conf` |
| `keepalived.conf.backup` | DB-BACKUP 같은 경로 |
| `bin/chk_db.sh` | `/usr/local/bin/chk_db.sh` |
| `bin/aadc-notify.sh` | `/usr/local/bin/aadc-notify.sh` |
| `bin/reattach-slave.sh` | 수동 실행 (복귀 작업용) |

`install/10-db.sh` 가 `ens192` / `auth_pass` / `virtual_router_id` 를
`config.env` 값으로 치환해서 설치한다.

---

## 세 가지 장치가 서로를 보완한다

### ① unicast — `dc-db` 가 확장 세그먼트이기 때문

multicast VRRP 를 쓰면 광고가 DCI 를 타고 DC-400 까지 흘러간다. 트랙 B 실험
(부록 A)이 관찰하려는 것이 정확히 그 거동이다. 본설계에서는 `unicast_peer` 로
DC-500 안에 가둔다.

### ② `nopreempt` — 순단을 두 번 만들지 않는다

복구된 구 master 가 VIP 를 되찾으면 순단이 한 번 더 생긴다. 되찾지 않게 하고
재투입은 계획된 작업으로 한다.

**부수 효과가 좋다.** B 훈련(분기 1회) 때마다 master 역할이 `.51` ↔ `.53` 로
번갈아 가고, 되돌리는 작업이 0 이 되며, 두 노드가 균등하게 운영 경험을 쌓는다.

되돌릴 필요는 없지만 **구 master 를 슬레이브로 다시 붙이는 작업은 남는다.**
`bin/reattach-slave.sh <새_master_IP>` 가 그 작업이다.

### ③ 게이트웨이 증인 — 2노드에는 쿼럼이 없다

```bash
mysqladmin ping -h127.0.0.1 --silent || exit 1        # 로컬 DB 정상?
ping -c1 -W1 10.3.31.254 >/dev/null 2>&1 || exit 1    # 내가 고립된 건 아닌가?
```

고립된 노드는 게이트웨이에 닿지 못해 스스로 우선순위를 낮춘다(`weight -50`).
VIP 이중 보유를 구조적으로 막는 장치다. C4(NIC 다운)가 이것을 검증한다.

---

## 확인

```bash
ip -4 addr show ens192 | grep 10.3.31.50     # 누가 VIP 를 잡았나
journalctl -u keepalived -f
tail -f /var/log/aadc-keepalived.log         # 상태 전이 이력
../db/check-replication.sh
```

**쓰기 가능 노드는 항상 정확히 1개여야 한다.** 2개면 VIP 이중 보유이고,
0개면 `notify_master` 가 `read_only` 를 풀지 못한 것이다.
