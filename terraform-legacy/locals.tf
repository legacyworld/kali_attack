locals {
  rg       = "contoso-seclab"
  location = "southeastasia"

  vnet_name = "seclab-vnet"

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
