# 连接 AWSomeShop 集成机指南（发给团队）

> 你会单独收到一份属于你自己的 **AccessKeyId / SecretAccessKey**（请勿外传、勿提交到 Git）。
> 全程通过 AWS SSM 连接，机器不开放公网端口、无需 SSH 密钥。

## 机器信息

| 项 | 值 |
|----|----|
| Instance ID | `i-0d1d69a9339074fef` |
| 区域 Region | `us-east-1` |
| 账号 Account | `984072314535` |
| 机型 | m8i.4xlarge（16 vCPU / 64 GiB） |
| 已装 | Docker + Docker Compose v2 + git |
| 共享目录 | `/opt/awsomeshop` |

---

## 步骤 1：安装工具（一次性）

1. **AWS CLI v2**：https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
2. **Session Manager 插件**：https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

## 步骤 2：配置你的凭证（一次性）

```bash
aws configure
# AWS Access Key ID:     （填你收到的 AccessKeyId）
# AWS Secret Access Key: （填你收到的 SecretAccessKey）
# Default region name:   us-east-1
# Default output format:  json
```

验证身份：
```bash
aws sts get-caller-identity
```
能看到你的 `aidlc_xxx` 用户即配置成功。

## 步骤 3：登录机器

```bash
aws ssm start-session --target i-0d1d69a9339074fef --region us-east-1
```

进入后是 `ssm-user`（有免密 sudo，已在 docker 组）：
```bash
docker ps
cd /opt/awsomeshop
```
退出输入 `exit`。

## 步骤 4：联调时做端口转发（把机器端口映射到你本机）

```bash
# 例：网关 8080
aws ssm start-session --target i-0d1d69a9339074fef --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```
然后本机访问 `http://localhost:8080`。前端 3000 等其他端口同理（另开终端）。

---

## 常见问题

- **看不到目标/`TargetNotConnected`**：确认 region 是 `us-east-1`；确认用的是发给你的那把 key。
- **`docker` 提示权限**：用 `sudo docker ...`，或重连一次会话让 docker 组生效。
- **密钥泄露或丢失**：联系 Eric 重新轮换，不要自行新建。

> 工作方式：日常在**本机** docker-compose 开发，这台机器是**集成/演示**环境。请勿在共享目录里互相覆盖他人代码。
