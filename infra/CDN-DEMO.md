# CDN 对外演示端点（CloudFront → Staging EC2）

> 目的：workshop 交作业——评委/同学打开一个 CloudFront URL 即可访问 AWSomeShop。
> 原则：**演示期临时开放，期间安全降级可控（CloudFront IP 白名单 + 秘密头双闸），演示结束一键回收**。
> 操作人：Eric（需要本账号 CloudFront/EC2 权限的凭证）。

---

## 0. 方案选择（为什么这么做）

| 方案 | 说明 | 取舍 |
|------|------|------|
| **A. 公网回源 + 前缀列表 + 秘密头**（本文档采用） | CloudFront 回源走公网到 EC2:80；SG 只放行 CloudFront 回源 IP 段；nginx 校验秘密头拒绝伪装 | 配置最少，半小时上线；EC2 需有公网 IP（现役机器已有）；演示后可完整回收 |
| B. VPC origins（CloudFront ENI 直连私网） | 回源走 AWS 骨干网进 VPC ENI，EC2 可完全无公网入站 | 更优安全形态，但多一层资源（VPC origin + ENI + 专用 SG）；适合长期形态，演示场景偏重 |
| C. 直接给 EC2 开 80 到 0.0.0.0/0 | — | ❌ 否决：裸暴露源站 IP，无 HTTPS，无任何过滤 |

> 若 demo 后决定长期保留对外端点，再升级到 B（届时结合 infra/cdk 把它代码化）。

CloudFront 给我们的三样东西：`https://dxxxx.cloudfront.net` 域名 + **受信 HTTPS 证书**（自动）、
全球边缘接入、源站 IP 隐藏。它**不是打洞**：回源是普通公网 HTTP 请求，所以必须开 SG——
我们用两道闸控制开放面：

```
评委浏览器 ──HTTPS──> CloudFront 边缘
                        │ 回源 HTTP:80（带秘密头 X-Origin-Guard）
                        ▼
            SG 闸门①：仅放行 CloudFront 回源 IP 段（托管前缀列表）
                        ▼
            nginx 闸门②：无秘密头一律 403（防"别人也建分发指向我们 IP"）
                        ▼
                  现有 Nginx:80 → 网关 → 服务
```

---

## 1. 前置确认（5 分钟）

```bash
# 1) 实例有公网 IP（CloudFront 公网回源需要）
aws ec2 describe-instances --instance-ids i-0d1d69a9339074fef --region us-east-1 \
  --query 'Reservations[0].Instances[0].{PublicDns:PublicDnsName,PublicIp:PublicIpAddress,SG:SecurityGroups}'
# 记下 PublicDnsName（形如 ec2-x-x-x-x.compute-1.amazonaws.com）和 SG ID

# 2) CloudFront 回源前缀列表 ID（us-east-1）
aws ec2 describe-managed-prefix-lists --region us-east-1 \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].{Id:PrefixListId,Name:PrefixListName}'
# 记下 pl-xxxxxxxx
```

> ⚠️ **SG 规则配额**：CloudFront 托管前缀列表权重为 55 条规则（默认配额 60/SG）。
> 如果现有 SG 规则较多，放不下就为演示新建一个专用 SG 附加到实例（步骤 2 备选）。

---

## 2. 闸门①：安全组放行 CloudFront 回源段（2 分钟）

```bash
SG_ID=<上一步的SG>      # 或新建演示专用 SG 后 attach
PL_ID=<pl-xxxxxxxx>

aws ec2 authorize-security-group-ingress --region us-east-1 \
  --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$PL_ID,Description=cloudfront-origin-facing-DEMO}]"
```

效果：80 端口只对 CloudFront 回源节点开放，公网扫描不可达。**Description 里的
`DEMO` 标记是回收时的定位锚点。**

---

## 3. 闸门②：nginx 秘密头守卫（5 分钟，SSM 登机执行）

仓库已预埋挂载点（`nginx/origin-guard/` → 容器 `/etc/nginx/origin-guard/`，
目录为空时不启用、本地开发无感）。演示前现场生成守卫配置：

```bash
cd /opt/awsomeshop/awsome-shop-deploy && git pull
GUARD=$(openssl rand -hex 24) && echo "GUARD=$GUARD"   # 记下，步骤 4 要用
cat > nginx/origin-guard/guard.conf <<EOF
# 演示期回源守卫：仅放行携带 CloudFront 秘密头的请求（DEMO 结束删除本文件）
if (\$http_x_origin_guard != "$GUARD") { return 403; }
EOF
docker compose exec nginx nginx -t && docker compose restart nginx
# 自检：机上直接访问应 403，带头应 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/healthz                       # 期望 403
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Origin-Guard: $GUARD" http://localhost/healthz  # 期望 200
```

> guard.conf 已在 .gitignore，不会被误提交；CD 的 git pull 也不会覆盖它。

---

## 4. 创建 CloudFront 分发（10 分钟）

