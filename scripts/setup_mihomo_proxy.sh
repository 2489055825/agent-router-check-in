#!/usr/bin/env bash
# 通过 mihomo 依次尝试多个机场订阅，在每个机场内部逐节点探测，
# 选出第一个真正能出网的节点作为签到代理。
#
# 环境变量:
#   PROXY_SUBSCRIPTION_URLS 订阅链接列表，一行一个，按顺序尝试（前一家不成换下一家）
#   PROXY_SUBSCRIPTION_URL  单个订阅链接（兼容旧用法，上面的变量为空时用它）
#   PROXY_REQUIRED          true 时全部机场都不通则退出 1
#   PROXY_PORT              本地 mixed-port，默认 7890
#   PROXY_CONTROL_PORT      mihomo 控制端口，默认 9090
#   PROXY_MAX_NODES         每家机场最多试几个节点，默认 12
#   PROXY_NODE_TIMEOUT      单个节点探测超时秒数，默认 6
#   PROXY_NODE_FILTER       只加载名称匹配该值的节点；留空则使用订阅里的全部节点
#
# 为什么不用 mihomo 的 url-test 组自动选节点：它的健康检查走 gstatic，
# 探测结果和「能不能连上目标站」并不总是一致——2026-10-04 那次它选中一个
# 连不上的节点，脚本据此判定代理不可用，签到直接失败了一整天。现在改成
# 自己逐个节点试，判据只有一个：代理出口 IP 与实际出口 IP 不同。

set -euo pipefail

# ---------- 参数 ----------
SUBS_RAW="${PROXY_SUBSCRIPTION_URLS:-${PROXY_SUBSCRIPTION_URL:-}}"
if [[ -z "${SUBS_RAW//[[:space:]]/}" ]]; then
	echo "[INFO] 未配置订阅链接，跳过代理配置"
	exit 0
fi

PROXY_DIR="${RUNNER_TEMP:-/tmp}/checkin-proxy"
PROXY_PORT="${PROXY_PORT:-7890}"
CONTROL_PORT="${PROXY_CONTROL_PORT:-9090}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.0}"
PROXY_REQUIRED="${PROXY_REQUIRED:-false}"
PROXY_MAX_NODES="${PROXY_MAX_NODES:-12}"
PROXY_NODE_TIMEOUT="${PROXY_NODE_TIMEOUT:-6}"
PROXY_NODE_FILTER="${PROXY_NODE_FILTER:-}"
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
CONTROL_URL="http://127.0.0.1:${CONTROL_PORT}"

# 这些机场都按 User-Agent 决定返回格式：装成 Clash 客户端才给 Clash YAML，
# 否则甩一份 base64 节点列表，mihomo 的 proxy-provider 解析不了（bixiny 对
# 陌生 UA 直接 403）。所以这里显式伪装，别删。
SUB_UA="${PROXY_SUB_UA:-clash-verge/v2.0.0}"

# 机场订阅里常夹着「剩余流量」「到期时间」这类假节点，试了也是白试。
INFO_NODE_PATTERN='流量|到期|剩余|官网|订阅|群组|重置|客服|续费|Expire|Traffic|Website|ExpireDate'

host_of() { sed -E 's|https?://([^/:]+).*|\1|' <<<"$1"; }

mkdir -p "${PROXY_DIR}"
cd "${PROXY_DIR}"

# ---------- 下载 mihomo ----------
echo "[INFO] Downloading mihomo ${MIHOMO_VERSION}..."
ARCHIVE="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
if ! curl --retry 3 --retry-delay 5 --retry-all-errors -fsSL -o "${ARCHIVE}" \
	"https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ARCHIVE}"; then
	echo "[WARN] Failed to download mihomo ${MIHOMO_VERSION}"
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi
gunzip -f "${ARCHIVE}"
chmod +x "mihomo-linux-amd64-${MIHOMO_VERSION}"
MIHOMO_BIN="${PROXY_DIR}/mihomo-linux-amd64-${MIHOMO_VERSION}"

