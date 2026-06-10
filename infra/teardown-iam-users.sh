#!/bin/bash
# AIDLC 活动结束后，统一删除临时 IAM 用户（aidlc_ 前缀）。
# 用法: bash teardown-iam-users.sh
set -euo pipefail

GROUP="awsomeshop-developers"

echo "将删除以下临时用户："
aws iam list-users --query "Users[?starts_with(UserName, 'aidlc_')].UserName" --output text
read -r -p "确认删除？(yes/no) " ANS
[ "$ANS" = "yes" ] || { echo "已取消"; exit 0; }

for U in $(aws iam list-users --query "Users[?starts_with(UserName, 'aidlc_')].UserName" --output text); do
  echo "--- 清理 $U ---"
  # 删除 access keys
  for K in $(aws iam list-access-keys --user-name "$U" --query "AccessKeyMetadata[].AccessKeyId" --output text); do
    aws iam delete-access-key --user-name "$U" --access-key-id "$K"
  done
  # 移出组
  aws iam remove-user-from-group --group-name "$GROUP" --user-name "$U" 2>/dev/null || true
  # 删除任何内联/附加策略（本方案未给用户直接挂策略，权限来自组）
  for P in $(aws iam list-attached-user-policies --user-name "$U" --query "AttachedPolicies[].PolicyArn" --output text); do
    aws iam detach-user-policy --user-name "$U" --policy-arn "$P"
  done
  # 删除用户
  aws iam delete-user --user-name "$U"
  echo "已删除 $U"
done

echo "全部临时用户已删除。"
echo "如需一并清理共享资源，可手动删除："
echo "  - IAM 组:   awsomeshop-developers"
echo "  - IAM 策略: arn:aws:iam::984072314535:policy/awsomeshop-ssm-access"
echo "  - EC2:      i-0d1d69a9339074fef (aws ec2 terminate-instances)"
