variable "windows_admin_password" {
  type        = string
  sensitive   = true
  description = "Windows Server AD の管理者パスワード (英大文字・小文字・数字・記号を含む12文字以上)"
}

variable "ssh_public_key" {
  type        = string
  description = "Linux VM (FortiGate / Squid / Kali) 用の SSH 公開鍵 (~/.ssh/id_rsa.pub の中身)"
}

variable "ad_safe_mode_password" {
  type        = string
  sensitive   = true
  description = "Active Directory の DSRM (ディレクトリサービス復元モード) パスワード"
}

variable "svc_account_password" {
  type        = string
  sensitive   = true
  description = "Kerberoasting シナリオ用の疑似サービスアカウント (svc-sql) のパスワード"
}

variable "opnsense_vhd_uri" {
  type        = string
  default     = ""
  description = "Azure Storage にアップロードした OPNsense VHD の blob URI。空の場合は OPNsense VM をスキップ（Step 1）"
}

variable "keep_until" {
  type    = string
  default = ""
}