```bash
PUBLIC_DNS=<步骤1的PublicDnsName>
GUARD=<步骤3的GUARD值>

cat > /tmp/cf-demo.json <<EOF
{
  "CallerReference": "awsomeshop-demo-$(date +%s)",
  "Comment": "AWSomeShop workshop demo (TEMPORARY - tear down after demo)",
  "Enabled": true,
  "Origins": { "Quantity": 1, "Items": [ {
    "Id": "staging-ec2",
    "DomainName": "$PUBLIC_DNS",
    "CustomOriginConfig": {
      "HTTPPort": 80, "HTTPSPort": 443,
      "OriginProtocolPolicy": "http-only",
      "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 5
    },
    "OriginCustomHeaders": { "Quantity": 1, "Items": [
      { "HeaderName": "X-Origin-Guard", "HeaderValue": "$GUARD" } ] }
  } ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "staging-ec2",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": { "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] } },
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
    "Compress": true
  }
}
EOF
aws cloudfront create-distribution --distribution-config file:///tmp/cf-demo.json \
  --query 'Distribution.{Id:Id,Domain:DomainName,Status:Status}'
rm -f /tmp/cf-demo.json   # 含秘密头，用完即删
```

两个托管策略 ID 的含义（CloudFront 内置，全账号通用）：

| ID | 名称 | 为什么用它 |
|----|------|-----------|
| `4135ea2d-6df8-44a3-9df3-4b5a84be39ad` | **CachingDisabled** | 商城是动态应用（积分/库存/订单实时变化），演示期间全程不缓存，避免"改了数据页面不动"的调试灾难 |
| `b689b0a8-53d0-40ab-baf2-68738e2966ac` | **AllViewerExceptHostHeader** | 把 JWT 的 `Authorization` 头、cookies、query 全部透传给源站；**剔除 Host 头**是关键——否则 nginx 收到 cloudfront.net 的 Host 一些场景会出问题，且这是 AllViewer+ 自定义源站的经典 403 坑 |

> 缓存全关意味着 CloudFront 在这里只当"HTTPS 门面 + 接入层"，不当缓存——demo 场景的正确取舍。
> 若想给静态资源提速，可后续对 `/assets/*` 加一条单独的缓存行为，演示前不必做。

部署需 5~15 分钟（Status: InProgress → Deployed）：

```bash
aws cloudfront wait distribution-deployed --id <分发ID>
```

---

## 5. 验收（演示前一天做完）

```bash
CF_URL=https://<dxxxx.cloudfront.net>

curl -s -o /dev/null -w '%{http_code}\n' $CF_URL/healthz        # 期望 200（CloudFront 带秘密头进来）
curl -s -o /dev/null -w '%{http_code}\n' http://$PUBLIC_DNS/healthz  # 期望 超时/拒绝（SG 闸门生效，普通公网进不来）
# 业务链（服务就绪后）：
curl -s $CF_URL/api/v1/public/auth/login -X POST -H 'Content-Type: application/json' -d '{}' # 期望返回业务错误 JSON 而非 403/502
```

浏览器打开 `$CF_URL`：SPA 加载 → 注册/登录 → 浏览商品 → 兑换。
**移动端也顺手测一下**（评委可能用手机开）。

### 已知边界

- **WebSocket**：CloudFront 支持，但如有长连接功能需确认网关侧超时（默认 OriginReadTimeout 60s 已放宽）。
- **大图上传**：链路上 nginx/网关已放宽 10m；CloudFront 默认请求体上限远大于此，不构成新瓶颈。
- **EC2 重启 = 公网 DNS 变**：现役机器若 stop/start，PublicDnsName 会变，需更新分发的 Origin。演示周内**不要 stop 实例**（reboot 不变）。

---

## 6. 演示结束回收（10 分钟，三步逆序）

```bash
# 1) 禁用并删除分发（disable 后需等部署完成才能 delete）
aws cloudfront get-distribution-config --id <分发ID> > /tmp/cf.json
# 把 Enabled 改 false 后 update-distribution，等 Deployed，然后：
aws cloudfront delete-distribution --id <分发ID> --if-match <ETag>

# 2) 移除 SG 规则（按 DEMO 描述定位）
aws ec2 revoke-security-group-ingress --region us-east-1 --group-id $SG_ID \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$PL_ID}]"

# 3) 删除 nginx 守卫，恢复纯内网形态
rm /opt/awsomeshop/awsome-shop-deploy/nginx/origin-guard/guard.conf
docker compose restart nginx
```

回收后回到 SSM-only 零入站形态。**把"已回收"记一笔到 plan 仓库的 audit（NFR 变更闭环）。**

---

## 附：这件事的 NFR 定位（留档）

对外暴露是一条 NFR 变更：安全边界从「SSM-only 零入站」临时演进为「CloudFront 受限回源双闸」，
触发原因 = workshop 交作业的演示需求，生命周期 = 演示期，回收标准 = 本文档第 6 节。
按 AI-DLC 纪律，该决策应同步回写 plan 仓库 `infrastructure-design.md`（todo B 板块的回写项一并做）。
