# SWAG / Nginx Reverse Proxy Setup for World Quiz
#
# These configs are designed for SWAG (Secure Web Application Gateway),
# but work with any nginx setup. Place them in your nginx proxy-confs
# folder (e.g. /config/nginx/proxy-confs/ for SWAG) and restart nginx.
#
# Before using:
# 1. Update the $upstream_app variables if SpacetimeDB / web server run
#    on a different host than nginx (e.g. 192.168.1.50).
# 2. Ensure your DNS has A records for:
#    - spacetime.yourdomain.com  -> your VPS IP
#    - quiz.yourdomain.com       -> your VPS IP
# 3. Make sure SWAG/nginx can obtain SSL certificates for these subdomains.
#
# Why two subdomains?
# SpacetimeDB uses WebSockets at the root path and is sensitive to path
# rewriting. A dedicated spacetime.* subdomain avoids subtle protocol bugs.
#
# Files:
#   spacetime.conf  -> proxies WebSocket traffic to SpacetimeDB (port 3080)
#   quiz.conf       -> proxies HTTP traffic to the static web server (port 8060)
#
# Important proxy settings (already included in the .conf files):
#   proxy_http_version 1.1;
#   proxy_set_header Upgrade $http_upgrade;
#   proxy_set_header Connection "upgrade";
#   proxy_send_timeout 3600s;
#   proxy_read_timeout 3600s;
#
# No auth_request off is needed if your SWAG template has no active auth.
# If you do have active auth, you may need to disable it for the websocket
# location to prevent the upgrade handshake from being intercepted.
