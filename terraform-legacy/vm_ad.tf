resource "azurerm_network_interface" "ad" {
  name                = "vm-ad-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.2.10"
  }
}

resource "azurerm_windows_virtual_machine" "ad" {
  name                = "vm-ad"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = "Standard_B2ms"
  admin_username      = local.admin_username
  admin_password      = var.windows_admin_password
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.ad.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }
}

# AD DS インストール + ドメインコントローラー昇格
resource "azurerm_virtual_machine_run_command" "install_adds" {
  name               = "install-adds"
  location           = azurerm_resource_group.main.location
  virtual_machine_id = azurerm_windows_virtual_machine.ad.id

  source {
    script = <<-POWERSHELL
      Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
      Write-Output "AD-Domain-Services installed"
    POWERSHELL
  }
}

resource "azurerm_virtual_machine_run_command" "promote_dc" {
  name               = "promote-dc"
  location           = azurerm_resource_group.main.location
  virtual_machine_id = azurerm_windows_virtual_machine.ad.id

  source {
    script = <<-POWERSHELL
      $safePwd = ConvertTo-SecureString "${var.ad_safe_mode_password}" -AsPlainText -Force
      Import-Module ADDSDeployment
      Install-ADDSForest `
        -DomainName "lab.local" `
        -DomainNetbiosName "LAB" `
        -SafeModeAdministratorPassword $safePwd `
        -InstallDns `
        -Force
    POWERSHELL
  }

  depends_on = [azurerm_virtual_machine_run_command.install_adds]
}

# 監査ポリシー強化（失敗ログオン・Kerberos などを記録）
resource "azurerm_virtual_machine_run_command" "configure_audit_policy" {
  name               = "configure-audit-policy"
  location           = azurerm_resource_group.main.location
  virtual_machine_id = azurerm_windows_virtual_machine.ad.id

  source {
    script = <<-POWERSHELL
      auditpol /set /subcategory:"Logon"                    /success:enable /failure:enable
      auditpol /set /subcategory:"Logoff"                   /success:enable /failure:enable
      auditpol /set /subcategory:"Account Lockout"          /success:enable /failure:enable
      auditpol /set /subcategory:"Kerberos Authentication Service" /success:enable /failure:enable
      auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable /failure:enable
      auditpol /set /subcategory:"Other Account Logon Events" /success:enable /failure:enable
      auditpol /set /subcategory:"User Account Management"  /success:enable /failure:enable
      auditpol /set /subcategory:"Computer Account Management" /success:enable /failure:enable
      Write-Output "Audit policy configured"
    POWERSHELL
  }

  # DC 昇格後（再起動を経た後）に手動実行を想定。自動化する場合は depends_on で promote_dc を指定
}

# Kerberoasting シナリオ用の疑似サービスアカウント（SPN 付き）
resource "azurerm_virtual_machine_run_command" "create_svc_account" {
  name               = "create-svc-account"
  location           = azurerm_resource_group.main.location
  virtual_machine_id = azurerm_windows_virtual_machine.ad.id

  source {
    script = <<-POWERSHELL
      Import-Module ActiveDirectory
      $pwd = ConvertTo-SecureString "${var.svc_account_password}" -AsPlainText -Force
      # 再実行しても同じ結果になるよう、既存ならパスワードだけ合わせ直す
      # （過去の試行でアカウントだけ作られて途中で失敗していても復旧できる）。
      $existing = Get-ADUser -Filter 'SamAccountName -eq "svc-sql"' -ErrorAction SilentlyContinue
      if ($existing) {
        Set-ADAccountPassword -Identity "svc-sql" -Reset -NewPassword $pwd
        Set-ADUser -Identity "svc-sql" -Enabled $true -PasswordNeverExpires $true
      } else {
        New-ADUser -Name "svc-sql" -SamAccountName "svc-sql" `
          -AccountPassword $pwd -Enabled $true -PasswordNeverExpires $true `
          -ErrorAction Stop
      }
      # SPN が未登録のときだけ登録する（重複登録のエラーを避ける）
      $spn = "MSSQLSvc/sqlserver.lab.local:1433"
      $registered = Get-ADUser -Identity "svc-sql" -Properties ServicePrincipalName
      if ($registered.ServicePrincipalName -notcontains $spn) {
        setspn -A $spn svc-sql
      }
      # Server 2022 は 2022-11 以降の累積更新（CVE-2022-37966 対策）で
      # msDS-SupportedEncryptionTypes 未設定のアカウントに RC4 TGS を既定で拒否する。
      # AES も許可すると KDC が AES256 を優先して発行し、Elastic の検知ルール
      # 「Newly Observed RC4 Kerberos Service Ticket Request」が
      # TicketEncryptionType:0x17（RC4）を明示的に要求しているため発火しなくなる。
      # Kerberoasting 教材として RC4 ハッシュ（$krb5tgs$23$）を取得できるよう RC4 のみ許可する。
      Set-ADUser -Identity "svc-sql" -KerberosEncryptionType RC4
      Write-Output "svc-sql created with SPN MSSQLSvc/sqlserver.lab.local:1433"
    POWERSHELL
  }

  # configure_audit_policy と同様、DC 昇格後の再起動を経てから実行する想定。
  # DC 昇格直後の apply では VM がまだ再起動中の可能性があるため、depends_on で
  # promote_dc を指定せず、再起動完了を確認してから改めて apply する運用とする。
}
