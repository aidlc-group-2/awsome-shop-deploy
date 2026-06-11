#!/bin/bash
# AWSomeShop MySQL 初始化 — Unit 7
# 职责边界：仅创建空 schema 与授权，不创建任何业务表（业务表由各服务自行迁移）。
#
# 库名对齐各服务 application-docker.yml 的 DB_NAME 约定（下划线；注意 point 单数；gateway 亦有独立库）：
#   awsome_shop_auth（官方入口经 MYSQL_DATABASE 创建）
#   awsome_shop_product / awsome_shop_point / awsome_shop_order / awsome_shop_gateway（本脚本创建）
#
# 为什么用 .sh：引用 $MYSQL_USER 使授权用户与 .env 的 MYSQL_APP_USER 始终一致。
set -e

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS awsome_shop_product CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS awsome_shop_point   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS awsome_shop_order   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS awsome_shop_gateway CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

    GRANT ALL PRIVILEGES ON awsome_shop_product.* TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON awsome_shop_point.*   TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON awsome_shop_order.*   TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON awsome_shop_gateway.* TO '${MYSQL_USER}'@'%';
    FLUSH PRIVILEGES;
EOSQL

echo "AWSomeShop: 5 schemas ready (auth/product/point/order/gateway), granted to '${MYSQL_USER}'"
