# CI 接入指南（各服务仓库）

> 目标：让每个服务仓库 push 到 `main` 时自动跑 **测试 + docker 打包验证**，把绿/红写到 commit 上。
> staging 的自动部署（`cd/deploy.sh`）**只部署"最新 CI 全绿"的 commit**——你的 CI 红，staging 就停在你上一个绿色版本，修绿自动恢复。
>
> 适用仓库：`awsome-shop-auth-service` / `-product-service` / `-points-service` / `-order-service` / `-api-gateway`（Java）、`awsome-shop-frontend`（前端）。

---

## 为什么要接

| 不接 CI | 接了 CI |
|---------|---------|
| `deploy.sh` 默认 **SKIP 你的仓库**（除非临时 `ALLOW_NO_CI=true`）| 每次 push 自动验证，绿色才会被部署到 staging |
| 别人不知道你这版能不能编译/打包 | commit 旁有 ✅/❌，一眼可见 |
| 出问题在 staging 才暴露，互相牵连 | 问题在你自己仓库的 CI 阶段就拦截，失败隔离 |

CI 必须包含两件事：**① 编译 + 单元测试；② `docker build` 能成功出镜像**（因为 staging 就是 `docker compose build` 你的源码）。

---

## 一、Java 服务（Maven）

把下面文件放到你的服务仓库 `.github/workflows/ci.yml`（也可从 `cd/templates/ci-java.yml` 复制）：

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-test-package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
          cache: maven

      # ① 编译 + 单元测试
      - name: Maven test
        run: mvn -B -ntp clean verify

      # ② docker 打包验证（与 staging 的 docker compose build 等价）
      - name: Docker build
        run: docker build -t ${{ github.event.repository.name }}:ci .
```

要点：
- `mvn -B -ntp clean verify` 跑编译 + 测试（含 `test` 阶段）。没有测试也没关系，至少保证能编译打包。
- `docker build .` 验证你仓库根目录的 `Dockerfile` 能成功出镜像——**这步最关键**，因为 staging 部署就是 build 你的 Dockerfile。
- JDK 版本按你项目实际改（17/21）。

### Java 服务 Dockerfile 参考（多阶段构建）

如果你仓库还没有 `Dockerfile`，可参考 `cd/templates/Dockerfile.java`：

```dockerfile
# ---- build ----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B -ntp dependency:go-offline
COPY src ./src
RUN mvn -B -ntp clean package -DskipTests

# ---- run ----
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8001            # 改成你的服务端口：auth 8001 / product 8002 / points 8003 / order 8004 / gateway 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

> 端口、健康检查（建议暴露 `/actuator/health`）、DB 连接等以 deploy 仓 `README.md` 的「交接契约」为准。

---

## 二、前端（Node / Vite）

放到 `awsome-shop-frontend` 仓库 `.github/workflows/ci.yml`（或从 `cd/templates/ci-frontend.yml` 复制）：

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-test-package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm

      - name: Install
        run: npm ci

      # ① lint / 测试（按项目实际，没有可删）
      - name: Test
        run: npm test --if-present

      # ② 构建 + docker 打包验证
      - name: Build
        run: npm run build

      - name: Docker build
        run: docker build -t awsome-shop-frontend:ci .
```

> 前端镜像的交接契约（compose 里有写）：最终镜像内含构建产物目录 `/app/dist`，且含 `sh` 与 `cp`（基于 alpine/debian，**不要用 distroless**），以便一次性导出容器把产物复制到共享卷。

---

## 三、验证你接成功了

1. push 一个 commit 到 `main`
2. 仓库 **Actions** 标签页能看到 `ci` 运行
3. commit 列表里该 commit 旁出现 ✅（成功）或 ❌（失败）
4. 成功后，staging 下一轮（≤10 min）就会自动拉你这个绿色 commit 部署

确认命令（任意机器）：
```bash
gh run list --repo aidlc-group-2/awsome-shop-<your-service> --limit 5
```

---

## 四、常见问题

- **CI 里 `docker build` 失败但本地能跑**：多半是 `.dockerignore` 漏文件、或依赖没在镜像内重新拉取。确保 Dockerfile 自包含（不依赖本地已下载的东西）。
- **没有单元测试**：可以先只保证 `mvn -B clean package` / `npm run build` + `docker build` 通过；测试随后补。门禁要的是"能编译、能打包"。
- **CI 绿了但 staging 没更新**：等下一轮 timer（≤10 min）；或让 Eric 在 staging 手动 `sudo systemctl start awsomeshop-cd.service` 跑一轮。
- **过渡期想先让没 CI 的仓库也能部署**：Eric 在 `cd/cd.env` 设 `ALLOW_NO_CI=true`（全员接入后务必关掉）。

---

接入完成后，告诉 Eric 把 `cd/cd.env` 的 `ALLOW_NO_CI` 关掉，门禁即对全员生效。
