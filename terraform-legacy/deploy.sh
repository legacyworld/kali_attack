#!/usr/bin/env bash
# ラボ環境全体の 2 ステップデプロイを一括実行する
#   使い方: ./deploy.sh [VHD ファイル]   (省略時は設定済み nano VHD)
# OPNsense VHD は設定込みで保存したものを使う（再設定不要。LAN の IP 10.10.2.4/24 も入っている v2）。
# ストレージに置きっぱなしにしない運用のため、毎回 Step 1 → アップロード → Step 2 を行う。
set -euo pipefail
cd "$(dirname "$0")"

VHD="${1:-./opnsense-nano-configured.vhd}"
[ -f "$VHD" ] || { echo "VHD が見つかりません: $VHD" >&2; exit 1; }

# Step 1: ストレージ・Bastion・AD・Squid・Kali 等（VHD URI は空で上書きして OPNsense VM をスキップ）
terraform apply -var opnsense_vhd_uri=""

ACCOUNT=$(terraform output -raw opnsense_storage_account)
URI=$(terraform output -raw opnsense_vhd_uri)

# アップロード（既に同名 blob があれば上書き）
az storage blob upload \
  --account-name "$ACCOUNT" --container-name vhd --name opnsense.vhd \
  --type page --file "$VHD" --max-connections 8 --overwrite

# Step 2: OPNsense VM を作成。以降の plain apply でも VM が消えないよう URI を保存する
# （terraform.auto.tfvars の機密変数とは別ファイル。*.tfvars は git 管理外）
echo "opnsense_vhd_uri = \"$URI\"" > opnsense.auto.tfvars
terraform apply