# ---------- 直连出口 IP：判据基准 ----------
DIRECT_IP=$(curl -fsS -m 15 --noproxy '*' https://api.ipify.org 2>/dev/null || true)
echo "[INFO] 直连出口 IP: ${DIRECT_IP:-unknown}"

start_mihomo() { # $1=订阅链接 $2=编号
	local filter_line=''
	if [[ -n "${PROXY_NODE_FILTER}" ]]; then
		filter_line="    filter: \"${PROXY_NODE_FILTER}\""
	fi
	cat > config.yaml <<EOF
mixed-port: ${PROXY_PORT}
external-controller: 127.0.0.1:${CONTROL_PORT}
allow-lan: false
ipv6: false
mode: rule
log-level: info
unified-delay: true

proxy-providers:
  subscription:
    type: http
    url: "$1"
    interval: 3600
    path: ./subscription-$2.yaml
    header:
      User-Agent:
        - "${SUB_UA}"
${filter_line}

proxy-groups:
  - name: CHECKIN
    type: select
    use:
      - subscription

rules:
  - MATCH,CHECKIN
EOF
	nohup "${MIHOMO_BIN}" -d "${PROXY_DIR}" -f config.yaml >"mihomo.log" 2>&1 &
	echo $! >mihomo.pid
}

stop_mihomo() {
	if [[ -f mihomo.pid ]]; then
		kill "$(cat mihomo.pid)" 2>/dev/null || true
		rm -f mihomo.pid
	fi
	sleep 1
}

list_nodes() {
	# 只列真实节点：mihomo 在订阅还没加载出来时，组里只有 COMPATIBLE
	# 这类伪节点，直接拿来当节点列表会误判成「订阅已就绪」。
	curl -fsS --max-time 5 --noproxy '*' "${CONTROL_URL}/proxies/CHECKIN" 2>/dev/null |
		python3 -c '
import json, sys
PSEUDO = {"COMPATIBLE", "DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL"}
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for name in data.get("all") or []:
    if name not in PSEUDO:
        print(name)
' || true
}

select_node() { # $1=节点名
	local body
	body=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}))' "$1")
	curl -fsS --max-time 5 --noproxy '*' -X PUT -H 'Content-Type: application/json' \
		-d "${body}" "${CONTROL_URL}/proxies/CHECKIN" >/dev/null 2>&1 || true
}

probe_node() { # 走代理取出口 IP，失败输出空
	curl -fsS -m "${PROXY_NODE_TIMEOUT}" -x "${PROXY_URL}" https://api.ipify.org 2>/dev/null || true
}

# ---------- 依次尝试每个机场 ----------
FAILED_LIST=()
idx=0
# 用 while read 而不是 for：订阅链接里带 ? & 等字符，for 会做分词和通配符展开。
while IFS= read -r sub; do
	[[ -z "${sub//[[:space:]]/}" ]] && continue
	idx=$((idx + 1))
	SUB_HOST=$(host_of "${sub}")
	echo ""
	echo "[INFO] ===== 机场 #${idx} (${SUB_HOST}) ====="
	start_mihomo "${sub}" "${idx}"

	nodes=''
	for _ in $(seq 1 15); do
		nodes=$(list_nodes)
		if [[ -n "${nodes}" ]]; then
			break
		fi
		sleep 2
	done
	if [[ -z "${nodes}" ]]; then
		echo "[WARN] 机场 #${idx} (${SUB_HOST}): 订阅没拉到任何节点"
		tail -n 5 mihomo.log || true
		FAILED_LIST+=("${SUB_HOST}: 订阅拉不到节点")
		stop_mihomo
		continue
	fi

	tried=0
	hit=''
	while IFS= read -r node; do
		[[ -z "${node}" ]] && continue
		[[ "${node}" =~ ${INFO_NODE_PATTERN} ]] && continue
		tried=$((tried + 1))
		if ((tried > PROXY_MAX_NODES)); then
			echo "[INFO] 机场 #${idx} 已试满 ${PROXY_MAX_NODES} 个节点，不再往下试"
			break
		fi
		select_node "${node}"
		ip=$(probe_node)
		if [[ -n "${ip}" && "${ip}" != "${DIRECT_IP}" ]]; then
			echo "[SUCCESS] 机场 #${idx} (${SUB_HOST}) 节点「${node}」可用，出口 IP ${ip}"
			hit="${node}"
			break
		fi
		echo "[INFO] 机场 #${idx} 节点「${node}」不通（出口 IP: ${ip:-unknown}）"
	done <<<"${nodes}"

	if [[ -n "${hit}" ]]; then
		echo "[SUCCESS] Proxy is ready: ${PROXY_URL}（机场 #${idx} ${SUB_HOST} / ${hit}）"
		echo "[INFO] Proxy is scoped to CHECKIN_PROXY_URL (browser/python only, not global HTTP_PROXY)"
		if [[ -n "${GITHUB_ENV:-}" ]]; then
			echo "CHECKIN_PROXY_URL=${PROXY_URL}" >>"${GITHUB_ENV}"
		fi
		exit 0
	fi

	FAILED_LIST+=("${SUB_HOST}: 试了 ${tried} 个节点都不通")
	stop_mihomo
done <<<"${SUBS_RAW}"

# ---------- 全军覆没 ----------
echo ""
echo "[FAILED] ${idx} 家机场都没能出网"
for f in ${FAILED_LIST[@]+"${FAILED_LIST[@]}"}; do
	echo "[FAILED]   - ${f}"
done
tail -n 30 mihomo.log || true
stop_mihomo

if [[ "${PROXY_REQUIRED}" == "true" ]]; then
	echo "[ERROR] 代理不通，已中止本次签到（直连去签到只会撞上 WAF 的滑动验证，那个报错更难查）。"
	echo "[ERROR] 每家机场的失败原因见上面 [FAILED] 列表；全是「都不通」的话，多半是各家入口同时抽风，或本机（机房）IP 被封。"
	echo "[ERROR] 排查：在本机 Clash 里挨个切这几家订阅各连一次。都连不上就是机场侧问题，等恢复即可，不用改订阅地址。"
	echo "::error title=代理不通，签到未执行::${idx} 家机场全部不通，详见日志 [FAILED] 列表。"
	exit 1
fi
exit 0
