# Arista AVD 6.3 Tenant + VRF Scaffold

Canonical inventory groups:

- FABRIC
- SPINES
- LEAFS
- NETWORK_SERVICES
- CONNECTED_ENDPOINTS

Canonical devices:

- DC1-Spine1
- DC1-Spine2
- DC1-Leaf1
- DC1-Leaf2
- DC1-Leaf3
- DC1-Leaf4

## Tenant and VRF model

```text
Tenant1
├── VRF11
└── VRF12

Tenant2
├── VRF21
└── VRF22
```

Tenant files:

```text
group_vars/NETWORK_SERVICES/Tenant1.yml
group_vars/NETWORK_SERVICES/Tenant2.yml
```

`Tenant1 / VRF11` retains the existing VLAN 100 service so the connected endpoint definitions on DC1-Leaf1 and DC1-Leaf4 remain valid.

VRFs without an SVI or L3 interface are placeholders. Add services under the matching VRF before expecting that VRF to render in EOS configuration.

## Host-specific variables

Use these only for configuration that genuinely applies to one switch:

```text
host_vars/DC1-Spine1.yml
host_vars/DC1-Spine2.yml
host_vars/DC1-Leaf1.yml
host_vars/DC1-Leaf2.yml
host_vars/DC1-Leaf3.yml
host_vars/DC1-Leaf4.yml
```

## Encrypted Vault

The archive does not contain credentials. Preserve an existing encrypted file at:

```text
group_vars/FABRIC/vault.yml
```

To create a new encrypted Vault:

```bash
source .venv/bin/activate && ./scripts/create_vault.sh
```

The encrypted file must contain:

```yaml
---
vault_ansible_user: EOS_USERNAME
vault_ansible_password: EOS_PASSWORD
```

## Install

```bash
python3 -m venv .venv && source .venv/bin/activate && python -m pip install --upgrade pip && python -m pip install -r requirements.txt && ansible-galaxy collection install -r collections/requirements.yml -p collections
```

## Test and build

```bash
source .venv/bin/activate && ansible FABRIC --ask-vault-pass -m arista.eos.eos_command -a '{"commands":["show hostname"]}'
```

```bash
source .venv/bin/activate && ansible-playbook build.yml --ask-vault-pass
```

## Deploy

Review all files under `intended/configs` before deployment.

```bash
source .venv/bin/activate && ansible-playbook deploy.yml --ask-vault-pass --diff
```

Pre- and post-deployment backups are written under `config_backup/`.
# AVD-MultiTenant1
