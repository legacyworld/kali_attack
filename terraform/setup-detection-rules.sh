#!/usr/bin/env bash
# セキュリティラボ環境（リソースグループ contoso-seclab-v2）用の検知ルールセットアップ。
#
# rule_id は lab-v2-* で統一している（terraform-legacy/ の旧ルール lab-* とは別物。
# 同じ Kibana デプロイ・スペースに対して実行しても旧ルールを上書きしない）。
#
# 使い方:
#   export ELASTIC_API_KEY="<Kibana/ES 共用の ApiKey (base64, id:api_key 形式)>"
#   export KIBANA_URL="https://<deployment>.kb.<region>.<cloud>.elastic.cloud"
#   ./setup-detection-rules.sh
#
# やること:
#   1. Elastic 提供の prebuilt detection rule 一式をインストール（未インストールの場合。
#      既にインストール済みなら何もしない＝既存環境に影響しない）
#   2. 攻撃チェーン用 (Kerberoasting) に必要な prebuilt rule を有効化
#   3. カスタムルールを作成（既存なら中身を更新）
#      - Password Spray → Successful Logon（シナリオ2相当。クエリは既存 lab-smb-bruteforce-success
#        と同一ロジック。source.ip 単位の「失敗の連続→成功」を見るだけでユーザー名を問わないため、
#        1ユーザー複数パスワード（Brute Force）でも複数ユーザー1パスワード（Password Spray）でも
#        そのまま発火する。クエリ変更は不要、rule_id のみ分離）
#      - Suspicious C2-like Domain Access（シナリオ4相当。periodic beacon にしても
#        ドメイン名ベースのマッチングなので変更不要）
#      - Lateral Movement（シナリオ5相当。変更不要）

set -euo pipefail

: "${ELASTIC_API_KEY:?ELASTIC_API_KEY を設定してください}"
: "${KIBANA_URL:?KIBANA_URL を設定してください}"

AUTH_HEADER="Authorization: ApiKey ${ELASTIC_API_KEY}"

echo "== 1. Prebuilt detection rule 一式をインストール =="
curl -s -X PUT "${KIBANA_URL}/api/detection_engine/rules/prepackaged" \
  -H "${AUTH_HEADER}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('rules_installed:', d.get('rules_installed'), '/ rules_updated:', d.get('rules_updated'))"

echo
echo "== 2. Kerberoasting 用の prebuilt rule を有効化 =="
# Newly Observed RC4 Kerberos Service Ticket Request
# event.code:4769 かつ TicketEncryptionType:0x17 (RC4) の TGS 要求を検知。
# svc-sql は RC4 のみ許可 (vm_ad.tf の create_svc_account) なので
# SPN discovery → GetUserSPNs.py -request の既定の RC4 要求がそのままこのルールに一致する。
curl -s -X PATCH "${KIBANA_URL}/api/detection_engine/rules" \
  -H "${AUTH_HEADER}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"rule_id": "57bc9e8d-9054-472c-9752-4aa91dc4cd49", "enabled": true}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name'), '-> enabled:', d.get('enabled'))"

echo
echo "== 3. カスタムルールを作成（既存なら更新） =="

create_or_update_rule() {
  local rule_id="$1"
  local body="$2"

  local existing
  existing=$(curl -s -G "${KIBANA_URL}/api/detection_engine/rules" \
    --data-urlencode "rule_id=${rule_id}" \
    -H "${AUTH_HEADER}" -H "kbn-xsrf: true")

  if echo "$existing" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'status_code' in d else 1)" 2>/dev/null; then
    echo "  [$rule_id] 新規作成"
    curl -s -X POST "${KIBANA_URL}/api/detection_engine/rules" \
      -H "${AUTH_HEADER}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print('  ->', d.get('name', d))"
  else
    echo "  [$rule_id] 既存を更新"
    curl -s -X PUT "${KIBANA_URL}/api/detection_engine/rules" \
      -H "${AUTH_HEADER}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print('  ->', d.get('name', d))"
  fi
}

