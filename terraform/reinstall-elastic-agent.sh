#!/usr/bin/env bash
# Fleet 上の既存 Elastic Agent を登録解除し、各 VM に Elastic Agent を入れ直す
#   Linux (vm-squid / vm-kali) -> Agent policy: security_attack_similate
#   Windows (vm-ad)            -> Agent policy: security_attack_AD
# 使い方: ./reinstall-elastic-agent.sh   (fleet.env が必要。fleet.env.example 参照 / az login 済み)
# VM へは Bastion ではなく az vm run-command invoke (Azure 管理プレーン経由) で実行する。
set -euo pipefail
cd "$(dirname "$0")"

[ -f fleet.env ] || { echo "fleet.env がありません (cp fleet.env.example fleet.env して編集)" >&2; exit 1; }
envval() { { grep -E "^$1=" fleet.env || true; } | tail -n1 | cut -d= -f2- | sed -E "s/^[\"']|[\"']\$//g"; }
KIBANA_URL=$(envval KIBANA_URL); KIBANA_URL=${KIBANA_URL%/}
KIBANA_API_KEY=$(envval KIBANA_API_KEY)
RG=${RG:-contoso-seclab-v2}
LINUX_POLICY=$(envval LINUX_AGENT_POLICY_NAME); LINUX_POLICY=${LINUX_POLICY:-security_attack_similate}
WINDOWS_POLICY=$(envval WINDOWS_AGENT_POLICY_NAME); WINDOWS_POLICY=${WINDOWS_POLICY:-security_attack_AD}
LINUX_VMS=(vm-squid vm-kali)
WINDOWS_VMS=(vm-ad)
{ [ -n "$KIBANA_URL" ] && [ -n "$KIBANA_API_KEY" ]; } || { echo "fleet.env に KIBANA_URL / KIBANA_API_KEY がありません" >&2; exit 1; }

kb() { # kb METHOD PATH [curl args...]
  local m=$1 p=$2; shift 2
  curl -fsS -X "$m" "$KIBANA_URL$p" -H "Authorization: ApiKey $KIBANA_API_KEY" \
    -H 'kbn-xsrf: true' -H 'elastic-api-version: 2023-10-31' -H 'Content-Type: application/json' "$@"
}

policy_id() { kb GET "/api/fleet/agent_policies?perPage=100" | jq -r --arg n "$1" '.items[] | select(.name==$n) | .id' | head -n1; }

unregister_policy_agents() { # $1=policy id
  local ids id
  ids=$(kb GET "/api/fleet/agents?perPage=1000&showInactive=true" --get --data-urlencode "kuery=policy_id:\"$1\"" | jq -r '.items[].id')
  for id in $ids; do
    echo "  unregister: $id"
    kb DELETE "/api/fleet/agents/$id" >/dev/null
  done
}

enroll_token() { # $1=policy id
  kb GET "/api/fleet/enrollment_api_keys?perPage=100" | jq -r --arg p "$1" '[.items[] | select(.policy_id==$p and .active)][0].api_key'
}

LINUX_ID=$(policy_id "$LINUX_POLICY");     [ -n "$LINUX_ID" ]   || { echo "Agent policy '$LINUX_POLICY' が見つかりません" >&2; exit 1; }
WINDOWS_ID=$(policy_id "$WINDOWS_POLICY"); [ -n "$WINDOWS_ID" ] || { echo "Agent policy '$WINDOWS_POLICY' が見つかりません" >&2; exit 1; }

AGENT_VERSION=$(kb GET /api/fleet/agents/available_versions | jq -r '.items[] | select(test("^[0-9.]+$"))' | sort -V | tail -n1)
FLEET_URL=$(kb GET /api/fleet/fleet_server_hosts | jq -r '([.items[] | select(.is_default)] + .items)[0].host_urls[0]')
LINUX_TOKEN=$(enroll_token "$LINUX_ID")
WINDOWS_TOKEN=$(enroll_token "$WINDOWS_ID")
for v in AGENT_VERSION FLEET_URL LINUX_TOKEN WINDOWS_TOKEN; do
  { [ -n "${!v}" ] && [ "${!v}" != null ]; } || { echo "Fleet から ${v} を取得できません" >&2; exit 1; }
done
echo "Elastic Agent ${AGENT_VERSION} / ${FLEET_URL}"

echo "== Fleet: 既存 Agent を登録解除"
echo " policy: $LINUX_POLICY";   unregister_policy_agents "$LINUX_ID"
echo " policy: $WINDOWS_POLICY"; unregister_policy_agents "$WINDOWS_ID"

# run-command の結果 JSON から出力を表示し、成功マーカーが無ければ非 0 で終了する
# (run-command は VM 内スクリプトが失敗しても終了コード 0 を返すため)
show_result() {
  local out
  out=$(cat)
  echo "$out" | jq -r '.value[]?.message // empty'
  echo "$out" | jq -e '[.value[]?.message // ""] | any(contains("ELASTIC_AGENT_INSTALL_OK"))' >/dev/null || {
    echo "!! インストール失敗: 成功マーカーがありません" >&2
    return 1
  }
}

echo "== Linux VM に Elastic Agent をインストール"
for vm in "${LINUX_VMS[@]}"; do
  echo " $vm"
  az vm run-command invoke -g "$RG" -n "$vm" --command-id RunShellScript -o json \
    --scripts "#!/bin/bash"$'\n'"VERSION='$AGENT_VERSION'; FLEET_URL='$FLEET_URL'; TOKEN='$LINUX_TOKEN'; export VERSION FLEET_URL TOKEN" @scripts/remote-install-agent.sh | show_result
done

echo "== Windows VM に Elastic Agent をインストール"
for vm in "${WINDOWS_VMS[@]}"; do
  echo " $vm"
  az vm run-command invoke -g "$RG" -n "$vm" --command-id RunPowerShellScript -o json \
    --scripts @scripts/remote-install-agent.ps1 \
    --parameters "Version=$AGENT_VERSION" "FleetUrl=$FLEET_URL" "Token=$WINDOWS_TOKEN" | show_result
done

echo "== 完了。Fleet > Agents で Healthy になることを確認してください"
