import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";
import * as fs from "fs";
import * as path from "path";

/**
 * AWSomeShop Staging — 可重建定义（牛，不是宠物）
 *
 * 现役机器 i-0d1d69a9339074fef 是手动启动的，本 Stack 不 import 它；
 * 而是把"再造一台一模一样的 staging"代码化。切换时机：teardown / 换机型 /
 * 重建演练。新机器起来后 user-data 自动完成 Docker 引导 + 仓库克隆 +
 * CD timer 安装，几分钟后自治运行，无需登录配置。
 *
 * 与现役机器的对齐基准：infra/ACCESS.md + infra/user-data.sh。
 */
export class StagingStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const org = "aidlc-group-2";
    const deployRepo = `https://github.com/${org}/awsome-shop-deploy.git`;

    // 默认 VPC（现役机器所在；ACCESS.md：172.31.x / us-east-1）
    const vpc = ec2.Vpc.fromLookup(this, "DefaultVpc", { isDefault: true });

    // ---------- IAM：实例角色（对齐 ec2-trust-policy.json + SSM 托管策略）----------
    const role = new iam.Role(this, "StagingInstanceRole", {
      roleName: "awsomeshop-staging-instance-role",
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      description: "AWSomeShop staging: SSM-only access, no inbound",
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });

    // ---------- 安全组：零入站（SSM-only 安全形态的代码化）----------
    const sg = new ec2.SecurityGroup(this, "StagingSg", {
      vpc,
      securityGroupName: "awsomeshop-staging-sg",
      description: "AWSomeShop staging: no inbound rules, SSM only",
      allowAllOutbound: true, // 出站：GitHub 拉代码/查 Checks API、镜像仓库、dnf
    });
    // 刻意不加任何 ingress 规则

    // ---------- user-data：复用仓库脚本 + 追加 CD 自治装配 ----------
    // 第一段：与现役机器相同的引导（Docker/Compose/共享目录）—— 单一事实源
    const bootstrap = fs.readFileSync(
      path.join(__dirname, "..", "..", "user-data.sh"),
      "utf8",
    );
    // 第二段：现役机器上手动做过的事，代码化进引导（克隆 deploy 仓库 + 安装 CD timer）
    const cdSetup = `
# --- AWSomeShop: clone deploy repo & enable CD (idempotent) ---
install -d -o ec2-user -g docker -m 2775 /opt/awsomeshop
if [ ! -d /opt/awsomeshop/awsome-shop-deploy/.git ]; then
  sudo -u ec2-user git clone ${deployRepo} /opt/awsomeshop/awsome-shop-deploy
fi
ln -sf /opt/awsomeshop/awsome-shop-deploy/cd/systemd/awsomeshop-cd.service /etc/systemd/system/
ln -sf /opt/awsomeshop/awsome-shop-deploy/cd/systemd/awsomeshop-cd.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now awsomeshop-cd.timer
echo "AWSomeShop CD enabled" >> /var/log/awsomeshop-bootstrap.done
# 注意：.env / cd/cd.env 含密钥不入库，仍需人工放置一次（见 README）
`;
    const userData = ec2.UserData.custom(bootstrap + cdSetup);

    // ---------- EC2 实例（对齐 ACCESS.md：m8i.4xlarge / AL2023 / us-east-1a）----------
    const instance = new ec2.Instance(this, "Staging", {
      vpc,
      // 不钉死 AZ（现役机器恰在 us-east-1a，重建机任意 AZ 均可）
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: new ec2.InstanceType("m8i.4xlarge"),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({
        cpuType: ec2.AmazonLinuxCpuType.X86_64,
      }),
      role,
      securityGroup: sg,
      userData,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          // 6 个镜像构建 + mysql 卷 + 构建缓存的余量
          volume: ec2.BlockDeviceVolume.ebs(100, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
          }),
        },
      ],
      requireImdsv2: true,
      // 公网出站走 IGW（默认 VPC 无 NAT；零入站由 SG 保证）
      associatePublicIpAddress: true,
    });
    cdk.Tags.of(instance).add("Project", "awsomeshop");
    cdk.Tags.of(instance).add("Purpose", "staging");

    new cdk.CfnOutput(this, "InstanceId", {
      value: instance.instanceId,
      description: "SSM 目标：aws ssm start-session --target <此值>",
    });
    new cdk.CfnOutput(this, "SsmPortForward", {
      value: `aws ssm start-session --target ${instance.instanceId} --region ${this.region} --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["80"],"localPortNumber":["8088"]}'`,
      description: "本机访问 staging:80 的端口转发命令",
    });
  }
}
