locals {
  # メインラボ (../terraform) とは別の RG / VNet / state にして干渉しないようにする
  rg        = "contoso-opnsense-debug"
  location  = "southeastasia"
  vnet_name = "opnsense-debug-vnet"

  keep_until = var.keep_until != "" ? var.keep_until : formatdate("YYYY-MM-DD", timeadd(timestamp(), "168h"))

  tags = {
    division   = "field"
    org        = "sa"
    keep-until = local.keep_until
    team       = "apj_japan"
    project    = "contoso"
  }
}
