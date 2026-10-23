locals {
  rg       = "contoso-seclab-v2"
  location = "southeastasia"

  vnet_name = "seclab-v2-vnet"

  admin_username = "elastic"

  keep_until = var.keep_until != "" ? var.keep_until : formatdate("YYYY-MM-DD", timeadd(timestamp(), "168h"))

  tags = {
    division   = "field"
    org        = "sa"
    keep-until = local.keep_until
    team       = "apj_japan"
    project    = "contoso"
  }
}
