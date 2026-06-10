#!/bin/bash
# AWSomeShop CD — 拉模式 gitops-lite（deploy latest green）
#
# 四个职责：
#   ① 绿色 sha 解析：问 GitHub Checks API "main 上最新 CI 全绿的 commit"
#   ② 部署：checkout 绿色 sha → 只 build 变更服务 → build 成功才替换容器（失败不传染）
#   ③ 由 systemd timer 周期触发（见 cd/systemd/）
#   ④ 反馈：有变更/失败才发群 webhook（含日志尾部）；每轮日志落 cd/logs/
#
# 设计要点：
#   - 幂等：无变更时一次 API 调用都不发（git ls-remote 比对，不耗配额），跑一万次无害
#   - 失败隔离：单服务 build 失败回退该服务源码、旧容器继续跑，不影响其他服务
#   - 无 CI 的仓库默认 SKIP（推动队友接入 ci-setup-guide），可用 ALLOW_NO_CI=true 放行
#   - 部署有变更时收尾跑 smoke/smoke.sh 验收
#
# 配置（可选）：cd/cd.env —— GITHUB_TOKEN / CD_WEBHOOK_URL / ALLOW_NO_CI（见 cd.env.example）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
DEPLOY_ROOT=$(pwd)
WORKSPACE=$(dirname "$DEPLOY_ROOT")
ORG="aidlc-group-2"
LOG_DIR="$DEPLOY_ROOT/cd/logs"
mkdir -p "$LOG_DIR"

if [ -f cd/cd.env ]; then
    set -a
    # shellcheck source=/dev/null
    source cd/cd.env
    set +a
fi
ALLOW_NO_CI="${ALLOW_NO_CI:-false}"

# 单实例锁：build 可能超过 timer 周期，防止重叠运行
exec 9>"$LOG_DIR/.lock"
flock -n 9 || { echo "已有部署进行中，本轮跳过"; exit 0; }

# compose 服务名 → GitHub 仓库名 / 本地目录名（= compose 的 build context）
# ⚠️ api-gateway：org 实际仓库为 awsome-shop-gateway-service，而 compose/设计文档写
#    awsome-shop-api-gateway——克隆时用"真实仓库名 → compose 期望的目录名"桥接，
#    命名统一后只需改这两行。
SERVICES=(auth-service api-gateway product-service points-service order-service frontend)
repo_of() {
    case "$1" in
        auth-service)    echo awsome-shop-auth-service ;;
        api-gateway)     echo awsome-shop-gateway-service ;;
        product-service) echo awsome-shop-product-service ;;
        points-service)  echo awsome-shop-points-service ;;
        order-service)   echo awsome-shop-order-service ;;
        frontend)        echo awsome-shop-frontend ;;
    esac
}
dir_of() {
    case "$1" in
        api-gateway) echo "$WORKSPACE/awsome-shop-api-gateway" ;;
        *)           echo "$WORKSPACE/$(repo_of "$1")" ;;
    esac
}

notify() {
    echo "$*"
    [ -n "${CD_WEBHOOK_URL:-}" ] || return 0
    curl -fs -m 5 -X POST "$CD_WEBHOOK_URL" -H 'Content-Type: application/json' \
        -d "{\"msg_type\":\"text\",\"content\":{\"text\":$(python3 -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$*")}}" \
        >/dev/null || true
}

gh_api() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fs -m 15 -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
    else
        curl -fs -m 15 "$1"
    fi
}

# ① 绿色 sha 解析：在本地 fetch 后的 origin/main 最近 10 个 commit 里，
#    找最新一个 check-runs 全部 success 的。
#    返回值：0=stdout 给出 sha；2=仓库无 CI；3=近 10 个无绿色；4=API 失败
green_sha() { # $1=仓库名 $2=本地目录
    local repo="$1" dir="$2" sha runs n ok
    while read -r sha; do
        runs=$(gh_api "https://api.github.com/repos/$ORG/$repo/commits/$sha/check-runs") || return 4
        n=$(echo "$runs" | jq -r '.total_count')
        if [ "$n" -eq 0 ]; then
            # 该 commit 无任何 check：视为仓库未接 CI（不再回溯——更老的也不会有）
            [ "$ALLOW_NO_CI" = "true" ] && { echo "$sha"; return 0; }
            return 2
        fi
        ok=$(echo "$runs" | jq -r '[.check_runs[].conclusion] | all(. == "success")')
        [ "$ok" = "true" ] && { echo "$sha"; return 0; }
    done < <(git -C "$dir" log origin/main --format=%H -10)
    return 3
}

