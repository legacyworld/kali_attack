# ============================================================
# OPNsense VHD アップロード用ストレージ（Step 1 で作成）
# ============================================================
# デプロイ手順（./deploy.sh が一括実行する）:
#   Step 1: terraform apply -var opnsense_vhd_uri="" → ストレージアカウント等を作成
#   Step 2: 設定済み nano VHD（opnsense-nano-configured.vhd。LAN の IP 入り）を az storage blob upload
#   Step 3: opnsense.auto.tfvars に blob URI を書き出して再 apply → OPNsense VM を作成
# VHD は nano イメージ（ディスクにインストール済み）に設定を入れて保存したもの。
# serial イメージはライブ環境で設定がメモリ上に載るだけなので使わない。
# ============================================================

resource "random_string" "opnsense_suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_storage_account" "opnsense_image" {
  name                            = "opnsense${random_string.opnsense_suffix.result}"
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
# VHD URI から "https://<account>.blob.core.windows.net/..." のアカウント名を抽出して
# data source で ID を引く。こうすると Terraform 管理のストレージアカウントと
# 実際のアップロード先が別でも名前を手で合わせる必要がない。
data "azurerm_storage_account" "opnsense_vhd" {
  count               = var.opnsense_vhd_uri != "" ? 1 : 0
  name                = split(".", split("//", var.opnsense_vhd_uri)[1])[0]
  # azurerm_resource_group.main.name ではなく local.rg（同じ値の固定文字列）を使う。
  # リソース参照にすると、tags の timestamp() 由来の差分で main が「更新待ち」になるたびに
  # この data source が apply 時まで遅延評価され、storage_account_id (ForceNew) が unknown になって
  # opnsense のディスク・VM が不要に再作成されてしまう。
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
