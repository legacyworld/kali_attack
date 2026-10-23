resource "azurerm_resource_group" "main" {
  name     = local.rg
  location = local.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = local.vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.10.0.0/16"]
  tags                = local.tags
}

# Bastion サブネット名は "AzureBastionSubnet" で固定（Azure の要件）
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.0.0/26"]
}

# FortiGate WAN 側 + Kali (攻撃元) を同居させる外部サブネット
resource "azurerm_subnet" "external" {
  name                 = "external-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.1.0/24"]
}

# FortiGate LAN 側 + AD + Squid を置く内部サブネット
resource "azurerm_subnet" "internal" {
  name                 = "internal-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.2.0/24"]
}

# ---- NAT Gateway: external-subnet の送信（OPNsense WAN → インターネット）----
# 新規 VNet のサブネットは default outbound access が無効のため、明示的な出口が必要。
# VM にパブリック IP を付けずに済ませるため NAT Gateway を使う。
resource "azurerm_public_ip" "nat" {
  name                = "seclab-nat-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "main" {
  name                = "seclab-natgw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "external" {
  subnet_id      = azurerm_subnet.external.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# ---- Route Table: external-subnet ----
# Kali から internal-subnet への通信が FortiGate WAN NIC を通過するようにする
resource "azurerm_route_table" "external" {
  name                = "rt-external"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  route {
    name                   = "to-internal-via-fgt-wan"
    address_prefix         = "10.10.2.0/24"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.10.1.4"
  }
}

resource "azurerm_subnet_route_table_association" "external" {
  subnet_id      = azurerm_subnet.external.id
  route_table_id = azurerm_route_table.external.id
}

# ---- Route Table: internal-subnet ----
# AD / Squid からの全アウトバウンドと external-subnet 向きを FortiGate LAN NIC 経由にする
# 10.10.0.0/16 の VNet システムルートが /0 より具体的なため、Bastion への戻りは VnetLocal になる
resource "azurerm_route_table" "internal" {
  name                = "rt-internal"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  # Kali (external-subnet) への応答を FortiGate 経由にして双方向ログを取る
  route {
    name                   = "to-external-via-fgt-lan"
    address_prefix         = "10.10.1.0/24"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.10.2.4"
  }

  # インターネット向きは OPNsense でログ取得 + Web フィルタ適用
  route {
    name                   = "default-via-opnsense-lan"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.10.2.4"
  }
}

resource "azurerm_subnet_route_table_association" "internal" {
  subnet_id      = azurerm_subnet.internal.id
  route_table_id = azurerm_route_table.internal.id
}

# ---- Bastion ----
resource "azurerm_public_ip" "bastion" {
  name                = "seclab-bastion-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# NSG は意図的に付けない（組織の Azure Policy が特定ポートを含む NSG を拒否するため）
resource "azurerm_bastion_host" "main" {
  name                = "seclab-bastion"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  tunneling_enabled   = true
  ip_connect_enabled  = true

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = local.tags
}
