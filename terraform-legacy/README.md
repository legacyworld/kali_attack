# terraform-legacy/（アーカイブ・使用しない）

旧・本番デモ環境（リソースグループ `contoso-seclab`）の Terraform コードです。**正式環境は [`terraform/`](../terraform/README.md) に移行済み**（攻撃チェーン版。旧 `terraform-v2/`）。

- Azure 上のリソースは destroy 済み（`terraform.tfstate` の `resources` は空）。
- 設定済み OPNsense VHD はここには置いていません（正式版は `terraform/opnsense-nano-configured.vhd`）。
- `setup-detection-rules.sh` はこの環境向け（rule_id `lab-*`）。正式環境の `lab-v2-*` とは別物です。

新しい作業はすべて `terraform/` で行ってください。このディレクトリはコードの参照用に残しているだけです。
