# AWSomeShop 集成机（Staging EC2）访问指南

> 访问方式：**AWS Systems Manager (SSM) Session Manager**，无需 SSH 端口、无需密钥。
> 安全组无任何入站规则，机器不暴露在公网。

## 机器信息

| 项 | 值 |
|----|----|
| 用途 | 集成 / 演示环境（本地开发，联调上这台） |
| Instance ID | `i-0d1d69a9339074fef` |
| 机型 | m8i.4xlarge（16 vCPU / 64 GiB） |
| 区域 | us-east-1（可用区 us-east-1a） |
| 账号 | 984072314535 |
| 私网 IP | 172.31.4.33（默认 VPC） |
| 操作系统 | Amazon Linux 2023 |
| 已装环境 | Docker 25.x、Docker Compose v2.39.4、git |
| 共享目录 | `/opt/awsomeshop`（docker 组可写） |

---

## 一、管理员（Eric）一次性操作：给成员授权

每个成员需要在账号 `984072314535` 有 IAM 用户。把他们加入开发组即可获得访问权限（组已绑定最小权限策略 `awsomeshop-ssm-access`）：

```bash
aws iam add-user-to-group --group-name awsomeshop-developers --user-name <成员IAM用户名>
```

> 已创建资源：IAM 组 `awsomeshop-developers`、托管策略 `awsomeshop-ssm-access`
> （仅允许对本实例发起 SSM 会话与端口转发，并管理自己的会话）。

---

## 二、成员本机一次性安装

1. **AWS CLI v2**：https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
2. **Session Manager 插件**：https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
3. **配置凭证**（用自己的 IAM Access Key）：
   ```bash
   aws configure
   # Region 填 us-east-1
   ```
   验证：
   ```bash
   aws sts get-caller-identity
   ```

---

## 三、登录机器（交互式 Shell）

```bash
aws ssm start-session --target i-0d1d69a9339074fef --region us-east-1
```

进入后默认是 `ssm-user`（有免密 sudo，且已在 docker 组）：

```bash
docker ps
cd /opt/awsomeshop
```

退出：`exit`。

---

## 四、端口转发（在本机访问机器上的服务）

联调时把机器上的应用端口映射到自己电脑，无需开放安全组。例如把网关 8080、前端 3000 映射到本地：

```bash
# 网关 8080
aws ssm start-session \
  --target i-0d1d69a9339074fef --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'

# 前端 3000（另开一个终端）
aws ssm start-session \
  --target i-0d1d69a9339074fef --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

然后本机浏览器访问 `http://localhost:8080` / `http://localhost:3000`。

---

## 五、常见问题

- **`TargetNotConnected` / 看不到机器**：实例已注册 SSM（PingStatus Online）。确认你的 Region 是 us-east-1，且 IAM 用户已加入 `awsomeshop-developers` 组。
- **`docker` 权限不足**：用 `sudo docker ...`，或重新登录会话使 docker 组生效。
- **想用 VS Code 远程开发**：可走 SSM 隧道做 Remote-SSH（需额外配置 SSH key + ProxyCommand），按需再加。
- **成本控制**：不用时停机
  ```bash
  aws ec2 stop-instances --instance-ids i-0d1d69a9339074fef --region us-east-1
  aws ec2 start-instances --instance-ids i-0d1d69a9339074fef --region us-east-1
  ```
  （停机后重启私网 IP 可能变化，SSM 访问不受影响。）

---

## 已创建的 AWS 资源清单

| 资源 | 名称 / ID |
|------|-----------|
| EC2 实例 | `i-0d1d69a9339074fef` (awsomeshop-staging) |
| IAM 角色（实例） | `awsomeshop-ec2-ssm-role`（含 AmazonSSMManagedInstanceCore） |
| 实例配置 | `awsomeshop-ec2-ssm-profile` |
| 安全组 | `sg-04fa5f80999a9b49b`（awsomeshop-staging-sg，无入站） |
| IAM 组 | `awsomeshop-developers` |
| IAM 策略 | `awsomeshop-ssm-access` |
