variable "opnsense_vhd_uri" {
  type        = string
  default     = ""
  description = "アップロード済み OPNsense VHD の blob URI。空の間は OPNsense VM を作らない (Step 1)"
}

variable "keep_until" {
  type    = string
  default = ""
}
