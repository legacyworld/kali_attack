#!/usr/bin/env bash
# Elastic Cloud を作り直したときに、このラボの5シナリオでアラートが発火する状態まで
# 一括セットアップするスクリプト。
#
# 使い方:
#   export ELASTIC_API_KEY="<Kibana/ES 共用の ApiKey (base64, id:api_key 形式)>"
#   export KIBANA_URL="https://<deployment>.kb.<region>.<cloud>.elastic.cloud"
#   ./setup-detection-rules.sh
#
# やること:
#   1. Elastic 提供の prebuilt detection rule 一式をインストール（未インストールの場合）
#   2. シナリオ3 (Kerberoasting) に必要な prebuilt rule を有効化
#   3. シナリオ2・4・5 用のカスタムルールを作成（既存なら中身を更新）
#
# 前提: vm-ad / vm-squid に Elastic Agent が導入済みで、
#   logs-system.security* (Windows integration) / logs-squid.log* (Squid integration) に
#   データが入っていること。Elastic Agent のインストールはこのスクリプトでは行わない
#   （README.md の「初期設定」参照、手動作業）。

set -euo pipefail

: "${ELASTIC_API_KEY:?ELASTIC_API_KEY を設定してください}"
: "${KIBANA_URL:?KIBANA_URL を設定してください}"

AUTH_HEADER="Authorization: ApiKey ${ELASTIC_API_KEY}"

echo "== 1. Prebuilt detection rule 一式をインストール =="
curl -s -X PUT "${KIBANA_URL}/api/detection_engine/rules/prepackaged" \
  -H "${AUTH_HEADER}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('rules_installed:', d.get('rules_installed'), '/ rules_updated:', d.get('rules_updated'))"

echo
echo "== 2. シナリオ3 (Kerberoasting) 用の prebuilt rule を有効化 =="
# Newly Observed RC4 Kerberos Service Ticket Request
# event.code:4769 かつ TicketEncryptionType:0x17 (RC4) の TGS 要求を検知。
# svc-sql は RC4 のみ許可 (vm_ad.tf の create_svc_account) なので GetUserSPNs.py の
# 既定の RC4 要求がそのままこのルールに一致する。
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

# --- シナリオ2: AD ブルートフォース ---
# NTLM の失敗ログオン (4625) は TargetUserSid が常に S-1-0-0 になるため、
# Elastic 組み込みの "Multiple Logon Failure Followed by Logon Success"
# (not user.id:"S-1-0-0" を含む) は発火しない。S-1-0-0 を除外しない版。
create_or_update_rule "lab-smb-bruteforce-success" '{
  "rule_id": "lab-smb-bruteforce-success",
  "name": "SMB Brute Force Followed by Successful Logon (Lab)",
  "description": "同一送信元からのネットワークログオン失敗が複数回続いた直後に成功ログオンが発生 (NTLM の TargetUserSid=S-1-0-0 制約を回避したラボ用カスタムルール。攻撃シミュレーションラボ用)",
  "severity": "medium",
  "risk_score": 47,
  "type": "eql",
  "language": "eql",
  "query": "sequence by winlog.computer_name, source.ip with maxspan=10s\n  [authentication where host.os.type == \"windows\" and event.action == \"logon-failed\" and winlog.logon.type : \"Network\" and source.ip != null and source.ip != \"127.0.0.1\" and source.ip != \"::1\"] with runs=5\n  [authentication where host.os.type == \"windows\" and event.action == \"logged-in\" and winlog.logon.type : \"Network\" and source.ip != null and source.ip != \"127.0.0.1\" and source.ip != \"::1\"]",
  "index": ["logs-system.security*", "logs-windows.forwarded*", "winlogbeat-*"],
  "interval": "5m",
  "from": "now-9m",
  "enabled": true,
  "tags": ["lab", "brute-force", "SMB"]
}'

# --- シナリオ4: プロキシ経由の不審通信 (C2 シミュレーション) ---
# Squid のアクセスログ向け prebuilt rule が存在しないためカスタムで対応。
create_or_update_rule "lab-squid-suspicious-c2-domain" '{
  "rule_id": "lab-squid-suspicious-c2-domain",
  "name": "Suspicious C2-like Domain Access via Squid Proxy",
  "description": "Squid プロキシ経由で C2/malware/pastebin 等の不審なドメイン・パスへアクセスした (攻撃シミュレーションラボ用カスタムルール)",
  "severity": "medium",
  "risk_score": 47,
  "type": "query",
  "language": "kuery",
  "query": "event.dataset:\"squid.log\" and (url.domain:(*malware* or *c2* or *pastebin*) or url.full:*suspicious*)",
  "index": ["logs-squid.log-*"],
  "interval": "5m",
  "from": "now-9m",
  "enabled": true,
  "tags": ["lab", "C2", "Squid"]
}'

# --- シナリオ5: ラテラルムーブメント ---
# WMI 経由のリモートコマンド実行は子プロセスが安定して観測できなかったため、
# 認証ベース (external-subnet = Kali 側からの成功ログオン) で検知する。
create_or_update_rule "lab-smb-lateral-movement-from-attack-subnet" '{
  "rule_id": "lab-smb-lateral-movement-from-attack-subnet",
  "name": "Successful SMB Logon to AD from Attack Subnet (Lab)",
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
  "tags": ["lab", "lateral-movement", "SMB"]
}'

echo
echo "完了。Kibana → Security → Rules で有効化状態を確認してください。"
