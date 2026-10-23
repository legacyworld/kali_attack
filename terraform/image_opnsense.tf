# ============================================================
# OPNsense VHD アップロード用ストレージ（Step 1 で作成）
# ============================================================
# デプロイ手順（./deploy.sh が一括実行する）:
#   Step 1: terraform apply -var opnsense_vhd_uri="" → ストレージアカウント等を作成
#   Step 2: 設定済み nano VHD（./opnsense-nano-configured.vhd。LAN の IP 入り）を az storage blob upload
#   Step 3: opnsense.auto.tfvars に blob URI を書き出して再 apply → OPNsense VM を作成
# ============================================================

resource "random_string" "opnsense_suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_storage_account" "opnsense_image" {
  name                            = "opnsensev2${random_string.opnsense_suffix.result}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_storage_container" "opnsense_image" {
  name                  = "vhd"
  storage_account_name  = azurerm_storage_account.opnsense_image.name
  container_access_type = "private"
}

# VHD アップロード後に opnsense_vhd_uri を設定して apply すると Managed Disk が作成される
data "azurerm_storage_account" "opnsense_vhd" {
  count               = var.opnsense_vhd_uri != "" ? 1 : 0
  name                = split(".", split("//", var.opnsense_vhd_uri)[1])[0]
  resource_group_name = local.rg
}

resource "azurerm_managed_disk" "opnsense" {
  count                = var.opnsense_vhd_uri != "" ? 1 : 0
  name                 = "opnsense-osdisk"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Premium_LRS"
  create_option        = "Import"
  source_uri           = var.opnsense_vhd_uri
  storage_account_id   = data.azurerm_storage_account.opnsense_vhd[0].id
  os_type              = "Linux"
  disk_size_gb         = 8
  tags                 = local.tags
}
