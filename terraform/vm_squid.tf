resource "azurerm_network_interface" "squid" {
  name                = "vm-squid-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.2.20"
  }
}

resource "azurerm_linux_virtual_machine" "squid" {
  name                            = "vm-squid"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = "Standard_B1s"
  admin_username                  = local.admin_username
  disable_password_authentication = true
  tags                            = local.tags

  # Azure側の既定で true になっており、未指定だと Terraform が false に戻そうとして
  # 毎回 VM 本体の更新差分が出ていた。実際の値に合わせて固定する。
  vm_agent_platform_updates_enabled = true

  network_interface_ids = [azurerm_network_interface.squid.id]

  admin_ssh_key {
    username   = local.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init で Squid をインストール・設定する
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: false
    package_upgrade: false
    write_files:
      # squid.conf の設定衝突の質問を避けるため、インストール後に runcmd で配置する
      - path: /root/squid-lab.conf
        content: |
          http_port 3128
          # ラボ内からのみアクセスを許可
          acl lab_net src 10.10.0.0/16
          http_access allow lab_net
          http_access deny all
          # アクセスログを詳細形式で記録（Elastic Agent が収集）
          access_log /var/log/squid/access.log squid
          cache_log /var/log/squid/cache.log
          # キャッシュなし（ログを確実に残すため）
          cache deny all
          visible_hostname squid-lab
    runcmd:
      # OPNsense 経由の出口が使えるまで待つ（Step 2 で OPNsense が起動するため、最大 60 分）
      - |
        for i in $(seq 1 360); do
          curl -sI --max-time 5 http://azure.archive.ubuntu.com >/dev/null && break
          sleep 10
        done
      - apt-get update
      - DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confnew squid
      - cp /root/squid-lab.conf /etc/squid/squid.conf
      - systemctl enable squid
      - systemctl restart squid
  CLOUDINIT
  )
}
