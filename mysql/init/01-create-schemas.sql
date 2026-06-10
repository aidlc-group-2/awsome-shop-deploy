-- AWSomeShop MySQL 初始化 — Unit 7
-- 职责边界（Q5=C）：仅创建空 schema 与授权，不创建任何业务表。
-- 业务表由各服务在启动时自行迁移（Flyway 优先 / JPA ddl-auto 备选）。
--
-- 说明：
--  - awsomeshop_auth 与共享应用账号由官方入口 (MYSQL_DATABASE/MYSQL_USER/MYSQL_PASSWORD) 自动创建并授权。
--  - 本脚本补建其余 3 个 schema，并把共享账号的权限扩展到这 3 个 schema。
--  - 共享账号名假定为 'awsomeshop'（与 .env 的 MYSQL_APP_USER 保持一致）。

CREATE DATABASE IF NOT EXISTS awsomeshop_product CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS awsomeshop_points  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS awsomeshop_order   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

GRANT ALL PRIVILEGES ON awsomeshop_product.* TO 'awsomeshop'@'%';
GRANT ALL PRIVILEGES ON awsomeshop_points.*  TO 'awsomeshop'@'%';
GRANT ALL PRIVILEGES ON awsomeshop_order.*   TO 'awsomeshop'@'%';
FLUSH PRIVILEGES;
