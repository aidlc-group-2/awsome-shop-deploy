#!/bin/bash
# AWSomeShop 部署后冒烟链 — 分级探测，按服务在场情况自动 SKIP
#
# 设计：今天就能跑（只有 mysql 时仅 Tier 0/1 生效），队友服务每接入一个，
#       对应 Tier 自动从 SKIP 变成真实检查——无需随进度修改本脚本。
#   Tier 0  平台层：在场容器全部 running（且有健康检查的为 healthy）
#   Tier 1  数据层：mysql healthy + 4 schema 存在
#   Tier 2  入口层：nginx /healthz + SPA 首页（需 frontend 产物）
#   Tier 3  业务链：注册→拿 JWT→查积分余额（需 auth + gateway + points）
#
# 用法：在仓库根目录 ./smoke/smoke.sh
#   BASE_URL          入口地址（默认 http://localhost）
#   SMOKE_WEBHOOK_URL 可选；设置后将摘要 POST 到群机器人 webhook
# 退出码：0 = 无 FAIL（SKIP 不算失败）；1 = 存在 FAIL
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BASE_URL="${BASE_URL:-http://localhost}"
PASS_N=0; FAIL_N=0; SKIP_N=0
SUMMARY=""

# CloudFront 回源守卫（见 nginx.conf / infra/CDN-DEMO.md）：启用时本机 curl 会被 403，
# 从 guard.conf 提取秘密值，所有经 nginx 的请求带上 X-Origin-Guard 头。
GUARD_ARGS=()
if [ -f nginx/origin-guard/guard.conf ]; then
    GUARD_SECRET=$(grep -o '"[^"]*"' nginx/origin-guard/guard.conf | head -1 | tr -d '"')
    [ -n "$GUARD_SECRET" ] && GUARD_ARGS=(-H "X-Origin-Guard: $GUARD_SECRET")
fi

note() { echo "$1"; SUMMARY+="$1"$'\n'; }
pass() { note "PASS  $1"; PASS_N=$((PASS_N+1)); }
fail() { note "FAIL  $1"; FAIL_N=$((FAIL_N+1)); }
skip() { note "SKIP  $1"; SKIP_N=$((SKIP_N+1)); }

# 服务的容器 ID（不存在则输出空）
cid() { docker compose ps -a -q "$1" 2>/dev/null | head -1; }
# 容器状态 / 健康（docker inspect，不依赖 compose ps 的输出格式）
state()  { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null; }

# ---------- Tier 0 · 平台层 ----------
note "--- Tier 0 平台层 ---"
for svc in mysql auth-service product-service points-service order-service api-gateway nginx; do
    id=$(cid "$svc")
    if [ -z "$id" ]; then skip "$svc 未部署"; continue; fi
    st=$(state "$id"); hl=$(health "$id")
    if [ "$st" = "running" ] && { [ -z "$hl" ] || [ "$hl" = "healthy" ]; }; then
        pass "$svc running${hl:+ ($hl)}"
    else
        fail "$svc 状态异常：$st${hl:+ ($hl)}"
    fi
done
# frontend 是一次性导出容器：期望 exited(0)
id=$(cid frontend)
if [ -z "$id" ]; then
    skip "frontend 未部署"
else
    st=$(state "$id"); ec=$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null)
    if [ "$st" = "exited" ] && [ "$ec" = "0" ]; then
        pass "frontend 产物导出完成（exited 0）"
    elif [ "$st" = "running" ]; then
        pass "frontend 导出中（running）"
    else
        fail "frontend 异常：$st (exit=$ec)"
    fi
fi

# ---------- Tier 1 · 数据层 ----------
note "--- Tier 1 数据层 ---"
if [ -z "$(cid mysql)" ]; then
    skip "mysql 未部署，跳过数据层"
elif [ ! -f .env ]; then
    skip "无 .env，跳过 schema 检查"
else
    set -a; # shellcheck source=/dev/null
    source .env; set +a
    DBS=$(docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e "SHOW DATABASES;" 2>/dev/null)
    # 库名对齐 mysql/init/01-create-schemas.sh（下划线；point 单数；gateway 独立库）
    for s in awsome_shop_auth awsome_shop_product awsome_shop_point awsome_shop_order awsome_shop_gateway; do
        if echo "$DBS" | grep -qx "$s"; then pass "schema $s"; else fail "schema $s 缺失"; fi
    done
