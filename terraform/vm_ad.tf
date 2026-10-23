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

  # Azure側の既定(組織ポリシー?)で true になっており、未指定だと Terraform が false に
  # 戻そうとして毎回 VM 本体の更新差分が出ていた。実際の値に合わせて固定する。
  vm_agent_platform_updates_enabled = true

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
  tags               = local.tags

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
  tags               = local.tags

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
  tags               = local.tags

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
  # 名前を変えた理由: 同名で作り直すと VM 内のハンドラが古い失敗結果（修正前スクリプト）を
  # 返し、新スクリプトが実行されなかった。リソース名を変えると別ハンドラとして実行される。
  name               = "create-svc-account-v3"
  location           = azurerm_resource_group.main.location
  virtual_machine_id = azurerm_windows_virtual_machine.ad.id
  tags               = local.tags

  source {
    script = <<-POWERSHELL
      $ErrorActionPreference = "Stop"

      # promote_dc は Install-ADDSForest -Force の完了（＝スクリプトの return）を
      # もって Succeeded になるが、実際の OS 再起動は非同期に走るため、Terraform が
      # 次のリソースへ進む時点では AD DS（ActiveDirectory モジュール・NTDS）がまだ
      # 使えないことがある（実際に発生: Import-Module/New-ADUser が軒並み失敗した）。
      # depends_on だけでは解決しないため、ここで AD DS が使えるようになるまで
      # ポーリングする（install_sysmon の接続性待ちと同じ考え方）。
      # Azure Run Command の既定タイムアウトは1800秒(30分)なので、再起動+DC起動の
      # 余裕を見て最大10分(30回 x 20秒)待つ。
      $maxAttempts = 30
      $ready = $false
      for ($i = 0; $i -lt $maxAttempts; $i++) {
        try {
          Import-Module ActiveDirectory -ErrorAction Stop
          Get-ADDomain -ErrorAction Stop | Out-Null
          $ready = $true
          break
        } catch {
          Start-Sleep -Seconds 20
        }
      }
      if (-not $ready) {
        # 注意: スクリプト内の文字列リテラルは ASCII のみにする。Run Command は Windows PowerShell 5.1 が
        # ANSI として読むため、日本語が cp1252 の引用符(0x94 等)に化けて文字列が閉じず
        # 「Missing closing '}'」のパースエラーになった（実際に発生）。
        Write-Error "AD DS did not become available after waiting 10 minutes (DC promotion reboot may not have finished)."
        exit 1
      }

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

  # AD DS の実際の起動待ちはスクリプト内のポーリングに任せるため、依存関係としては
  # promote_dc の後、の順序だけを Terraform に伝える（実行タイミングの猶予はスクリプト側で確保）。
  depends_on = [azurerm_virtual_machine_run_command.promote_dc]
}

