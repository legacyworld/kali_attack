# Elastic Security 攻撃シミュレーション ラボ

OPNsense（ファイアウォール）/ Squid（プロキシ）/ Windows Server AD の 3 層ログ環境を Azure VM で再現し、Kali 相当の Ubuntu VM から攻撃を仕掛けて Elastic Security でアラートを検証するラボです。

## ディレクトリ構成

| ディレクトリ | 役割 |
|---|---|
| **[terraform/](terraform/README.md)** | **正式環境。** 攻撃チェーン版（Password Spray → Discovery → Kerberoasting → Lateral Movement → C2 Beacon）。リソースグループ `contoso-seclab-v2`。デプロイ・攻撃シナリオ・検知ルールの詳細は [terraform/README.md](terraform/README.md) を参照 |

Claude 向けの詳細な作業ルール（Azure 環境の制約、OPNsense デプロイの特殊事情など）は [CLAUDE.md](CLAUDE.md) を参照してください。
