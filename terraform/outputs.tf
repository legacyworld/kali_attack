output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "bastion_name" {
  value = azurerm_bastion_host.main.name
}

# ---- Step 1 完了後: OPNsense VHD アップロード先 ----
output "opnsense_storage_account" {
  description = "OPNsense VHD をアップロードするストレージアカウント名"
  value       = azurerm_storage_account.opnsense_image.name
}

output "opnsense_vhd_upload_command" {
  description = "OPNsense VHD アップロードコマンド（qemu-img で変換後に実行）"
  value       = "az storage blob upload --account-name ${azurerm_storage_account.opnsense_image.name} --container-name vhd --name opnsense.vhd --type page --file opnsense.vhd"
}

output "opnsense_vhd_uri" {
  description = "アップロード後に TF_VAR_opnsense_vhd_uri に設定する URI"
  value       = "https://${azurerm_storage_account.opnsense_image.name}.blob.core.windows.net/vhd/opnsense.vhd"
}

# ---- Step 2 完了後: OPNsense Bastion 接続 ----
output "opnsense_gui_tunnel" {
  description = "OPNsense 管理 GUI (HTTPS) → ブラウザで https://127.0.0.1:10443"
  value = var.opnsense_vhd_uri != "" ? (
    "az network bastion tunnel --name ${azurerm_bastion_host.main.name} --resource-group ${azurerm_resource_group.main.name} --target-resource-id ${azurerm_virtual_machine.opnsense[0].id} --resource-port 443 --port 10443"
  ) : "Step 2 未完了: opnsense_vhd_uri を設定して terraform apply を再実行してください"
}

output "opnsense_ssh_tunnel" {
  description = "OPNsense SSH → ssh root@127.0.0.1 -p 10022"
  value = var.opnsense_vhd_uri != "" ? (
    "az network bastion tunnel --name ${azurerm_bastion_host.main.name} --resource-group ${azurerm_resource_group.main.name} --target-resource-id ${azurerm_virtual_machine.opnsense[0].id} --resource-port 22 --port 10022"
  ) : "Step 2 未完了: opnsense_vhd_uri を設定して terraform apply を再実行してください"
}

# ---- Windows AD ----
output "ad_rdp_tunnel" {
  description = "Windows AD RDP → RDP クライアントで localhost:13389"
  value       = "az network bastion tunnel --name ${azurerm_bastion_host.main.name} --resource-group ${azurerm_resource_group.main.name} --target-resource-id ${azurerm_windows_virtual_machine.ad.id} --resource-port 3389 --port 13389"
}

# ---- Squid ----
output "squid_ssh_tunnel" {
  description = "Squid VM SSH → ssh elastic@127.0.0.1 -p 10023"
  value       = "az network bastion tunnel --name ${azurerm_bastion_host.main.name} --resource-group ${azurerm_resource_group.main.name} --target-resource-id ${azurerm_linux_virtual_machine.squid.id} --resource-port 22 --port 10023"
}

# ---- Kali ----
output "kali_ssh_tunnel" {
  description = "Kali Linux SSH → ssh elastic@127.0.0.1 -p 10024"
  value       = "az network bastion tunnel --name ${azurerm_bastion_host.main.name} --resource-group ${azurerm_resource_group.main.name} --target-resource-id ${azurerm_linux_virtual_machine.kali.id} --resource-port 22 --port 10024"
}

# ---- Private IPs ----
output "private_ips" {
  value = {
    opnsense_wan = var.opnsense_vhd_uri != "" ? azurerm_network_interface.opnsense_wan[0].private_ip_address : "未デプロイ"
    opnsense_lan = var.opnsense_vhd_uri != "" ? azurerm_network_interface.opnsense_lan[0].private_ip_address : "未デプロイ"
    ad           = azurerm_network_interface.ad.private_ip_address
    squid        = azurerm_network_interface.squid.private_ip_address
    kali         = azurerm_network_interface.kali.private_ip_address
  }
}
