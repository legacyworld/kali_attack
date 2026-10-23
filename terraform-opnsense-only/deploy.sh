#!/usr/bin/env bash
# OPNsense 単体環境の 2 ステップデプロイを一括実行する
#   使い方: ./deploy.sh [VHD ファイル]   (省略時は設定済み VHD)
# destroy でストレージごと消える前提のため、毎回 Step 1 → アップロード → Step 2 を行う。
set -euo pipefail
cd "$(dirname "$0")"

VHD="${1:-../terraform/opnsense-nano-configured.vhd}"
[ -f "$VHD" ] || { echo "VHD が見つかりません: $VHD" >&2; exit 1; }

# Step 1: ストレージ・Bastion 等（VHD URI は空で上書きして VM をスキップ）
terraform apply -var opnsense_vhd_uri=""

ACCOUNT=$(terraform output -raw opnsense_storage_account)
URI=$(terraform output -raw opnsense_vhd_uri)

# アップロード（既に同名 blob があれば上書き）
az storage blob upload \
  --account-name "$ACCOUNT" --container-name vhd --name opnsense.vhd \
  --type page --file "$VHD" --max-connections 8 --overwrite

# Step 2: OPNsense VM を作成。以降の plain apply でも VM が消えないよう URI を保存する
echo "opnsense_vhd_uri = \"$URI\"" > terraform.auto.tfvars
terraform apply
