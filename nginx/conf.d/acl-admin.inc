# =============================================================================
# /etc/nginx/conf.d/acl-admin.inc — 진단 화면·진단 API 접근 제어
#
# 검증 화면은 현재 DB writer 호스트명, semi-sync 상태(= RPO 가 깨졌는지),
# degraded 여부, 반대편 DC 상태를 그대로 보여 준다. WEB 은 www 로 인터넷에
# 노출되므로, 접근 제어가 없으면 이 전부가 공개된다.
#
# install/30-web.sh 가 config.env 의 ADMIN_ALLOW 로 allow 줄을 생성한다.
# =============================================================================
__ADMIN_ALLOW_LINES__
deny all;