# --- Password Spray → Successful Logon ---
# NTLM の失敗ログオン (4625) は TargetUserSid が常に S-1-0-0 になるため、
# Elastic 組み込みの "Multiple Logon Failure Followed by Logon Success"
# (not user.id:"S-1-0-0" を含む) は発火しない。S-1-0-0 を除外しない版。
# ユーザー名でフィルタしていないため、複数アカウントへの Password Spray でもそのまま発火する。
create_or_update_rule "lab-v2-smb-bruteforce-success" '{
  "rule_id": "lab-v2-smb-bruteforce-success",
  "name": "SMB Password Spray / Brute Force Followed by Successful Logon (Lab v2)",
  "description": "同一送信元からのネットワークログオン失敗が複数回続いた直後に成功ログオンが発生 (NTLM の TargetUserSid=S-1-0-0 制約を回避したラボ用カスタムルール。Password Spray [複数ユーザー×1パスワード] / Brute Force [1ユーザー×複数パスワード] どちらの構成でも発火する。攻撃シミュレーションラボ v2 用)",
  "severity": "medium",
  "risk_score": 47,
  "type": "eql",
  "language": "eql",
  "query": "sequence by winlog.computer_name, source.ip with maxspan=10s\n  [authentication where host.os.type == \"windows\" and event.action == \"logon-failed\" and winlog.logon.type : \"Network\" and source.ip != null and source.ip != \"127.0.0.1\" and source.ip != \"::1\"] with runs=5\n  [authentication where host.os.type == \"windows\" and event.action == \"logged-in\" and winlog.logon.type : \"Network\" and source.ip != null and source.ip != \"127.0.0.1\" and source.ip != \"::1\"]",
  "index": ["logs-system.security*", "logs-windows.forwarded*", "winlogbeat-*"],
  "interval": "5m",
  "from": "now-9m",
  "enabled": true,
  "tags": ["lab-v2", "password-spray", "brute-force", "SMB"]
}'

# --- プロキシ経由の不審通信 (C2 シミュレーション / periodic beacon) ---
# Squid のアクセスログ向け prebuilt rule が存在しないためカスタムで対応。
# ドメイン名ベースのマッチングなので、単発アクセスでも periodic beacon でも同じクエリで拾える。
create_or_update_rule "lab-v2-squid-suspicious-c2-domain" '{
  "rule_id": "lab-v2-squid-suspicious-c2-domain",
  "name": "Suspicious C2-like Domain Access via Squid Proxy (Lab v2)",
  "description": "Squid プロキシ経由で C2/malware/pastebin 等の不審なドメイン・パスへアクセスした (攻撃シミュレーションラボ v2 用カスタムルール。periodic beacon 構成でも同一アラートが複数回発火するため、Kibana 側で同一 rule.id の連続発火から beacon 間隔を確認できる)",
  "severity": "medium",
  "risk_score": 47,
  "type": "query",
  "language": "kuery",
  "query": "event.dataset:\"squid.log\" and (url.domain:(*malware* or *c2* or *pastebin*) or url.full:*suspicious*)",
  "index": ["logs-squid.log-*"],
  "interval": "5m",
  "from": "now-9m",
  "enabled": true,
  "tags": ["lab-v2", "C2", "Squid"]
}'

# --- ラテラルムーブメント ---
# WMI 経由のリモートコマンド実行は子プロセスが安定して観測できなかったため、
# 認証ベース (external-subnet = Kali 側からの成功ログオン) で検知する。
create_or_update_rule "lab-v2-smb-lateral-movement-from-attack-subnet" '{
  "rule_id": "lab-v2-smb-lateral-movement-from-attack-subnet",
  "name": "Successful SMB Logon to AD from Attack Subnet (Lab v2)",
  "description": "external-subnet (10.10.1.0/24、Kali 配置) から AD サーバーへの成功ネットワークログオン。ラテラルムーブメント/共有列挙・リモートコマンド実行 (nxc smb --shares / -x) を想定したラボ用カスタムルール。",
  "severity": "medium",
  "risk_score": 47,
  "type": "query",
  "language": "kuery",
  "query": "event.action:\"logged-in\" and winlog.logon.type:\"Network\" and host.os.type:\"windows\" and source.ip:10.10.1.0/24 and not user.name:*$",
  "index": ["logs-system.security*", "logs-windows.forwarded*", "winlogbeat-*"],
  "interval": "5m",
  "from": "now-9m",
  "enabled": true,
  "tags": ["lab-v2", "lateral-movement", "SMB"]
}'

echo
echo "完了。Kibana → Security → Rules で有効化状態を確認してください。"
