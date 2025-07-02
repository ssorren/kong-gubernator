# docker run -d --name kong-gateway \
# --network=kong-net \
# -e "KONG_DATABASE=postgres" \
# -e "KONG_PG_HOST=kong-database" \
# -e "KONG_PG_USER=kong" \
# -e "KONG_PG_PASSWORD=kongpass" \
# -e "KONG_PROXY_ACCESS_LOG=/dev/stdout" \
# -e "KONG_ADMIN_ACCESS_LOG=/dev/stdout" \
# -e "KONG_PROXY_ERROR_LOG=/dev/stderr" \
# -e "KONG_ADMIN_ERROR_LOG=/dev/stderr" \
# -e "KONG_ADMIN_LISTEN=0.0.0.0:8001" \
# -e "KONG_ADMIN_GUI_URL=http://localhost:8002" \
# -p 8000:8000 \
# -p 8443:8443 \
# -p 8001:8001 \
# -p 8444:8444 \
# -p 8002:8002 \
# -p 8445:8445 \
# -p 8003:8003 \
# -p 8004:8004 \
# kong-throttler

#-e KONG_LICENSE_DATA \

docker run -d  --name kong-gateway \
-e "KONG_ROLE=data_plane" \
-e "KONG_DATABASE=off" \
-e "KONG_VITALS=off" \
-e "KONG_CLUSTER_MTLS=pki" \
-e "KONG_CLUSTER_CONTROL_PLANE=${KONG_CLUSTER_CONTROL_PLANE}" \
-e "KONG_CLUSTER_SERVER_NAME=${KONG_CLUSTER_SERVER_NAME}" \
-e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${KONG_CLUSTER_TELEMETRY_ENDPOINT}" \
-e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${KONG_CLUSTER_TELEMETRY_SERVER_NAME}" \
-e "KONG_CLUSTER_CERT=${DATAPLANE_CERT}" \
-e "KONG_CLUSTER_CERT_KEY=${DATAPLANE_CERT_KEY}" \
-e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
-e "KONG_KONNECT_MODE=on" \
-e "KONG_CLUSTER_DP_LABELS=created-by:quickstart,type:docker-macOsArmOS" \
-e "KONG_ROUTER_FLAVOR=expressions" \
-p 8000:8000 \
-p 8443:8443 \
kong-throttler
# kong/kong-gateway:3.9

