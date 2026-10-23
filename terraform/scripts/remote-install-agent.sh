#!/bin/bash
# Linux VM 上で実行 (az vm run-command invoke 経由): Elastic Agent を (再)インストールして Fleet に登録する
# 入力: 環境変数 VERSION / FLEET_URL / TOKEN (呼び出し側が先頭行で定義する)
# ※ az の --parameters は 'name=value' と解釈するため、末尾が '=' のトークンは壊れる。引数では渡さない。
set -euxo pipefail
: "${VERSION:?}" "${FLEET_URL:?}" "${TOKEN:?}"

# 既存の Agent があれば削除
if [ -x /usr/bin/elastic-agent ] || [ -d /opt/Elastic/Agent ]; then
  elastic-agent uninstall -f || /opt/Elastic/Agent/elastic-agent uninstall -f
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
NAME=elastic-agent-${VERSION}-linux-x86_64
curl -fsSL -o "$DIR/agent.tgz" "https://artifacts.elastic.co/downloads/beats/elastic-agent/${NAME}.tar.gz"
tar xzf "$DIR/agent.tgz" -C "$DIR"
(cd "$DIR/$NAME" && ./elastic-agent install --non-interactive --url="$FLEET_URL" --enrollment-token="$TOKEN")

echo ELASTIC_AGENT_INSTALL_OK
