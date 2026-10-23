output "opnsense_storage_account" {
  value = azurerm_storage_account.opnsense_image.name
}

output "opnsense_vhd_upload_command" {
  description = "Step 1 後: VHD アップロード"
  value       = "az storage blob upload --account-name ${azurerm_storage_account.opnsense_image.name} --container-name vhd --name opnsense.vhd --type page --file ${path.module}/../terraform/opnsense.vhd --max-connections 8"
}

output "opnsense_vhd_uri" {
  description = "Step 2 で terraform.auto.tfvars に設定する URI"
  value       = "https://${azurerm_storage_account.opnsense_image.name}.blob.core.windows.net/vhd/opnsense.vhd"
}

locals {
  bastion_tunnel_base = "az network bastion tunnel --name ${azurerm_bastion_host.main.name} --resource-group ${azurerm_resource_group.main.name}"
  step2_msg           = "Step 2 未完了: opnsense_vhd_uri を設定して terraform apply を再実行してください"
}

# --- A: VM リソース ID 指定（Bastion は primary NIC = WAN 10.10.1.4 に届く） ---
output "gui_tunnel_via_vm" {
  description = "A: VM ID 指定 → https://127.0.0.1:10443 （WAN 側。OPNsense は WAN の 443 を既定で遮断する）"
  value       = var.opnsense_vhd_uri != "" ? "${local.bastion_tunnel_base} --target-resource-id ${azurerm_virtual_machine.opnsense[0].id} --resource-port 443 --port 10443" : local.step2_msg
}

# --- B: IP 指定は 22 / 3389 のみ許可（443 は不可）。SSH 経由でポートフォワードする ---
output "ssh_tunnel_via_lan_ip" {
  description = "B-1: LAN IP(10.10.2.4) の SSH へトンネル（ターミナル1で実行）"
  value       = "${local.bastion_tunnel_base} --target-ip-address 10.10.2.4 --resource-port 22 --port 10022"
}

output "gui_forward_over_ssh" {
  description = "B-2: ターミナル2で実行 → ブラウザで https://127.0.0.1:10444"
  value       = "ssh -N -L 10444:127.0.0.1:443 -p 10022 root@127.0.0.1"
}

output "serial_console" {
  description = "起動ログ / コンソール確認"
  value       = var.opnsense_vhd_uri != "" ? "Azure Portal → vm-opnsense → Help → Serial console / Boot diagnostics、または: az vm boot-diagnostics get-boot-log --ids ${azurerm_virtual_machine.opnsense[0].id}" : local.step2_msg
}
