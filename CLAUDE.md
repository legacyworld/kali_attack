# Elastic Security 攻撃シミュレーション ラボ — Claude 向けプロジェクト指示

## 概要

OPNsense（ファイアウォール）/ Squid（プロキシ）/ Windows Server AD の 3 層ログ環境を Azure VM で再現し、Kali 相当の Ubuntu VM から攻撃を仕掛けて Elastic Security でアラートを検証するラボ。

## ディレクトリ構成

```
security_attack2/
├── terraform/          # 正式環境（攻撃チェーン版。旧 terraform-v2/）。メイン作業場所
│   ├── providers.tf
│   ├── locals.tf            # rg = contoso-seclab-v2 / vnet_name = seclab-v2-vnet
│   ├── variables.tf
│   ├── network.tf          # VNet / サブネット / UDR / NAT Gateway / Bastion
│   ├── image_opnsense.tf   # VHD 用ストレージ + Managed Disk 定義
│   ├── vm_opnsense.tf      # OPNsense アプライアンス VM
│   ├── vm_ad.tf            # Windows Server 2022 AD DS（監査ポリシー・svc-sql・Sysmon 含む）
│   ├── vm_squid.tf         # Ubuntu + Squid プロキシ
│   ├── vm_kali.tf          # Ubuntu + 攻撃ツール（Kali 相当）
│   ├── outputs.tf
│   ├── deploy.sh           # 2 ステップデプロイ一括実行（Step 1 → VHD アップロード → Step 2）
│   ├── setup-detection-rules.sh  # カスタム検知ルール（rule_id: lab-v2-*）セットアップ
│   ├── load-cmdb.sh        # CMDB 風データ投入（AI Agent / RAG 検証用、攻撃シナリオとは独立）
│   ├── opnsense-nano-configured.vhd  # 設定済み OPNsense VHD（正式版。git 管理外・手元で保管）
│   └── .env.example        # 機密変数の雛形
├── terraform-legacy/   # 旧・本番デモ環境（RG contoso-seclab）。destroy 済み・参照用のみ。使わない
├── terraform-opnsense-only/  # OPNsense だけを立てるトラブルシュート用（別 state / 別 RG）
└── README.md
```

## Azure 環境の制約（絶対に守ること）

### タグ必須
すべてのリソースに `local.tags` を付ける。`locals.tf` に定義済み（division / org / keep-until / team / project）。

### NSG 禁止
Azure Policy が特定ポートを含む NSG をブロックする。**NIC・サブネット問わず NSG を追加しない**。

### Bastion 必須
- SKU: `Standard`
- `tunneling_enabled = true`
- `ip_connect_enabled = true`
- VM への SSH/RDP は Bastion トンネル経由のみ。パブリック IP を VM に付けない。

### リージョン
`southeastasia` 固定。

### admin_username
`"elastic"` 固定（`locals.tf` の `local.admin_username`）。

### Azure 予約 IP
各サブネットで `.0`〜`.3` と `.255` は使用不可。NIC の静的 IP は `.4` 以降から割り当てる。

## ネットワーク設計

| サブネット | CIDR | 用途 |
|---|---|---|
| AzureBastionSubnet | 10.10.0.0/26 | Bastion |
| external-subnet | 10.10.1.0/24 | OPNsense WAN (10.10.1.4) / Kali (10.10.1.10) |
| internal-subnet | 10.10.2.0/24 | OPNsense LAN (10.10.2.4) / AD (10.10.2.10) / Squid (10.10.2.20) |

UDR で双方向トラフィックを OPNsense 経由に強制。

