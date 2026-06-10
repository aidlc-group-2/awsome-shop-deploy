# Unit 7 基础设施层验证记录

> 验证日期：2026-06-10
> 环境：Staging EC2 `i-0d1d69a9339074fef`（m8i.4xlarge，Amazon Linux 2023，us-east-1）
> 访问方式：AWS SSM（见 `ACCESS.md` / `CONNECT.md`）
> 范围：仅基础设施层（MySQL + Nginx 配置）。业务服务（auth/product/points/order/gateway/frontend）尚未产出，不在本次范围。

## 验证目标

在真实 EC2 上确认 Unit 7 底座可用：
1. MySQL 容器能启动并通过健康检查
2. 4 个业务 schema 正确创建
3. 共享应用账号对 4 个 schema 授权正确
4. Nginx 配置语法正确
5. 应用账号（非 root）能完成真实读写往返

---

## 步骤与结果

### 1. 启动 MySQL 并初始化

```bash
cd /opt/awsomeshop
cp .env.example .env   # 实际由机器生成强随机密钥，权限 600
docker compose --env-file .env up -d mysql
```

- 镜像：`mysql:8.4`
- 健康检查：`starting → healthy` ✅

```
NAMES              STATUS                    PORTS
awsomeshop-mysql   Up (healthy)   3306/tcp, 33060/tcp
```

### 2. Schema 创建（4 个）

`SHOW DATABASES;` 结果包含：

```
awsomeshop_auth      ← 官方入口 MYSQL_DATABASE 创建
awsomeshop_product   ┐
awsomeshop_points    ├ 由 mysql/init/01-create-schemas.sh 创建
awsomeshop_order     ┘
```

✅ 4 个 schema 全部存在（均 utf8mb4 / utf8mb4_unicode_ci）。

### 3. 应用账号授权

`SHOW GRANTS FOR 'awsomeshop'@'%';`

```
GRANT ALL PRIVILEGES ON `awsomeshop_auth`.*    TO `awsomeshop`@`%`
GRANT ALL PRIVILEGES ON `awsomeshop_product`.* TO `awsomeshop`@`%`
GRANT ALL PRIVILEGES ON `awsomeshop_points`.*  TO `awsomeshop`@`%`
GRANT ALL PRIVILEGES ON `awsomeshop_order`.*   TO `awsomeshop`@`%`
```

✅ 共享账号对 4 个 schema 均有 ALL PRIVILEGES。

### 4. Nginx 配置校验

```bash
docker run --rm -v /opt/awsomeshop/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:1.27-alpine nginx -t
```

```
nginx: configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

✅ 配置语法通过。

### 5. 应用账号连通性往返（非 root）

以 `MYSQL_APP_USER=awsomeshop` 连接 `awsomeshop_product`，建表 → 插入 → 查询 → 删除：

```
connected_as = awsomeshop@%
current_db   = awsomeshop_product
往返写入读取：id=1, note='connectivity check', created_at=2026-06-10 18:27:56
```

同一账号可访问其余 schema：

```
awsomeshop_auth   OK
awsomeshop_points OK
awsomeshop_order  OK
```

测试表已 `DROP`，schema 保持干净。✅

---

## 结论

Unit 7 基础设施底座在真机上功能性验证闭环。后端服务可按下列交接契约直接接入：

| 项 | 约定 |
|----|------|
| DB 连接 | `jdbc:mysql://mysql:3306/awsomeshop_<service>`（auth/product/points/order）|
| DB 账号 | `.env` 的 `MYSQL_APP_USER` / `MYSQL_APP_PASSWORD`（默认 `awsomeshop`）|
| 建表 | 各服务自管（Flyway 优先 / JPA ddl-auto 备选）|

## 待后续阶段验证（业务服务就绪后）

- `docker compose up -d --build` 全量构建 6 个业务服务镜像
- 经 Nginx:80 的端到端链路（前端 → /api 反代 → 网关 → 各服务）
- JWT 鉴权与跨服务调用
