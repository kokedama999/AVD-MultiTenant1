#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v ansible-vault >/dev/null 2>&1; then
  echo "ERROR: ansible-vault is not available. Activate .venv first."
  exit 1
fi

if [[ -f group_vars/FABRIC/vault.yml ]]; then
  echo "ERROR: group_vars/FABRIC/vault.yml already exists. Nothing changed."
  exit 1
fi

cat > /tmp/avd-vault.yml <<'VAULT'
---
vault_ansible_user: YOUR_EOS_USERNAME
vault_ansible_password: YOUR_EOS_PASSWORD
VAULT

${EDITOR:-vi} /tmp/avd-vault.yml
ansible-vault encrypt --output group_vars/FABRIC/vault.yml /tmp/avd-vault.yml
rm -f /tmp/avd-vault.yml
chmod 600 group_vars/FABRIC/vault.yml

echo "Created encrypted group_vars/FABRIC/vault.yml"