### インターネットへの出口（NAT Gateway）
- 新しい VNet のサブネットには Azure の既定の送信アクセスがない。VM にパブリック IP も付けられないので、**external-subnet に NAT Gateway**（`network.tf`: `azurerm_nat_gateway.main` など）を付けて OPNsense WAN の出口にしている。
- internal-subnet（Squid / AD）の外向き通信は、UDR で OPNsense LAN → WAN → NAT Gateway の順に出る。internal-subnet には NAT Gateway を付けない。
- NAT Gateway は **TCP / UDP のみで ICMP を通さない。** `ping 8.8.8.8` や `ping www.google.com` は正常でも失敗する。疎通確認は `curl -sI http://example.com`（Squid VM から）や `nc -zv <IP> 443`、`drill www.google.com @8.8.8.8`（OPNsense）で行う。
- NAT Gateway・パブリック IP は VM を止めても課金が続く。

## OPNsense デプロイの特殊事情

### イメージは nano（設定済み VHD）を使う
- **serial イメージは使わない。** ライブ（インストーラー）環境で、ルートが `OPNsense_Install` の read-only UFS、`/conf` は unionfs で tmpfs に載るだけ。VM を停止すると設定が消える。VHD に保存しても設定は入らない（元の VHD と 36 バイトしか差がない）。
- **nano イメージを使う。** ディスクにインストール済み（`/dev/ufs/OPNsense_Nano` が rw）で、設定がディスクの `/conf` に残る。Azure（Hyper-V）でも問題なく起動・永続化することを確認済み（過去の「Nano 不可」は誤り）。
- 設定済み VHD は `terraform/opnsense-nano-configured.vhd`。割り当て（WAN=hn0 / LAN=hn1）、**LAN の IP（10.10.2.4/24）**、WAN の Block private/bogon 解除、WAN の TCP 443 pass ルールを保存済み。デプロイ後に OPNsense を設定し直す必要はない。
- LAN の IP が無い状態（作り直しに失敗した VHD）は、Squid → 10.10.2.4 の ping が通らない、で気づく。OPNsense のファイアウォールを切っても直らない（OS 側がその IP を持っていないため）。シリアルコンソールのメニュー `2` で LAN を 10.10.2.4/24 にする（GW・DHCP サーバーなし）。
- VHD は手元に必ず保管する（git 管理外）。ストレージには置きっぱなしにできない運用のため、毎回 destroy で消して再アップロードする。

### NIC の割り当て（Azure / Hyper-V）
- primary NIC（10.10.1.4・external）が **hn0**、2 枚目（10.10.2.4・internal）が **hn1**。FreeBSD の自動割り当ては WAN→hn1 / LAN→hn0 と逆になるので、素のイメージでは手で WAN=hn0 / LAN=hn1 にする。
- WAN にしたインターフェースは Block private/bogon が既定で有効で、Bastion の送信元（10.10.0.x）を落とすため GUI に入れなくなる。解除と、WAN の TCP 443 pass ルールが必要。ルールを Apply すると `pfctl -d` の効果は消える（その前に 443 の pass ルールを入れる）。
- NIC の順序（`vm_opnsense.tf` の `network_interface_ids`）を変えると設定済み VHD の割り当てと合わなくなる。

### デプロイ（2 ステップ方式を `deploy.sh` で一括実行）
```bash
cd terraform
./deploy.sh                      # 省略時は ./opnsense-nano-configured.vhd
./deploy.sh /path/to/other.vhd
```
- **Step 1**: `terraform apply -var opnsense_vhd_uri=""`（ストレージ + その他 VM。OPNsense VM はスキップ）
- VHD アップロード: `az storage blob upload --type page --overwrite`（8 GB）
- **Step 2**: `opnsense.auto.tfvars`（git 管理外）に `opnsense_vhd_uri` を書き出して再 apply → OPNsense VM を作成
  - `opnsense_vhd_uri` は `terraform.auto.tfvars` には書かない（`deploy.sh` が別ファイルで管理）

`var.opnsense_vhd_uri` が空文字列のとき `count = 0`（image_opnsense.tf の Managed Disk と vm_opnsense.tf の全リソース）。

