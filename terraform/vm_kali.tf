# kali-linux Marketplace イメージは削除済みのため Ubuntu 22.04 + 攻撃ツール構成に切り替え
resource "azurerm_network_interface" "kali" {
  name                = "vm-kali-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "external"
    subnet_id                     = azurerm_subnet.external.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.1.10"
  }
}

resource "azurerm_linux_virtual_machine" "kali" {
  name                            = "vm-kali"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = "Standard_B2s"
  admin_username                  = local.admin_username
  disable_password_authentication = true
  tags                            = local.tags

  # Azure側の既定で true になっており、未指定だと Terraform が false に戻そうとして
  # 毎回 VM 本体の更新差分が出ていた。実際の値に合わせて固定する。
  vm_agent_platform_updates_enabled = true

  network_interface_ids = [azurerm_network_interface.kali.id]

  admin_ssh_key {
    username   = local.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init で攻撃ツール一式をインストール
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    package_upgrade: false
    packages:
      - nmap
      - hydra
      - smbclient
      - proxychains4
      - gobuster
      - netcat-openbsd
      - python3-pip
      - python3-venv
      - software-properties-common
      - pipx
      - git
      - curl
      - jq
    runcmd:
      # Ubuntu 22.04 既定の pip (22.0.2) は PEP 668 以前のため --break-system-packages 非対応。
      # つけると不明オプションで即エラーになり、cloud-init ログに "impacket" の痕跡すら残らない。
      - pip3 install impacket
      # needrestart の対話ダイアログを抑止（自動再起動を許可）
      - echo '$nrconf{restart} = "a";' > /etc/needrestart/conf.d/50-autorestart.conf
      # NetExec (nxc) は PyPI 未配布・Python >=3.11 必須のため、
      # deadsnakes PPA で 3.11 を追加し、GitHub から pipx 経由でインストールする
      - add-apt-repository -y ppa:deadsnakes/ppa
      - apt-get update
      - apt-get install -y python3.11 python3.11-venv python3.11-dev
      - su - ${local.admin_username} -c "pipx ensurepath"
      - su - ${local.admin_username} -c "pipx install --python python3.11 git+https://github.com/Pennyw0rth/NetExec"
      - ln -sf /home/${local.admin_username}/.local/bin/nxc /usr/local/bin/nxc
      - curl https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb -o /tmp/msfinstall
      - chmod +x /tmp/msfinstall
      - /tmp/msfinstall
  CLOUDINIT
  )
}
