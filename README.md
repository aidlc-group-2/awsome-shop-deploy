# awsome-shop-deploy（Unit 7 · 基础设施/部署）

AWSomeShop 的一键编排环境：MySQL + API 网关 + 4 个业务微服务 + 前端，统一由 Nginx 对外。

## 目录结构

```
awsome-shop-deploy/
├── docker-compose.yml          # 编排：8 容器 + 网络 + 卷
├── .env.example                # 环境配置模板（复制为 .env 使用）
├── .gitignore                  # 排除真实 .env
├── nginx/
│   └── nginx.conf              # 静态资源 + /api 反代网关
└── mysql/
    └── init/
        └── 01-create-schemas.sql  # 仅建 4 个空 schema + 授权（不建表）
```

> 各业务服务源码目录与本目录**同级**（Monorepo 风格摆放）：
> `../awsome-shop-auth-service`、`../awsome-shop-product-service`、`../awsome-shop-points-service`、`../awsome-shop-order-service`、`../awsome-shop-api-gateway`、`../awsome-shop-frontend`

## 快速开始（本机）

```bash
cp .env.example .env      # 填入强随机密钥
docker compose up -d --build
# 浏览器访问 http://localhost
```

常用命令：

```bash
docker compose ps                 # 查看状态
docker compose logs -f <service>  # 看日志
docker compose down               # 停止
docker compose down -v            # 停止并清空数据卷（⚠️ 删库 + 删图片）
```

## 在 Staging EC2 上运行（联调）

机器已预装 Docker / Compose（见 `infra/user-data.sh`），经 SSM 访问（见 `infra/ACCESS.md`、面向团队的 `infra/CONNECT.md`）：

```bash
# 1. SSM 登录后，在 /opt/awsomeshop 下准备好各仓库源码
# 2. docker compose up -d --build
# 3. 本机经 SSM 端口转发访问 80：
aws ssm start-session --target i-0d1d69a9339074fef --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["80"],"localPortNumber":["8088"]}'
# 然后访问 http://localhost:8088
```

> 本机与 EC2 共用同一份 compose，差异仅在 `.env`。

## 当前阶段限制

- **仅 Unit 7 就绪**：其余服务源码目录尚不存在，`up --build` 会在构建业务服务时失败（预期）。
- **现在可独立验证**：
  ```bash
  docker compose config                    # 校验 compose 语法
  docker compose up -d mysql               # 验证 4 schema + 账号创建
  docker run --rm -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine nginx -t
  ```
- 完整端到端验证留待"构建与测试"阶段（Units 1~6 就绪后）。

## 交接契约（供各服务遵守）

| 项 | 约定 |
|----|------|
| DB 连接 | `jdbc:mysql://mysql:3306/awsomeshop_<service>`（service ∈ auth/product/points/order）|
| DB 账号 | 取 `.env` 的 `MYSQL_APP_USER` / `MYSQL_APP_PASSWORD`（共享账号，默认 `awsomeshop`）|
| 建表 | 各服务自管：Flyway（优先）或 JPA `ddl-auto`（MVP）|
| 服务端口 | auth 8001 / product 8002 / points 8003 / order 8004 / gateway 8080（容器内）|
| 健康检查 | 建议暴露 `/actuator/health` |
| 图片存储 | product-service 挂载 `product-images` 卷于 `/app/uploads` |
| 前端产物 | frontend 镜像构建产物置于 `/app/dist`，由 compose 复制到 `frontend-dist` 卷供 nginx 提供 |
| 网关前缀 | Nginx 将 `/api/*` 剥离前缀后转发（`/api/auth/login → /auth/login`）；若网关保留 `/api`，改 nginx.conf 的 `proxy_pass` |

## 安全提示

- `.env` 含密钥，已在 `.gitignore` 排除，**切勿提交**。
- 业务服务端口默认不对宿主暴露，仅容器网络内可达；唯一入口是 Nginx:80。