### 設定済み VHD の作り方（作り直すとき）
```bash
# nano イメージ（amd64）。DVD/VGA/serial は不可。
curl -LO https://mirror.ams1.nl.leaseweb.net/opnsense/releases/24.7/OPNsense-24.7-nano-amd64.img.bz2
bunzip2 OPNsense-24.7-nano-amd64.img.bz2          # 3 GB
truncate -s 8192M OPNsense-24.7-nano-amd64.img    # サイズを整数 MB に揃える
qemu-img convert -f raw -o subformat=fixed,force_size -O vpc \
  OPNsense-24.7-nano-amd64.img opnsense-nano.vhd
```
`force_size` を省略するとサイズが端数になり Azure がエラーを返す。VHD は 8,589,935,104 バイト（8 GiB + 512 バイトのフッター）になる。

1. `./deploy.sh opnsense-nano.vhd` で起動し、OPNsense を設定する（上の NIC 割り当ての節）。`sync` してから VM を停止（`az vm deallocate`）する。
2. OS ディスクの Snapshot を取り（**必須タグを付ける**。RG にタグはないので、ディスクのタグを引き継ぐ）、`az snapshot grant-access`（JSON のキーは `accessSAS`）で SAS を発行する。
3. `curl -C -` で再開ループしながらダウンロードする。接続リセットやハングが起きるので、`--speed-limit 100000 --speed-time 30 --connect-timeout 20` で停止を検知させる。
4. `az snapshot revoke-access` で SAS を失効させる。Snapshot は destroy の前に削除する（RG の削除が失敗するため）。
5. `cmp` で元の nano VHD と比べ、差が 36 バイトを大きく超えていれば設定が入っている。
6. **LAN の IP（10.10.2.4/24）が入っているか**を、設定前の VHD ではなく、保存した VHD で `./deploy.sh <VHD>` を実行して確かめる（OPNsense で何も設定せずに `ifconfig hn1` が 10.10.2.4、Squid から `curl -sI http://example.com` が 200 になること）。確認できたら正式版（`opnsense-nano-configured.vhd`）に差し替える。
- スナップショットの SAS 経由でダウンロードしたファイルは、そのまま VHD になっている（末尾に `conectix` のフッター、8,589,935,104 バイト）。`qemu-img convert` は不要。
- SAS の有効期限（`--duration-in-seconds`）は、8 GB を 1 分約 37 MB で落とす時間（約 4 時間）を見込んで 14400 以上にする。切れたら `revoke-access` → `grant-access` で再発行し、同じファイルに `curl -C -` で追記する。

### OPNsense 単体のトラブルシュート環境（`terraform-opnsense-only/`）
- NAT Gateway は付いていない（メイン構成の `network.tf` にだけある）。インターネットへの出口の確認はメイン環境で行う。
- OPNsense だけを別 state・別 RG（`contoso-opnsense-debug`、VNet 10.10.0.0/16）で立てる。本番と同じ `./deploy.sh [VHD]` で動く。使い方は同ディレクトリの README.md。
- Bastion の `--target-ip-address`（IP 接続）トンネルは **22/3389 以外のポートを使えない**（`Custom ports are not allowed`）。GUI(443) は `--target-resource-id <VM の ID>` のトンネルで張る。IP 接続でしか届かない先は、SSH で LAN 側 IP(10.10.2.4:22) に入って `ssh -L` で転送する。
- シリアルコンソールは `root` / `opnsense`。ファイアウォールで GUI に入れなくなったら `pfctl -d`（再起動か、ルールの Apply で元に戻る）。
- 課金が続くので、使い終えたら `terraform destroy`。先に Snapshot を消す（RG の削除が失敗する）。

