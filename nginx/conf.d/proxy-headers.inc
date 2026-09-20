# =============================================================================
# /etc/nginx/conf.d/proxy-headers.inc — 모든 proxy_pass 가 include 한다
# AADC-POC.md 3-2절
# =============================================================================
proxy_http_version 1.1;
proxy_set_header Connection "";              # upstream keepalive 유지

proxy_set_header Host             $host;
proxy_set_header X-Forwarded-For  $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP        $remote_addr;
proxy_set_header X-Request-Id     $request_id;

# WAS 가 "어느 WEB 이 보냈는지"를 알 수 있게 한다.
# L4 가 Full NAT 라 WAS 입장에서 클라이언트는 L4 이지, nginx 가 아니다(5-1절).
proxy_set_header X-Web-Host       $hostname;
proxy_set_header X-Web-Addr       $server_addr;
