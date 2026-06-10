#!/bin/bash
# AWSomeShop MySQL 初始化 — Unit 7
# 职责边界（Q5=C）：仅创建空 schema 与授权，不创建任何业务表。
# 业务表由各服务在启动时自行迁移（Flyway 优先 / JPA ddl-auto 备选）。
#
# 为什么用 .sh 而非 .sql：
#   .sql 初始化文件不做环境变量替换，会导致 GRANT 目标用户名被硬编码。
#   本脚本引用 $MYSQL_USER，使授权用户与 .env 的 MYSQL_APP_USER 始终一致，
#   即使有人修改了应用账号名也不会授权到不存在的用户。
#
# 说明：
#   - awsomeshop_auth 与应用账号由官方入口 (MYSQL_DATABASE/MYSQL_USER/MYSQL_PASSWORD) 自动创建并授权。
#   - 本脚本补建其余 3 个 schema，并把该账号权限扩展到这 3 个 schema。
set -e

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS awsomeshop_product CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS awsomeshop_points  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS awsomeshop_order   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

    GRANT ALL PRIVILEGES ON awsomeshop_product.* TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON awsomeshop_points.*  TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON awsomeshop_order.*   TO '${MYSQL_USER}'@'%';
    FLUSH PRIVILEGES;
EOSQL

echo "AWSomeShop: 4 schemas ready, granted to '${MYSQL_USER}'"