# ---------- deploy 仓库自更新（基础设施变更也走绿色门禁）----------
self_update() {
    local remote local_sha green
    remote=$(git ls-remote -q origin main 2>/dev/null | cut -f1) || return 0
    local_sha=$(git rev-parse HEAD)
    [ -z "$remote" ] || [ "$remote" = "$local_sha" ] && return 0
    git fetch -q origin || return 0
    green=$(green_sha awsome-shop-deploy "$DEPLOY_ROOT") || return 0
    [ "$green" = "$local_sha" ] && return 0
    git checkout -q "$green" || return 0
    notify "🔄 CD：deploy 仓库已更新 ${local_sha:0:7} → ${green:0:7}，应用基础设施变更"
    docker compose up -d mysql >/dev/null 2>&1 || true
    docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 || true
    # 用新版脚本重新执行本轮（CD_SELF_UPDATED 防循环；flock fd 随 exec 保留）
    exec env CD_SELF_UPDATED=1 "$0"
}
[ -z "${CD_SELF_UPDATED:-}" ] && self_update

# ---------- 基础栈保底：mysql 必须在跑 ----------
docker compose up -d mysql >/dev/null 2>&1 || notify "❌ CD：mysql 拉起失败，本轮继续但服务可能起不来"

# ---------- ② 主循环：按构建顺序逐服务部署 ----------
CHANGED=()
FAILED=()
SKIPPED=()

for svc in "${SERVICES[@]}"; do
    repo=$(repo_of "$svc")
    dir=$(dir_of "$svc")

    # 首次：克隆（public 仓库走 https，零凭证）
    if [ ! -d "$dir/.git" ]; then
        if ! git clone -q "https://github.com/$ORG/$repo.git" "$dir" 2>/dev/null; then
            SKIPPED+=("$svc（仓库克隆失败）")
            continue
        fi
    fi

    # 零成本变更检测：remote HEAD 没动就什么都不做（不耗 API 配额）
    remote=$(git -C "$dir" ls-remote -q origin main 2>/dev/null | cut -f1)
    current=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)
    [ -n "$remote" ] && [ "$remote" = "$current" ] && continue

    git -C "$dir" fetch -q origin || { SKIPPED+=("$svc（fetch 失败）"); continue; }

    green=$(green_sha "$repo" "$dir")
    rc=$?
    if [ $rc -ne 0 ]; then
        case $rc in
            2) SKIPPED+=("$svc（未接 CI，见 ci-setup-guide）") ;;
            3) SKIPPED+=("$svc（main 近 10 个 commit 无绿色）") ;;
            *) SKIPPED+=("$svc（Checks API 失败）") ;;
        esac
        continue
    fi
    [ "$green" = "$current" ] && continue

    git -C "$dir" checkout -q "$green" || { SKIPPED+=("$svc（checkout 失败）"); continue; }

    buildlog="$LOG_DIR/$svc-${green:0:7}.log"
    if docker compose build "$svc" >"$buildlog" 2>&1; then
        if docker compose up -d "$svc" >>"$buildlog" 2>&1; then
            CHANGED+=("$svc @ ${green:0:7}")
        else
            FAILED+=("$svc @ ${green:0:7}（up 失败）")
            notify "❌ CD：$svc up 失败 @ ${green:0:7}（CI 绿但 staging 起不来 → 平台问题找 Eric）
$(tail -20 "$buildlog")"
        fi
    else
        # build 失败：源码回退到原 commit，旧容器不受影响
        git -C "$dir" checkout -q "$current" 2>/dev/null || true
        FAILED+=("$svc @ ${green:0:7}（build 失败）")
        notify "❌ CD：$svc build 失败 @ ${green:0:7}（CI 绿但 staging 烧不出 → 平台问题找 Eric）
完整日志：staging:$buildlog
$(tail -20 "$buildlog")"
    fi
done

# frontend 产物就绪且 nginx 未运行时，拉起 nginx（唯一对外入口）
if docker compose ps -a -q frontend 2>/dev/null | grep -q . && \
   ! docker compose ps -q nginx 2>/dev/null | grep -q .; then
    docker compose up -d nginx >/dev/null 2>&1 || true
fi

# ---------- ④ 收尾：有变更才验收+通知（无事发生则完全静默）----------
if [ ${#CHANGED[@]} -gt 0 ] || [ ${#FAILED[@]} -gt 0 ]; then
    smoke_out=$(./smoke/smoke.sh 2>&1 | tail -15 || true)
    status=$([ ${#FAILED[@]} -eq 0 ] && echo "✅" || echo "⚠️")
    msg="$status CD 部署轮次完成
已部署：${CHANGED[*]:-无}
失败：${FAILED[*]:-无}
跳过：${SKIPPED[*]:-无}
--- 冒烟摘要 ---
$smoke_out"
    notify "$msg"
    echo "$(date -Is) ${CHANGED[*]:-} | FAILED: ${FAILED[*]:-none}" >> "$LOG_DIR/deploy-history.log"
fi
exit 0
