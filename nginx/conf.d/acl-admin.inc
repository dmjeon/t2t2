# =============================================================================
# /etc/nginx/conf.d/acl-admin.inc — 진단 화면·진단 API 접근 제어
#
# 검증 화면은 현재 DB writer 호스트명, semi-sync 상태(= RPO 가 깨졌는지),
# degraded 여부, 반대편 DC 상태를 그대로 보여 준다. WEB 은 www 로 인터넷에
# 노출되므로, 접근 제어가 없으면 이 전부가 공개된다.
#
# ★ satisfy any — 둘 중 하나만 통과하면 된다.
#
#     ① 소스 IP 가 ADMIN_ALLOW 안에 있다        (사내·관리 대역)
#     ② 또는 basic 인증에 성공한다              (그 밖의 모든 경로)
#
#   IP 만으로는 안 되는 이유가 있다. 앞단(FortiGate / DMZ FortiADC)이 SNAT 를
#   하면 nginx 가 보는 소스 주소는 고객 IP 가 아니라 앞단 장비의 주소다.
#   그러면 사무실 공인 IP 를 아무리 적어도 맞지 않는다. 게다가 앞단 주소를
#   허용 목록에 넣어 버리면 인터넷 전체를 허용하는 것과 같아져 ACL 이 무의미해진다.
#   XFF 삽입(회신 대기 항목)이 적용되기 전까지는 ②가 유일하게 확실한 수단이다.
#
#   지금 nginx 가 무엇을 보고 있는지는 /health/web 이 알려 준다 (ACL 없음):
#       curl -s http://<WEB>/health/web
#       raw = real_ip 적용 전 주소,  client = ACL 이 판정에 쓰는 값
#
# install/30-web.sh 가 ADMIN_ALLOW 로 allow 줄을, ADMIN_USER/ADMIN_PASS 로
# /etc/nginx/.htpasswd 를 만든다.
# =============================================================================
satisfy any;

__ADMIN_ALLOW_LINES__
deny all;

auth_basic           "AADC PoC - diagnostics";
auth_basic_user_file /etc/nginx/.htpasswd;
