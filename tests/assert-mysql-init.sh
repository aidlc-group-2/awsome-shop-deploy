#!/bin/bash
# MySQL 初始化断言 — infra/VALIDATION.md 的自动化版本（CI 与 staging 通用）
# 前置：在仓库根目录、.env 已就位、mysql 容器已 healthy（docker compose up -d mysql --wait）
# 断言：4 schema 存在且 utf8mb4 / 应用账号对 4 schema 授权 / 应用账号（非 root）建表-插入-查询-删除往返
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ ! -f .env ]; then
    echo "ERROR: .env 不存在（cp .env.example .env）" >&2
    exit 1
fi
set -a
# shellcheck source=/dev/null
source .env
set +a

SCHEMAS="awsomeshop_auth awsomeshop_product awsomeshop_points awsomeshop_order"
FAILED=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

q_root() { docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e "$1" 2>/dev/null; }
q_app()  { docker compose exec -T mysql mysql -u"${MYSQL_APP_USER}" -p"${MYSQL_APP_PASSWORD}" -N -B -e "$1" 2>/dev/null; }

# ---------- 1. schema 存在 + 字符集 ----------
DBS=$(q_root "SHOW DATABASES;")
for s in $SCHEMAS; do
    if echo "$DBS" | grep -qx "$s"; then
        cs=$(q_root "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$s';")
        if [ "$cs" = "utf8mb4" ]; then
            pass "schema $s 存在且 utf8mb4"
        else
            fail "schema $s 字符集为 '$cs'（期望 utf8mb4）"
        fi
    else
        fail "schema $s 不存在"
    fi
done

# ---------- 2. 应用账号授权覆盖 4 schema ----------
GRANTS=$(q_root "SHOW GRANTS FOR '${MYSQL_APP_USER}'@'%';")
for s in $SCHEMAS; do
    if echo "$GRANTS" | grep -q "\`$s\`"; then
        pass "授权：${MYSQL_APP_USER} → $s"
    else
        fail "授权缺失：${MYSQL_APP_USER} → $s"
    fi
done

# ---------- 3. 应用账号（非 root）真实读写往返 ----------
for s in $SCHEMAS; do
    out=$(q_app "USE $s;
        CREATE TABLE __ci_check (id INT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(64));
        INSERT INTO __ci_check (note) VALUES ('round-trip');
        SELECT note FROM __ci_check WHERE id=1;
        DROP TABLE __ci_check;")
    if [ "$out" = "round-trip" ]; then
        pass "读写往返（建表/插入/查询/删除）：$s"
    else
        fail "读写往返失败：$s（输出：'$out'）"
    fi
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "== MySQL 初始化断言全部通过 =="
else
    echo "== 存在失败项 ==" >&2
fi
exit "$FAILED"
