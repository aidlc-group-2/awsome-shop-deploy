# 连接 AWSomeShop 集成机指南（发给团队）

> 你会单独收到一份属于你自己的 **AccessKeyId / SecretAccessKey**（请勿外传、勿提交到 Git）。
> 访问方式二选一：
> - **方式 A：SSM Session Manager**（无 SSH，共享 ssm-user，适合快速调试）
> - **方式 B：SSH-over-SSM**（独立 Linux 账户，可真 ssh / VS Code Remote-SSH，推荐日常使用）
> 机器不开放公网端口。共享目录 `/opt/awsomeshop` 供团队共同部署使用。

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

## 方式 B：SSH-over-SSM（独立账户，推荐日常使用）

> 方式 A（SSM Session Manager）所有用户共享同一个 `ssm-user`，会互相干扰。
> 方式 B 给每个人分配独立的 Linux 账户、加入共享组，可真 ssh 登录、可 VS Code Remote-SSH。

### 前提：公钥（一次性）

每人需要生成或已有 SSH 公钥：
```bash
# 本机执行，生成 Ed25519 公钥（如已有可跳过）
ssh-keygen -t ed25519 -C "your-email@example.com"

# 打印公钥，复制发给 Eric（或直接发给 AI 代为配置）
cat ~/.ssh/id_ed25519.pub
```
**公钥不是机密，可以公开分享。** 拿到后请联系 Eric 开通。

### 步骤 1：本地 SSH 配置（一次性）

把以下内容追加到 `~/.ssh/config`：

```bash
# AWSomeShop staging EC2 over SSM Session Manager (SSH-over-SSM)
Host awsomeshop-staging
  HostName i-0d1d69a9339074fef
  User <你的Linux用户名>   # 例如 ericyan、yuanbo 等，开通后告知
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region us-east-1"
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
```

> **注意**：`User` 填开通后分给你的 Linux 用户名（不是 IAM 用户名）。目前已开通：Eric → `ericyan`。

### 步骤 2：SSH 登录

```bash
ssh awsomeshop-staging
```

登录后：
- 你是独立的 Linux 用户（不是共享的 ssm-user），有自己 `$HOME`
- 已加入 `docker` 组，docker 命令直接可用
- 已加入 `awsomedev` 组，`/opt/awsomeshop` 共享目录可写（组内文件互不影响）
- 所有成员共享 `/opt/awsomeshop` 目录部署，代码建议 clone 到各自 `$HOME` 下开发

### 步骤 3：VS Code 远程开发

1. VS Code 安装 **Remote - SSH** 扩展
2. 按 `Cmd+Shift+P` → `Remote-SSH: Connect to Host` → 选择 `awsomeshop-staging`
3. 打开 `$HOME` 或 `/opt/awsomeshop` 目录即可开发

---

## 常见问题

- **看不到目标/`TargetNotConnected`**：确认 region 是 `us-east-1`；确认用的是发给你的那把 key。
- **`docker` 提示权限**：用 `sudo docker ...`，或重连一次会话让 docker 组生效。
- **密钥泄露或丢失**：联系 Eric 重新轮换，不要自行新建。

> 工作方式：日常在**本机** docker-compose 开发，这台机器是**集成/演示**环境。请勿在共享目录里互相覆盖他人代码。
