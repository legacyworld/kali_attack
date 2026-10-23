# FreeBSD アプライアンスのため azurerm_virtual_machine（汎用）を使用

# WAN (vtnet0 / primary NIC)
resource "azurerm_network_interface" "opnsense_wan" {
  count                = var.opnsense_vhd_uri != "" ? 1 : 0
  name                 = "opnsense-wan-nic"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  enable_ip_forwarding = true
  tags                 = local.tags

  ip_configuration {
    name                          = "wan"
    subnet_id                     = azurerm_subnet.external.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.1.4"
  }
}

# LAN (vtnet1)
resource "azurerm_network_interface" "opnsense_lan" {
  count                = var.opnsense_vhd_uri != "" ? 1 : 0
  name                 = "opnsense-lan-nic"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  enable_ip_forwarding = true
  tags                 = local.tags

  ip_configuration {
    name                          = "lan"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.2.4"
  }
}

resource "azurerm_virtual_machine" "opnsense" {
  count                        = var.opnsense_vhd_uri != "" ? 1 : 0
  name                         = "vm-opnsense"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  vm_size                      = "Standard_B2s"
  primary_network_interface_id = azurerm_network_interface.opnsense_wan[0].id
  tags                         = local.tags

  network_interface_ids = [
    azurerm_network_interface.opnsense_wan[0].id,
    azurerm_network_interface.opnsense_lan[0].id,
  ]

  storage_os_disk {
    name            = "opnsense-osdisk"
    managed_disk_id = azurerm_managed_disk.opnsense[0].id
    create_option   = "Attach"
    os_type         = "Linux"
    caching         = "ReadWrite"
  }

  # シリアルコンソールで起動状況を確認できるようにする
  boot_diagnostics {
    enabled     = true
    storage_uri = azurerm_storage_account.opnsense_image.primary_blob_endpoint
  }

  delete_os_disk_on_termination = false
}
