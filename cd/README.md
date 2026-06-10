# CD — 拉模式自动部署（deploy latest green）

> 一句话：staging 每 10 分钟检查各服务仓库 main 上**最新的 CI 全绿 commit**，
> 有变更才构建并替换该服务容器；红色 commit 机制上到不了 staging。

## 工作原理

```
队友 push → 各自仓库 CI（mvn test + docker build）→ 绿/红写在 commit 上
                                                        │
staging systemd timer（10min）→ deploy.sh
  ├─ ① git ls-remote 比对 HEAD（零 API 成本）→ 无变更 = 本轮静默结束
  ├─ ② 查 Checks API 取 main 最新绿色 sha → checkout（detached HEAD）
  ├─ ③ docker compose build <svc>（失败：源码回退、旧容器不动、群通知带日志尾部）
  ├─ ④ build 成功 → up -d 替换该服务容器
  └─ ⑤ 有变更才跑 smoke/smoke.sh 验收 + 群通知摘要
```

特性：

| 特性 | 说明 |
|------|------|
| 只部署绿色 | CI 没绿的 commit 不会进 staging；未接 CI 的仓库整体 SKIP（默认）|
| 失败隔离 | 单服务 build/up 失败不影响其他服务；该服务旧容器继续跑 |
| 幂等 + 防重叠 | 无变更零动作；flock 单实例锁防 build 超过 timer 周期 |
| 自更新 | deploy 仓库自身的变更也走绿色门禁，更新后用新脚本重新执行本轮 |
| 回滚 | `git -C ../awsome-shop-<svc> checkout <旧绿色sha> && docker compose up -d --build <svc>`，或临时停掉 timer 后手工操作 |
| 命名桥接 | org 仓库 `awsome-shop-gateway-service` 克隆为 compose 期望的 `awsome-shop-api-gateway` 目录（待命名统一后删除桥接）|

## 在 Staging EC2 上安装（一次性，SSM 登录后执行）

```bash
sudo ln -sf /opt/awsomeshop/awsome-shop-deploy/cd/systemd/awsomeshop-cd.service /etc/systemd/system/
sudo ln -sf /opt/awsomeshop/awsome-shop-deploy/cd/systemd/awsomeshop-cd.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now awsomeshop-cd.timer
```

可选配置（建议至少配 GITHUB_TOKEN 防限流）：

```bash
cp cd/cd.env.example cd/cd.env && vi cd/cd.env   # GITHUB_TOKEN / CD_WEBHOOK_URL
chmod 600 cd/cd.env
```

## 日常操作

```bash
systemctl list-timers awsomeshop-cd.timer      # 下次触发时间
sudo systemctl start awsomeshop-cd.service     # 手动立即跑一轮
journalctl -u awsomeshop-cd.service -n 50      # 查看最近一轮输出
cat cd/logs/deploy-history.log                 # 部署历史
ls cd/logs/                                    # 各服务构建日志（svc-sha.log）
sudo systemctl stop awsomeshop-cd.timer        # 暂停自动部署（联调关键期手工控制）
```

## 责任边界（给队友）

- **CI 红**：你仓库自己的问题，staging 停在你上一个绿色版本；修绿即自动恢复，无需找任何人
- **CI 绿但部署失败**（群里收到 ❌ 通知）：平台问题，找 Eric
- 部署成功与否、冒烟摘要都会进群，无需登录 staging