### 運用上の注意
- OPNsense の設定（LAN の IP など）は OS ディスクにあるので、**`opnsense-osdisk` が作り直されると VHD の状態に戻る**（Import 元の VHD の設定に戻る）。`terraform apply` の前に `terraform plan` で、`opnsense` の VM やディスクが replace / destroy になっていないか確認する。コンソールで設定を変えたら、VHD に取り直さない限りその場限りになる。
- `terraform apply -auto-approve` を `deploy.sh` 経由で実行することは、権限の分類器に拒否される。デプロイと destroy はユーザーが自分で実行する（私は実行しない）。
- VHD のダウンロードは `curl -C -` が接続リセットやハングで止まる。バックグラウンドで実行する場合は、ループを `&` で自分で切り離さず、タスクとして実行し、進捗の監視と停止検知を付ける。

### `azurerm_managed_disk` の注意点
- `create_option = "Import"` のとき `storage_account_id` は必須（プロバイダー要件）
- VHD アップロード先と Terraform が管理するストレージアカウント名が異なる可能性があるため、**data source で URI からアカウント名を動的に抽出**する（`image_opnsense.tf` 参照）
- `disk_size_gb = 8`（VHD が 8 GB に切り詰め済みのため）

### `azurerm_virtual_machine`（汎用リソース）を使用
FreeBSD アプライアンスのため `azurerm_linux_virtual_machine` は不可（`os_profile` 必須、カスタムディスク Attach 非対応）。

## Windows Server AD

- イメージ: `2022-Datacenter`（Gen1）
- **`vtpm_enabled` / `secure_boot_enabled` 禁止**（Gen1 は TrustedLaunch 非対応）
- `azurerm_virtual_machine_run_command` で AD DS インストール・DC 昇格・監査ポリシー設定・Kerberoasting 用疑似サービスアカウント（`svc-sql`、SPN: `MSSQLSvc/sqlserver.lab.local:1433`）作成を自動化
- ドメイン: `lab.local`
- 監査ポリシー設定・疑似サービスアカウント作成は DC 昇格（`Install-ADDSForest -Force`）が引き起こす再起動を経てから実行する想定のため、`promote_dc` への `depends_on` を付けていない。再起動完了を確認してから改めて `terraform apply` する運用。

### Run Command スクリプトの注意（実際にハマった）
- **スクリプト内の文字列リテラル（`Write-Error "..."` など）は ASCII のみにする。** Run Command は Windows PowerShell 5.1 が ANSI として読むため、日本語が cp1252 の引用符（0x94 等）に化けて文字列が閉じず、`Missing closing '}'` のパースエラーになる。日本語は `#` コメントなら問題ない。
- **失敗した run command を同名で作り直さない。** VM 内のハンドラが古い失敗結果（修正前スクリプト）を返し、新スクリプトが実行されないことがある（エラーの行番号が修正前のまま・数百ミリ秒で終わる、が目印）。リソースの `name` を変える（`vm_ad.tf` の `create-svc-account-v3` が例）。
- スクリプトは冪等にする（`svc-sql` は存在確認してから作成、SPN は未登録のときだけ登録）。途中失敗後の再実行で `The specified account already exists` にならないようにする。

## Ubuntu 攻撃 VM（Kali 相当）

Kali Linux は Azure Marketplace から削除済みのため、Ubuntu 22.04 LTS + cloud-init で攻撃ツールをインストール。`vm_kali.tf` 参照。

## 環境変数管理

```bash
# terraform/ ディレクトリで実行するだけ（source は不要）
terraform apply
```

機密変数は `terraform/terraform.auto.tfvars` に定義する（Terraform が自動で読み込む）。`opnsense_vhd_uri` は `deploy.sh` が `terraform/opnsense.auto.tfvars` に書き出す。`*.tfvars` は `.gitignore` 済みで git には含めない。雛形は `.env.example` を参照。
`.env`（`export TF_VAR_*` 形式）は旧方式。ARM_* 等の Azure 認証を環境変数で渡す場合のみ使う。

## コマンド実行ルール

- Terraform は `terraform/` ディレクトリで実行
- Azure CLI は直接実行（Docker 不要）
- qemu-img は `brew install qemu` で導入済み前提
