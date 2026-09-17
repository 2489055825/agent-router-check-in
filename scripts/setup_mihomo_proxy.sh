#!/usr/bin/env bash
# 通过 mihomo 拉取订阅、启动本地代理并探测可用节点。
# 环境变量:
#   PROXY_SUBSCRIPTION_URL  订阅链接（必填才启用）
#   PROXY_TEST_URL          探测目标，默认 https://www.google.com/generate_204
#   PROXY_REQUIRED          true 时探测失败则退出 1
#   PROXY_PORT              本地 mixed-port，默认 7890
#   PROXY_NODE_FILTER       只加载名称匹配该值的节点；留空则使用订阅里的全部节点

set -euo pipefail

if [[ -z "${PROXY_SUBSCRIPTION_URL:-}" ]]; then
	echo "[INFO] PROXY_SUBSCRIPTION_URL not set, skip proxy setup"
	exit 0
fi

PROXY_DIR="${RUNNER_TEMP:-/tmp}/checkin-proxy"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com/generate_204}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.0}"
PROXY_REQUIRED="${PROXY_REQUIRED:-false}"
PROXY_NODE_FILTER="${PROXY_NODE_FILTER:-}"

mkdir -p "${PROXY_DIR}"
cd "${PROXY_DIR}"

echo "[INFO] Downloading mihomo ${MIHOMO_VERSION}..."
ARCHIVE="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
if ! curl --retry 3 --retry-delay 5 --retry-all-errors -fsSL -o "${ARCHIVE}" \
	"https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ARCHIVE}"; then
	echo "[WARN] Failed to download mihomo ${MIHOMO_VERSION}, skip proxy setup"
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi
gunzip -f "${ARCHIVE}"
chmod +x "mihomo-linux-amd64-${MIHOMO_VERSION}"
MIHOMO_BIN="${PROXY_DIR}/mihomo-linux-amd64-${MIHOMO_VERSION}"

FILTER_LINE=''
if [[ -n "${PROXY_NODE_FILTER}" ]]; then
	FILTER_LINE="    filter: \"${PROXY_NODE_FILTER}\""
	echo "[INFO] Restricting proxy nodes by filter: ${PROXY_NODE_FILTER}"
fi

cat > config.yaml <<EOF
mixed-port: ${PROXY_PORT}
external-controller: 127.0.0.1:9090
allow-lan: false
ipv6: false
mode: rule
log-level: info
unified-delay: true

proxy-providers:
  subscription:
    type: http
    url: "${PROXY_SUBSCRIPTION_URL}"
    interval: 3600
    path: ./subscription.yaml
${FILTER_LINE}
    health-check:
      enable: true
      interval: 300
      url: https://www.gstatic.com/generate_204

proxy-groups:
  - name: CHECKIN
    type: url-test
    url: "${PROXY_TEST_URL}"
    interval: 300
    tolerance: 150
    lazy: false
    use:
      - subscription

rules:
  - MATCH,CHECKIN
EOF

echo "[INFO] Starting mihomo on 127.0.0.1:${PROXY_PORT}..."
nohup "${MIHOMO_BIN}" -d "${PROXY_DIR}" -f config.yaml > mihomo.log 2>&1 &
echo $! > mihomo.pid

PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
CONTROL_URL="http://127.0.0.1:9090"
SELECTED=''

# 等 url-test 组真正选出节点。初始值是内置的 COMPATIBLE（行为等同直连），
# 太早放行会让后续流量从 runner 本机 IP 出去，WAF 照样拦。
for attempt in $(seq 1 30); do
	SELECTED=$(curl -fsS --max-time 5 "${CONTROL_URL}/proxies/CHECKIN" 2>/dev/null \
		| sed -n 's/.*"now":"\([^"]*\)".*/\1/p' || true)
	if [[ -n "${SELECTED}" && "${SELECTED}" != "COMPATIBLE" && "${SELECTED}" != "DIRECT" ]]; then
		echo "[INFO] Proxy group selected node: ${SELECTED}"
		break
	fi
	echo "[INFO] Waiting for node selection (${attempt}/30)..."
	sleep 2
done

# 不能只测 google.com：runner 直连本来就能上 Google，会误判成成功。
# 真正的判据是「代理出口 IP 与直连出口 IP 不同」。
DIRECT_IP=$(curl -fsS -m 15 --noproxy '*' https://api.ipify.org 2>/dev/null || true)
PROXY_IP=$(curl -fsS -m 20 -x "${PROXY_URL}" https://api.ipify.org 2>/dev/null || true)
echo "[INFO] Selected node: ${SELECTED:-none}  Direct IP: ${DIRECT_IP:-unknown}  Proxy IP: ${PROXY_IP:-unknown}"

READY=false
if [[ -n "${PROXY_IP}" && "${PROXY_IP}" != "${DIRECT_IP}" ]]; then
	READY=true
fi

if [[ "${READY}" != "true" ]]; then
	echo "[FAILED] Proxy is not carrying traffic (selected=${SELECTED:-none}, direct=${DIRECT_IP:-unknown}, proxy=${PROXY_IP:-unknown})"
	tail -n 30 mihomo.log || true
	if [[ -f mihomo.pid ]]; then
		kill "$(cat mihomo.pid)" 2>/dev/null || true
	fi
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

echo "[SUCCESS] Proxy is ready: ${PROXY_URL}"
echo "[INFO] Proxy is scoped to CHECKIN_PROXY_URL (browser/python only, not global HTTP_PROXY)"
if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "CHECKIN_PROXY_URL=${PROXY_URL}" >> "${GITHUB_ENV}"
fi