# Sysmon 導入（Process Creation / Network Connection / DNS Query を記録）
# 「4624 (SMB認証) → 4688/Sysmon EID1 (cmd.exe 等の起動) → Sysmon EID3 (外部通信)」
# という Authentication → Execution → C2 のチェーンを Elastic 側で追跡できるようにする。
#
# インターネット（Microsoft Sysinternals からのダウンロード）が必要なため、OPNsense WAN →
# NAT Gateway の出口が無い Step 1（opnsense_vhd_uri=""）では実行できない。vm_opnsense.tf /
# image_opnsense.tf と同じ count 条件で、Step 2（OPNsense 作成）以降だけ実行する。
# OPNsense VM 自体の API 上の作成が終わっても OS が起動してルーティングできるまでは数分
# かかるため、Squid の cloud-init（vm_squid.tf）と同様に接続性を待つリトライを入れる。
#
# 注意: azurerm_virtual_machine_run_command は Azure 側の timeoutInSeconds（既定 1800秒 = 30分）を
# Terraform から変更できない（プロバイダーのスキーマに無い）。接続待ちを Squid と同じ60分にすると
# この30分の壁を超えて VMExtensionProvisioningTimeout で強制終了される（実際に発生した）。
# ダウンロード・インストール分の余裕を見て、接続待ちは最大10分に抑える。
#
# configure_audit_policy / create_svc_account と同様、DC 昇格後の再起動を経てから
# 手動で改めて apply する運用（depends_on で promote_dc を指定しない）。
resource "azurerm_virtual_machine_run_command" "install_sysmon" {
  count              = var.opnsense_vhd_uri != "" ? 1 : 0
  name               = "install-sysmon"
  location           = azurerm_resource_group.main.location
  virtual_machine_id = azurerm_windows_virtual_machine.ad.id
  tags               = local.tags

  source {
    script = <<-POWERSHELL
      $ErrorActionPreference = "Stop"
      $workDir = "C:\sysmon-install"
      New-Item -ItemType Directory -Path $workDir -Force | Out-Null

      # OPNsense 経由の出口が使えるまで待つ（Squid の cloud-init と同じ考え方。
      # Azure Run Command 自体の既定タイムアウトが30分なので、最大10分に抑える）。
      #
      # プローブ先は別の「疎通確認用エンドポイント」を探すのをやめ、実際にダウンロードしたい
      # URL 自体を HEAD で叩く（これなら「プローブ先の選定ミス」という問題自体が起きない）。
      # 経緯: 最初は https://download.sysinternals.com/ (ルートパス) を使ったが、
      # ここは 404 を返すため Invoke-WebRequest が例外を投げて「未接続」と誤判定し続けた。
      # 次に https://www.msftconnecttest.com/connecttest.txt を試したが、
      # このエンドポイントは HTTP 専用で HTTPS では証明書の信頼関係が確立できず失敗した。
      # どちらも実際には接続自体は最初から問題なかった。
      $sysmonUrl = "https://download.sysinternals.com/files/Sysmon.zip"
      $connected = $false
      for ($i = 0; $i -lt 60; $i++) {
        try {
          Invoke-WebRequest -Uri $sysmonUrl -Method Head -UseBasicParsing -TimeoutSec 5 | Out-Null
          $connected = $true
          break
        } catch {
          Start-Sleep -Seconds 10
        }
      }
      if (-not $connected) {
        Write-Error "No internet connectivity after waiting 10 minutes. Check OPNsense routing."
        exit 1
      }

      # 除外ルールなし（全件記録）の最小構成。Process Creation (EID 1) / Network Connect (EID 3) /
      # DNS Query (EID 22) を有効化する。
      # 1行約340文字の長い単一行（here-string または単一の文字列リテラル）で Azure Run Command 経由だと
      # パースエラー（The string is missing the terminator）になったため、短い行の配列に分割する。
      $sysmonConfigLines = @(
        '<Sysmon schemaversion="4.90">',
        '  <EventFiltering>',
        '    <RuleGroup name="" groupRelation="or">',
        '      <ProcessCreate onmatch="exclude" />',
        '    </RuleGroup>',
        '    <RuleGroup name="" groupRelation="or">',
        '      <NetworkConnect onmatch="exclude" />',
        '    </RuleGroup>',
        '    <RuleGroup name="" groupRelation="or">',
        '      <DnsQuery onmatch="exclude" />',
        '    </RuleGroup>',
        '  </EventFiltering>',
        '</Sysmon>'
      )
      Set-Content -Path "$workDir\sysmon-config.xml" -Value $sysmonConfigLines -Encoding ascii

      Invoke-WebRequest -Uri $sysmonUrl -OutFile "$workDir\Sysmon.zip" -UseBasicParsing
      Expand-Archive -Path "$workDir\Sysmon.zip" -DestinationPath $workDir -Force

      & "$workDir\Sysmon64.exe" -accepteula -i "$workDir\sysmon-config.xml"
      Write-Output "Sysmon installed"
    POWERSHELL
  }
}
