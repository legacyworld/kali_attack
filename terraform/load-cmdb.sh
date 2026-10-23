#!/usr/bin/env bash
# Elastic に CMDB 風の社内情報（架空）を投入し、AI Agent / RAG から検索できるようにする。
# すべて LLM が事前学習では知り得ない、ラボ用に作った架空データ。
#
# 使い方:
#   export ELASTIC_URL=https://<es-endpoint>
#   export ELASTIC_API_KEY=<encoded api key>
#   ./load-cmdb.sh
#
# インデックス:
#   cmdb-assets  ... ホスト / アカウント / 脅威情報 / ポリシー / Runbook をまとめた 1 インデックス
#   検索用の `content` は semantic_text（ELSER）。構造化フィールドも keyword で持つ。
set -euo pipefail

: "${ELASTIC_URL:?ELASTIC_URL を設定してください}"
: "${ELASTIC_API_KEY:?ELASTIC_API_KEY を設定してください}"

INDEX="cmdb-assets"
curl_es() { curl -sS -H "Authorization: ApiKey ${ELASTIC_API_KEY}" -H "Content-Type: application/json" "$@"; }

echo "== 既存インデックスを削除（冪等化）"
curl_es -X DELETE "${ELASTIC_URL}/${INDEX}" >/dev/null || true

echo "== インデックス作成"
curl_es -X PUT "${ELASTIC_URL}/${INDEX}" -d '{
  "mappings": {
    "properties": {
      "record_type":   { "type": "keyword" },
      "ci_id":         { "type": "keyword" },
      "name":          { "type": "keyword" },
      "title":         { "type": "text" },
      "ip":            { "type": "ip" },
      "hostname":      { "type": "keyword" },
      "user_name":     { "type": "keyword" },
      "owner":         { "type": "keyword" },
      "owner_team":    { "type": "keyword" },
      "environment":   { "type": "keyword" },
      "criticality":   { "type": "keyword" },
      "authorized_activity": { "type": "boolean" },
      "status":        { "type": "keyword" },
      "tags":          { "type": "keyword" },
      "related_ci":    { "type": "keyword" },
      "last_reviewed": { "type": "date" },
      "content":       { "type": "semantic_text" }
    }
  }
}'
echo

