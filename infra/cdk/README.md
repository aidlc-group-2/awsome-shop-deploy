# infra/cdk — Staging 的可重建定义（CDK）

> 策略：**现役机器不 import，用"可重建"代替"被收编"**。
> 现役 staging（`i-0d1d69a9339074fef`）是手动启动的宠物；本 Stack 把"再造一台
> 一模一样的 staging"代码化成牛。现役机器继续跑，**下一个自然重建时机**
> （活动结束 teardown / 换机型 / 重建演练）切到 CDK 启动的实例。

## Stack 内容（AwsomeshopStaging）

| 资源 | 关键属性 | 对齐来源 |
|------|----------|----------|
| EC2 Instance | m8i.4xlarge / AL2023 / 默认 VPC / gp3 100G 加密 / IMDSv2 强制 | `infra/ACCESS.md` |
| SecurityGroup | **零入站**，全量出站（GitHub/镜像仓库/dnf） | SSM-only 安全形态 |
| IAM Role + InstanceProfile | 仅 `AmazonSSMManagedInstanceCore` | `infra/ec2-trust-policy.json` |
| user-data | `infra/user-data.sh`（单一事实源，运行时读取拼接）+ CD 自治装配（克隆 deploy 仓库、安装并启用 `awsomeshop-cd.timer`） | `infra/user-data.sh` + `cd/` |

新机器启动后几分钟内自动：装 Docker/Compose → 克隆 deploy 仓库 → CD timer 开始
每 10 分钟自治部署。**唯一人工步骤**：放置两个含密钥的文件（不入库）：

```bash
# SSM 登录新机器后
cd /opt/awsomeshop/awsome-shop-deploy
cp .env.example .env && vi .env            # 强随机密钥
cp cd/cd.env.example cd/cd.env && vi cd/cd.env   # GITHUB_TOKEN / webhook（可选）
```

## 使用

```bash
cd infra/cdk
npm install

# 预览将创建什么（需要有权限的 AWS 凭证；账号需 cdk bootstrap 过）
npx cdk synth
npx cdk diff

# 创建新 staging（重建时机才执行；与现役机器并存，互不影响）
npx cdk deploy
# 输出含 InstanceId 和现成的 SSM 端口转发命令

# 切换完成后，旧机器手动终止；新机器 ID 同步到 infra/ACCESS.md 与
# infra/team-ssm-access-policy.json 的 instance ARN
```

## 边界与提醒

- **数据不迁移**：staging 数据按可抛设计（MySQL 卷 / 商品图片随旧机器走）。若需保留，重建前 `docker compose exec mysql mysqldump` 导出。
- **成员 SSM 策略要跟**：`team-ssm-access-policy.json` 把 instance ARN 写死了，切换后需更新策略中的实例 ID（这是该策略的已知耦合点）。
- **IAM 现存资产（组/策略/角色）不在本 Stack**：它们是另一类收编（`cdk import`），见 eric-todo-list G 板块，暂未做。
- 本目录的 `npx tsc --noEmit` 已纳入仓库 CI 习惯（手动跑）；synth/deploy 需要真实凭证，不进 GitHub Actions。
