#!/usr/bin/env bash
# learn-podman スタックを削除するヘルパー。
# 会社の組織ガバナンスで GuardDuty Runtime Monitoring が有効化されており、
# VPC を作るたびに次のリソースが自動付与され、CloudFormation の標準削除では消せない:
#   - VPC エンドポイント (com.amazonaws.<region>.guardduty-data)
#   - セキュリティグループ (GuardDutyManagedSecurityGroup-vpc-xxxxx)
# このスクリプトはそれらを先に掃除してから delete-stack を実行する。
#
# 使い方:
#   bash infra/destroy.sh
#   STACK_NAME=foo AWS_REGION=us-east-1 bash infra/destroy.sh

set -euo pipefail

STACK_NAME="${STACK_NAME:-learn-podman}"
REGION="${AWS_REGION:-ap-northeast-1}"

echo "== Stack: $STACK_NAME / Region: $REGION =="

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "スタック '$STACK_NAME' は存在しません。何もしません。"
  exit 0
fi

# スタックから VPC ID を取得
VPC_ID=$(aws cloudformation describe-stack-resource \
  --stack-name "$STACK_NAME" \
  --logical-resource-id Vpc \
  --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" \
  --output text 2>/dev/null || echo "")

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "VPC ID が取得できませんでした。GuardDuty リソース掃除はスキップして delete-stack のみ実行します。"
else
  echo "VPC ID: $VPC_ID"

  # 1. GuardDuty 関連 VPC エンドポイントを削除
  ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "VpcEndpoints[?contains(ServiceName, 'guardduty')].VpcEndpointId" \
    --output text)

  if [[ -n "$ENDPOINT_IDS" ]]; then
    echo "削除する VPC エンドポイント: $ENDPOINT_IDS"
    aws ec2 delete-vpc-endpoints \
      --vpc-endpoint-ids $ENDPOINT_IDS \
      --region "$REGION" >/dev/null
    echo "VPC エンドポイント削除リクエスト送信完了"
  else
    echo "削除対象の VPC エンドポイント無し"
  fi

  # 2. エンドポイント削除に伴う ENI の available 化を待つ
  echo "ENI のクリーンアップ待機 (30秒)..."
  sleep 30

  # 3. まだ残っている available な ENI を手動削除
  AVAILABLE_ENIS=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
    --region "$REGION" \
    --query "NetworkInterfaces[].NetworkInterfaceId" \
    --output text)

  if [[ -n "$AVAILABLE_ENIS" ]]; then
    echo "残存 ENI を削除: $AVAILABLE_ENIS"
    for eni in $AVAILABLE_ENIS; do
      aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" || true
    done
  fi

  # 4. GuardDuty 関連セキュリティグループを削除 (ENI が無くなってから)
  SG_IDS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "SecurityGroups[?starts_with(GroupName, 'GuardDuty')].GroupId" \
    --output text)

  if [[ -n "$SG_IDS" ]]; then
    echo "削除する GuardDuty SG: $SG_IDS"
    for sg in $SG_IDS; do
      aws ec2 delete-security-group --group-id "$sg" --region "$REGION" || true
    done
  else
    echo "削除対象の GuardDuty SG 無し"
  fi
fi

# 5. CloudFormation の削除を実行
echo "delete-stack 実行..."
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

echo "削除完了を待機 (最大15分)..."
if aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"; then
  echo "削除完了"
else
  echo ""
  echo "!! delete-stack が DELETE_FAILED で終了した可能性があります。"
  echo "!! GuardDuty が再付与した可能性もあるので、もう一度このスクリプトを実行してみてください:"
  echo "!!   bash infra/destroy.sh"
  exit 1
fi