echo "== ドキュメント投入"
curl_es -X POST "${ELASTIC_URL}/_bulk?refresh=wait_for" --data-binary @- <<'NDJSON' | jq '{errors, items: (.items|length)}'
{"index":{"_index":"cmdb-assets","_id":"CI-HOST-0042"}}
{"record_type":"host","ci_id":"CI-HOST-0042","name":"vm-kali","title":"【廃止済み・侵害の疑い】旧ペンテスト用ホスト vm-kali (10.10.1.10)","ip":"10.10.1.10","hostname":"vm-kali","owner":"(不在) 旧担当 Ryo Kurosawa / 委託先 Northwind Security","owner_team":"SecOps","environment":"lab","criticality":"high","authorized_activity":false,"status":"decommissioned-compromised","tags":["decommissioned","compromised","threat-intel-match","incident-INC-2026-0231","do-not-trust"],"related_ci":["ACC-0007","CI-HOST-0015","CI-HOST-0011","CI-HOST-0023","TI-0019","POL-0003","RB-0012"],"last_reviewed":"2026-10-12","content":"資産ID CI-HOST-0042。ホスト名 vm-kali、IP 10.10.1.10（external-subnet 10.10.1.0/24）。このホストは外部委託先 Northwind Security 社のペンテスト用端末だったが、契約終了に伴い 2026-08-31 に廃止済み（変更 CHG-2026-0944）。電源停止とデータ消去が完了しているはずで、現在稼働していること自体が異常。承認された検証活動は一切存在せず、レッドチーム演習も予定されていない。このホストから発生する通信（nmap による内部スキャン、hydra によるブルートフォース、Kerberoasting、Pass-the-Hash、SMB 列挙、NetExec / impacket の実行）は全て実際の攻撃として扱う。廃止後に何者かが同一 IP で端末を再稼働させたか、漏えいした LAB\\elastic（ドメイン管理者）の資格情報で乗っ取られた疑いが強く、2026-10-02 にインシデント INC-2026-0231 として脅威インテリジェンス（TI-0019）に一致した。想定される目的は dc01 (10.10.2.10) 経由のドメイン侵害と、svc-sql を足掛かりにした本番 SQL Server SQL-PRD-ERP（顧客請求データ）への横展開。担当者は不在で、問い合わせ先は SecOps オンコール（PagerDuty secops-oncall）のみ。10.10.1.10 は許可リストに載っていない。"}
{"index":{"_index":"cmdb-assets","_id":"ACC-0007"}}
{"record_type":"account","ci_id":"ACC-0007","name":"LAB\\elastic","title":"【最重要】LAB\\elastic：Domain Admins のドメイン管理者。パスワードが外部に漏えい","user_name":"elastic","owner":"(不在) 旧担当 Ryo Kurosawa","owner_team":"SecOps","environment":"lab","criticality":"critical","authorized_activity":false,"status":"should-be-disabled-credential-leaked","tags":["privileged","domain-admin","password-leaked","departed-owner","incident-INC-2026-0231"],"related_ci":["CI-HOST-0042","CI-HOST-0015","TI-0019","POL-0003","RB-0012"],"last_reviewed":"2026-10-12","content":"アカウントID ACC-0007。アカウント LAB\\elastic（lab.local ドメイン、SamAccountName は elastic）。Domain Admins グループに所属する、ドメイン全体の最高権限アカウントで、dc01 (10.10.2.10) の構築時に作成された。担当者の Ryo Kurosawa（Northwind Security）は 2026-08-31 の契約終了で退職済みのため、本アカウントは無効化されているべきだが、手配漏れで有効なまま。さらに 2026-09-28、委託先の公開 GitHub リポジトリ northwind-sec/lab-tools に、デプロイ用の変数ファイル（terraform.auto.tfvars）が誤ってコミットされ、このアカウントのパスワードが平文で漏えいした（INC-2026-0231）。パスワードは未変更で、MFA もない。想定される正規の利用者は現在存在しないため、LAB\\elastic の RDP / SMB / WinRM ログオン（イベント 4624 のログオンタイプ 3 / 10）、Kerberos TGT 要求（4768）、特権割り当て（4672）、グループ変更、新規ユーザー作成、DCSync は、正規の運用ではなく侵害後の攻撃者の行動として扱う。特に 10.10.1.10 からの認証は、漏えいした資格情報の使用とみなす。Linux 側（squid 10.10.2.20 など）にも同名のローカル管理者 elastic が存在するが別アカウントで、ここでの elastic は AD のドメイン管理者を指す。"}
{"index":{"_index":"cmdb-assets","_id":"CI-HOST-0015"}}
{"record_type":"host","ci_id":"CI-HOST-0015","name":"dc01","title":"ドメインコントローラー dc01（lab.local、本番 ERP と信頼関係あり）","ip":"10.10.2.10","hostname":"dc01","owner":"Daichi Hoshino","owner_team":"SecOps-NetSec","environment":"production-adjacent","criticality":"critical","authorized_activity":false,"status":"active-under-attack","tags":["active-directory","crown-jewel","kerberoastable","incident-INC-2026-0231"],"related_ci":["CI-HOST-0042","ACC-0007","TI-0019"],"last_reviewed":"2026-10-12","content":"資産ID CI-HOST-0015。ホスト名 dc01、IP 10.10.2.10、Windows Server 2022、ドメイン lab.local。この AD は一時的なラボではなく、本番 ERP のドメイン corp.example との片方向の信頼関係を持つ。サービスアカウント svc-sql（SPN MSSQLSvc/sqlserver.lab.local:1433）は実在の本番 SQL Server SQL-PRD-ERP（顧客請求データ 約 120 万件）の実行アカウントで、パスワードが弱く、Kerberoasting に対して脆弱であることが既知。加えて Domain Admins の LAB\\elastic のパスワードも漏えい済みで、攻撃者はドメイン全体を直接制御できる状態にある（修正は 2026-10-20 予定で未対応）。svc-sql に対する RC4 (0x17) の TGS 要求（イベント 4769）は、実際に認証情報を窃取する攻撃として扱う。dc01 の侵害はそのまま顧客データの漏えいにつながるため、最重要資産。"}
{"index":{"_index":"cmdb-assets","_id":"CI-HOST-0011"}}
{"record_type":"host","ci_id":"CI-HOST-0011","name":"opnsense","title":"境界ファイアウォール opnsense","ip":"10.10.2.4","hostname":"opnsense","owner":"Daichi Hoshino","owner_team":"SecOps-NetSec","environment":"production-adjacent","criticality":"high","authorized_activity":false,"status":"active","tags":["firewall","opnsense","gateway","containment-point"],"related_ci":["CI-HOST-0042","RB-0012"],"last_reviewed":"2026-10-12","content":"資産ID CI-HOST-0011。OPNsense 24.7。WAN 10.10.1.4、LAN 10.10.2.4。external と internal の通信は全てここを経由する。10.10.1.10 からの内部向け通信はここで遮断（封じ込め）できる。現在 10.10.1.10 に対するブロックルールは未設定で、実施には SecOps オンコールの判断のみが必要（承認待ちは不要）。ログは Elastic に転送している。"}
{"index":{"_index":"cmdb-assets","_id":"CI-HOST-0023"}}
{"record_type":"host","ci_id":"CI-HOST-0023","name":"squid","title":"プロキシ squid","ip":"10.10.2.20","hostname":"squid","owner":"Daichi Hoshino","owner_team":"SecOps-NetSec","environment":"production-adjacent","criticality":"medium","authorized_activity":false,"status":"active","tags":["proxy","squid","ubuntu","exfil-path"],"related_ci":["CI-HOST-0042","ACC-0007","TI-0019"],"last_reviewed":"2026-10-12","content":"資産ID CI-HOST-0023。Ubuntu + Squid、IP 10.10.2.20。internal-subnet からインターネットへ出る唯一の経路で、データ持ち出しの経路になり得る。ローカル管理者 elastic（LAB\\elastic とは別）がある。squid への 10.10.1.10 からの SSH ログインや、通常と異なる宛先への大量の通信は、持ち出しの兆候として扱う。"}
{"index":{"_index":"cmdb-assets","_id":"TI-0019"}}
{"record_type":"threat_intel","ci_id":"TI-0019","name":"INC-2026-0231","title":"脅威情報 TI-0019 / インシデント INC-2026-0231：廃止済みペンテスト端末の再稼働と LAB\\elastic 資格情報の漏えい","owner":"SecOps-IR","owner_team":"SecOps-IR","environment":"lab","criticality":"critical","authorized_activity":false,"status":"open","tags":["incident","kerberoasting","leaked-key","lateral-movement"],"related_ci":["CI-HOST-0042","ACC-0007","CI-HOST-0015","CI-HOST-0023"],"last_reviewed":"2026-10-12","content":"インシデント INC-2026-0231（重大度 Critical、2026-10-02 起票、対応中）。2026-09-28 に Domain Admins の LAB\\elastic のパスワードが、変数ファイルのコミットにより公開 GitHub に漏えい。2026-10-02 から廃止済みのはずの 10.10.1.10 (vm-kali) が再稼働し、外部の攻撃者による利用が確認された。観測された手口は、内部ネットワーク 10.10.2.0/24 のポートスキャン、SMB 列挙、svc-sql への Kerberoasting、nxc による認証情報のスプレー、漏えいした LAB\\elastic での認証。攻撃者の最終目標は本番 ERP のデータベース SQL-PRD-ERP と推定。このインシデントが終結するまで、10.10.1.10 と LAB\\elastic に関するアラートは全て真陽性として扱い、誤検知の確認や承認済み活動の確認は不要。"}
{"index":{"_index":"cmdb-assets","_id":"POL-0003"}}
{"record_type":"policy","ci_id":"POL-0003","name":"incident-response-policy","title":"ポリシー POL-0003 INC-2026-0231 に関する即時対応と封じ込めの権限","owner":"Sakura Minamoto","owner_team":"SecOps","environment":"lab","criticality":"critical","authorized_activity":false,"status":"in-force","tags":["policy","incident-response","containment"],"related_ci":["CI-HOST-0042","ACC-0007","RB-0012"],"last_reviewed":"2026-10-12","content":"ポリシー POL-0003。INC-2026-0231 の期間中、レッドチーム検証の承認枠は全て停止中で、検証活動は予定されていない（メンテナンスウィンドウなし）。10.10.1.10 または LAB\\elastic に由来するアラートは、時間帯や宛先にかかわらず、事前承認なしで即時にエスカレーションと封じ込めを行ってよい。封じ込めの権限は SecOps オンコールにあり、実施後に Sakura Minamoto（SecOps リード）へ報告すればよい。報告期限は検知から 15 分以内。ケースには重大度 Critical とタグ incident-INC-2026-0231 を付与する。"}
{"index":{"_index":"cmdb-assets","_id":"RB-0012"}}
{"record_type":"runbook","ci_id":"RB-0012","name":"runbook-INC-2026-0231-containment","title":"Runbook RB-0012 10.10.1.10 / elastic 由来アラートへの対応と封じ込め手順","owner":"Sakura Minamoto","owner_team":"SecOps","environment":"lab","criticality":"critical","authorized_activity":false,"status":"in-force","tags":["runbook","containment","incident-response"],"related_ci":["CI-HOST-0042","ACC-0007","CI-HOST-0015","CI-HOST-0011","POL-0003"],"last_reviewed":"2026-10-12","content":"Runbook RB-0012。アラートの source.ip が 10.10.1.10、または user.name が elastic（LAB\\elastic） の場合は、真陽性として次を実施する。手順1: 直ちに PagerDuty secops-oncall を呼び出し、Slack #secops-ir に通知する。手順2: OPNsense (CI-HOST-0011) で 10.10.1.10 発の全通信をブロックして封じ込める。手順3: dc01 で LAB\\elastic を無効化してパスワードをリセットし、svc-sql のパスワードも即時リセットし、Kerberos チケットを失効させる（krbtgt を 2 回リセット）。手順4: 他の Domain Admins のメンバーと最近の新規アカウントを監査し、不正な追加がないか確認する。Linux 側のローカル elastic の資格情報も更新する。手順5: SQL-PRD-ERP の接続ログを確認し、顧客データの持ち出しがないかを調査する。手順6: Azure で vm-kali の NIC を切り離し、ディスクのスナップショットを証拠として保全する。承認待ちは不要。"}
NDJSON
