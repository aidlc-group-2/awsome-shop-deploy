# 部署依赖清单（运行时外部组件 + 配置约定排查）

> 排查日期：2026-06-11　来源：各服务仓 `bootstrap/src/main/resources/application*.yml`、pom、源码
> 目的：在 `docker compose up` 之前明确每个服务真正需要的外部组件与配置约定，避免起来才发现缺东西。

## 一、外部组件总览（全栈需要的中间件）

| 组件 | 是否需要 | 说明 |
|------|---------|------|
| **MySQL 8.x** | ✅ 必须 | 5 个服务各有独立库；表由各服务 **Flyway** 启动时自动迁移 |
| **Redis** | ✅ 必须 | 5 个 Java 服务都配置了 `spring.data.redis`（缓存/会话等）|
| **AWS SQS** | ❌ 不需要 | `infrastructure/mq/sqs-impl` 是**空骨架**（仅 pom + .gitkeep，无代码无 Bean），代码中无 `@SqsListener`/发送调用 → 当前非运行时依赖 |
| S3 / 邮件 / Kafka / RabbitMQ / MongoDB / ES | ❌ 不需要 | 未发现任何引用 |
| 前端 | — | 纯静态构建产物，经 nginx 提供；只通过网关访问后端，无独立中间件依赖 |

**结论**：起全栈只需 **MySQL + Redis** 两个中间件。SQS 等都不需要。

## 二、各服务运行时约定（⚠️ 服务间不一致）

| 服务 | 容器端口 | DB 环境变量约定 | 默认库名 | Redis | 建表 |
|------|---------|----------------|---------|-------|------|
| auth | **8081** | `DB_HOST/DB_PORT/DB_NAME/DB_USERNAME/DB_PASSWORD` | `awsome_shop_auth` | REDIS_HOST/PORT | Flyway(3) |
| product | **8081** | `DB_*` | `awsome_shop_product` | REDIS_HOST/PORT | Flyway(3) |
| order | **8081** | `DB_*` | `awsome_shop_order` | REDIS_HOST/PORT | Flyway(2) |
| gateway | **8081** | `DB_*` | `awsome_shop_gateway` | REDIS_HOST/PORT | Flyway(1) |
| **points** | **8003** ⚠️ | `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` ⚠️ | `awsomeshop_points` ⚠️ | REDIS_HOST/PORT | Flyway(3) |

> 通用安全变量：`JWT_SECRET`、`ENCRYPTION_KEY`（auth/product/order/gateway 用 `DB_*` 系列时一并需要）。

## 三、⚠️ 会导致 `up` 失败的问题（需修复）

### P1. points 服务与其余四个完全不一致（最关键）
- 端口 **8003**（其余 8081）
- 用 `SPRING_DATASOURCE_*`（其余 `DB_*`）
- 库名 `awsomeshop_points`（其余 `awsome_shop_*` 下划线风格）

**影响**：当前 `docker-compose.yml` 已统一按 `DB_*` + `awsome_shop_point` + 8081 配置 points → **points 读不到这些变量，会回退默认值连 `awsomeshop_points`（空密码），起不来。**

**修复（二选一）**：
- (A) 在 compose 里**单独**给 points 配 `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` 指向 `awsomeshop_points`，并 init 脚本创建该库；
- (B) 推动 points 仓把 docker profile 改成与其余一致（`DB_*` + `awsome_shop_point` + 8081）。
- 推荐 (B) 统一风格；过渡期可先用 (A) 让它跑起来。

### P2. MySQL init 库名与 points 不匹配
当前 `mysql/init` 创建的是 `awsome_shop_{product,point,order,gateway}` + 官方入口的 `awsome_shop_auth`。
**缺少 points 实际要的 `awsomeshop_points`**（若走修复 A）。按最终对齐方案补齐对应库名。

### P3. 网关 docker profile 无路由（已知）
`routes` 与 `gateway.services.*` 仅在 `application-local.yml`；docker profile 缺失 → 容器内网关不转发。
**修复**：在 gateway 仓 `application-docker.yml` 补 `gateway.services.*`（指向 `http://<svc>:8081`，points 为 `http://points-service:8003`）+ routes + `auth.validate-url`。

### P4. order 下游地址未在 docker profile 配置
order 调用 product/points 的地址未在 docker profile 出现。
**修复**：在 order 仓 docker profile 补下游 URL（product `:8081`、points `:8003`）。

### P5. 端口不统一影响网关/nginx 上游
4 个服务 8081、points 8003。网关转发到 points 要用 `:8003`，nginx 上游到网关用 `:8081`。

## 四、最小可启动所需（按当前现实）

```
中间件：MySQL（含 5 个库：awsome_shop_auth/product/order/gateway + points 的 awsomeshop_points）
        Redis
环境变量：DB_*（auth/product/order/gateway）、SPRING_DATASOURCE_*（points）、
          REDIS_HOST/REDIS_PORT、JWT_SECRET、ENCRYPTION_KEY
建表：各服务 Flyway 自动迁移（无需手工建表，只需空库 + 授权）
```

## 五、与已实现状态的差距

- ✅ compose 已加 Redis；✅ MySQL 已就绪；✅ SQS 确认无需
- ❗ compose 对 points 的变量/端口/库名仍是错的（P1/P2）——下一步需修
- ❗ gateway 路由、order 下游（P3/P4）需在各自服务仓补 docker profile
