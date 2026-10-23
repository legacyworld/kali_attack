# OPNsense 単体トラブルシュート用 Terraform

`https://127.0.0.1:10443`（Bastion トンネル経由）で OPNsense GUI に繋がらない問題を切り分けるための、OPNsense だけの最小構成。
メイン構成 (`../terraform`) とは **別 RG (`contoso-opnsense-debug`) / 別 state** なので互いに影響しない。

構成: Bastion + external(10.10.1.0/24) / internal(10.10.2.0/24) + OPNsense (WAN 10.10.1.4 / LAN 10.10.2.4)。UDR・NSG なし。

## 手順
```bash
cd terraform-opnsense-only
terraform init
terraform apply                       # Step 1: Bastion / Storage 等

# VHD は ../terraform/opnsense.vhd を流用（変換済み）
az login   # 未ログインなら
$(terraform output -raw opnsense_vhd_upload_command)

echo "opnsense_vhd_uri = \"$(terraform output -raw opnsense_vhd_uri)\"" > terraform.auto.tfvars
terraform apply                       # Step 2: OPNsense VM
```

## 接続の切り分け
Bastion の IP 指定トンネルは 22 / 3389 のみ許可（`--resource-port 443` は "Custom ports are not allowed"）。

| 方法 | コマンド | アクセス先 |
|---|---|---|
| A: VM ID 指定（元のやり方） | `gui_tunnel_via_vm` | https://127.0.0.1:10443（primary NIC = WAN に届く。WAN の 443 は既定遮断） |
| B: LAN 側 SSH 経由 | ターミナル1: `ssh_tunnel_via_lan_ip` / ターミナル2: `gui_forward_over_ssh` | https://127.0.0.1:10444 |

B は OPNsense 側で SSH (root ログイン) の有効化が必要（初回はシリアルコンソールから Services → Secure Shell を設定）。

Bastion のトンネル確認: `az network bastion tunnel` の出力で "Tunnel is ready" が出ているか、`curl -vk https://127.0.0.1:<port>`。
起動ログ: `terraform output serial_console`（OPNsense が起動して hn0/hn1 が割り当たっているか）。

## 後片付け
```bash
terraform destroy
```

## 毎回の流れ（ストレージは destroy で消える前提）
```bash
./deploy.sh                      # 設定済み VHD (../terraform/opnsense-nano-configured.vhd。LAN の IP 10.10.2.4/24 入りの v2) で Step 1 → アップロード → Step 2
./deploy.sh path/to/other.vhd    # 別の VHD を使う場合
terraform destroy                # 終わったら全削除
```
この環境には NAT Gateway が無く、OPNsense はインターネットに出られない（出口の確認はメイン環境で行う）。
設定を変更したら VHD を保存し直す（`az vm deallocate` → `az disk grant-access` → `curl -C -` で取得）。