fi

# ---------- Tier 2 · 入口层 ----------
note "--- Tier 2 入口层 ---"
if [ -z "$(cid nginx)" ]; then
    skip "nginx 未部署，跳过入口层"
else
    code=$(curl -fso /dev/null -w '%{http_code}' --max-time 5 "${GUARD_ARGS[@]}" "$BASE_URL/healthz" || true)
    if [ "$code" = "200" ]; then pass "nginx /healthz → 200"; else fail "nginx /healthz → ${code:-超时}"; fi
    if [ -z "$(cid frontend)" ]; then
        skip "frontend 未部署，跳过 SPA 首页"
    else
        code=$(curl -fso /dev/null -w '%{http_code}' --max-time 5 "${GUARD_ARGS[@]}" "$BASE_URL/" || true)
        if [ "$code" = "200" ]; then pass "SPA 首页 → 200"; else fail "SPA 首页 → ${code:-超时}"; fi
    fi
fi

# ---------- Tier 3 · 业务链（注册→JWT→积分余额）----------
note "--- Tier 3 业务链 ---"
need_missing=""
for svc in nginx api-gateway auth-service points-service; do
    [ -z "$(cid "$svc")" ] && need_missing+=" $svc"
done
if [ -n "$need_missing" ]; then
    skip "业务链未就绪（缺:$need_missing）"
else
    DOMAIN="${EMAIL_DOMAIN_WHITELIST:-example.com}"; DOMAIN="${DOMAIN%%,*}"
    USER="smoke$(date +%s)"
    # 客户端路径按网关契约保留 /api 前缀（gateway-service-api.md：路由为 /api/v1/**）
    resp=""
    for _ in 1 2 3; do
        resp=$(curl -fs --max-time 10 "${GUARD_ARGS[@]}" -X POST "$BASE_URL/api/v1/public/auth/register" \
            -H 'Content-Type: application/json' \
            -d "{\"username\":\"$USER\",\"email\":\"$USER@$DOMAIN\",\"password\":\"Smoke123456\"}" ) && break
        sleep 5
    done
    if echo "$resp" | grep -Eq '"code"\s*:\s*"SUCCESS"'; then
        pass "注册（auth 经网关+nginx 全链路）"
        TOKEN=$(echo "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["token"])' 2>/dev/null || true)
        UID_=$(echo "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["userId"])' 2>/dev/null || true)
        if [ -n "$TOKEN" ]; then
            # ⚠️ 契约缺口：points 从 body 读 operatorId，而网关 OperatorIdInjectionFilter 注入的
            #    字段名是 userId —— 两仓字段名未对齐，已知问题。在对齐前显式传 operatorId。
            bal=$(curl -fs --max-time 10 "${GUARD_ARGS[@]}" -X POST "$BASE_URL/api/v1/public/point/balance/get" \
                -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
                -d "{\"operatorId\":\"${UID_:-0}\"}" || true)
            if echo "$bal" | grep -Eq '"code"\s*:\s*"SUCCESS"'; then
                pass "积分余额查询（points 经网关）"
            else
                fail "积分余额查询：${bal:-无响应}"
            fi
        else
            fail "注册响应无 token，无法继续业务链"
        fi
    else
        fail "注册失败：${resp:-无响应}"
    fi
fi

# ---------- 汇总 ----------
note "--- 汇总：PASS=$PASS_N FAIL=$FAIL_N SKIP=$SKIP_N ---"
if [ -n "${SMOKE_WEBHOOK_URL:-}" ]; then
    status=$([ "$FAIL_N" -eq 0 ] && echo "✅" || echo "❌")
    curl -fs --max-time 5 -X POST "$SMOKE_WEBHOOK_URL" -H 'Content-Type: application/json' \
        -d "{\"msg_type\":\"text\",\"content\":{\"text\":$(printf '%s staging 冒烟 PASS=%s FAIL=%s SKIP=%s\n%s' "$status" "$PASS_N" "$FAIL_N" "$SKIP_N" "$SUMMARY" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}}" \
        >/dev/null || true
fi
[ "$FAIL_N" -eq 0 ]
