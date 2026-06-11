# awsome-shop-deploy（Unit 7 · 基础设施/部署）

AWSomeShop 的一键编排环境：MySQL + API 网关 + 4 个业务微服务 + 前端，统一由 Nginx 对外。

## 目录结构

```
awsome-shop-deploy/
├── docker-compose.yml          # 编排：8 容器 + 网络 + 卷
├── .env.example                # 环境配置模板（复制为 .env 使用）
├── .gitignore                  # 排除真实 .env
├── .github/workflows/
│   └── validate.yml            # CI：push 即自动重放基础设施验证（VALIDATION.md 自动化）
├── nginx/
│   └── nginx.conf              # 静态资源 + /api 反代网关
├── mysql/
│   └── init/
│       └── 01-create-schemas.sh   # 仅建 4 个空 schema + 授权（不建表）
├── tests/
│   └── assert-mysql-init.sh    # MySQL 初始化断言（schema/授权/应用账号读写往返）
├── smoke/
│   └── smoke.sh                # 部署后冒烟链（分级探测，服务未就绪自动 SKIP）
└── cd/
    ├── deploy.sh               # CD：拉取各仓库最新 CI 全绿 commit 并部署（见 cd/README.md）
    ├── cd.env.example          # CD 可选配置（GitHub token / 群 webhook）
    └── systemd/                # timer + service（staging 上一次性安装）
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

## 自动部署（CD）

staging 上由 systemd timer 每 10 分钟执行 `cd/deploy.sh`：检查各服务仓库 main 的**最新 CI 全绿 commit**，有变更才构建替换该服务（失败隔离，旧容器不动），收尾跑冒烟链并将摘要发群。**CI 红 = staging 停在你上一个绿色版本，修绿即自动恢复。** 安装与日常操作见 `cd/README.md`。

## 自动验证（CI + 冒烟）

- **CI（`.github/workflows/validate.yml`）**：push/PR 自动跑——compose/nginx 语法 → shellcheck → 起真 MySQL 断言 4 schema/授权/应用账号读写往返（即 `infra/VALIDATION.md` 的自动重放）→ 改名应用账号回归。本仓库任何改动是否破坏底座，看 commit 旁的 ✅/❌ 即知。
- **冒烟链（`smoke/smoke.sh`）**：部署后在编排机上跑 `./smoke/smoke.sh`。分级探测：Tier 0 容器状态 → Tier 1 MySQL/schema → Tier 2 nginx 入口 → Tier 3 业务链（注册→JWT→查积分余额）。**未部署的服务自动 SKIP 不算失败**——队友服务每接入一个，对应 Tier 自动生效，零 SKIP 零 FAIL 即全栈闭环。设 `SMOKE_WEBHOOK_URL` 可将摘要推送到群机器人。

```bash
./smoke/smoke.sh                          # 本地/EC2 上，部署后执行
BASE_URL=http://localhost:8088 ./smoke/smoke.sh   # 经 SSM 端口转发从本机探测
```

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
| 前端产物 | **前端镜像最终阶段必须满足**：(1) 构建产物位于 `/app/dist`；(2) 镜像内含 `sh` 与 `cp`（基于 alpine/debian 等，**不可用 distroless**）。compose 的 `frontend` 容器复制产物到 `frontend-dist` 卷后退出，`nginx` 通过 `service_completed_successfully` 等其完成后再启动。 |
| 网关前缀 | Nginx 将 `/api/*` 剥离前缀后转发（`/api/auth/login → /auth/login`）；若网关保留 `/api`，改 nginx.conf 的 `proxy_pass` |
| 上传体积 | nginx 限 `client_max_body_size 10m`；网关(Spring Cloud Gateway)与 product-service 也需放宽到 ≥10m，否则大图上传中途 413 |

## 安全提示

- `.env` 含密钥，已在 `.gitignore` 排除，**切勿提交**。
- 业务服务端口默认不对宿主暴露，仅容器网络内可达；唯一入口是 Nginx:80。

## 对外演示（CDN）

workshop 交作业需要公开 URL 时，按 `infra/CDN-DEMO.md` 临时架设 CloudFront：
SG 仅放行 CloudFront 回源段 + nginx 秘密头守卫（`nginx/origin-guard/`，默认空目录不启用），
演示结束按文档第 6 节三步回收，恢复 SSM-only 零入站形态。
