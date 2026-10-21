// Arista AVD 6.3 / EVPN-VXLAN lab pipeline
// Repository: kokedama999/AVD-MultiTenant1
// GitHub pushes BUILD the configs, then request MANUAL APPROVAL before DEPLOY.
// Ansible/AVD dependencies are cached OUTSIDE the Jenkins workspace.
// Only install on first run or when requirements change.
// DEPLOY=true by default; approval is always required before switches change.
//
// Required Jenkins credentials:
//   github-avd          : Username/Password (GitHub username + PAT with repository read access)
//   ask-vault-pass      : Secret text (Ansible Vault password)
// Use the existing encrypted group_vars/FABRIC/vault.yml in the job workspace.
// Jenkins will not move, overwrite, or delete your existing vault file.

pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 90, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '15', artifactNumToKeepStr: '10'))
    }

    // Requires the Jenkins GitHub plugin and a working /github-webhook/ endpoint.
    triggers {
        githubPush()
    }

    parameters {
        booleanParam(
            name: 'DEPLOY',
            defaultValue: true,
            description: 'Build configs, review running-vs-intended diff and request approval to deploy. Turn OFF for build-only.'
        )
        choice(
            name: 'TARGET',
            choices: ['FABRIC', 'LEAFS', 'SPINES', 'DC1-Leaf1', 'DC1-Leaf2', 'DC1-Leaf3', 'DC1-Leaf4',
                      'DC1-Spine1', 'DC1-Spine2'],
            description: 'Deployment target (the full fabric is ALWAYS built).'
        )
    }

    environment {
        REPO_URL = 'https://github.com/kokedama999/AVD-MultiTenant1.git'
        REPO_BRANCH = 'main'
        AVD_VENV = '/var/lib/jenkins/avd-cache/venv'
        ANSIBLE_COLLECTIONS_PATH = '/var/lib/jenkins/avd-cache/collections'
        AVD_DEPS_FINGERPRINT = '/var/lib/jenkins/avd-cache/requirements.sha256'
        ANSIBLE_NOCOLOR = '1'
        PYTHONUNBUFFERED = '1'
    }

    stages {
        stage('1 - Checkout from GitHub') {
            steps {
                // Do not delete workspace: vault.yml is Git-ignored and must be preserved.
                git branch: env.REPO_BRANCH,
                    credentialsId: 'github-avd',
                    url: env.REPO_URL
                sh 'git log -1 --format="Commit: %h %s"'
            }
        }

        stage('2 - Reuse cached Ansible and AVD') {
            steps {
                sh '''#!/usr/bin/env bash
set -euo pipefail

# The checkout stage deletes the WORKSPACE, not this server-side cache.
# Keep Ansible and Arista collections between Jenkins builds.
cache_dir="$(dirname "$AVD_VENV")"
mkdir -p "$cache_dir" "$ANSIBLE_COLLECTIONS_PATH"
requested_hash="$(sha256sum requirements.txt collections/requirements.yml | sha256sum | awk '{print $1}')"

if [[ -x "$AVD_VENV/bin/ansible-playbook" \
      && -f "$AVD_DEPS_FINGERPRINT" \
      && "$(cat "$AVD_DEPS_FINGERPRINT")" == "$requested_hash" \
      && -f "$ANSIBLE_COLLECTIONS_PATH/ansible_collections/arista/avd/MANIFEST.json" \
      && -f "$ANSIBLE_COLLECTIONS_PATH/ansible_collections/arista/eos/MANIFEST.json" ]]; then
    echo 'Cached Ansible and Arista AVD found - skipping pip and Ansible Galaxy installation.'
else
    echo 'First run, incomplete cache, or requirements changed - installing dependencies.'
    if [[ ! -x "$AVD_VENV/bin/python" ]]; then
        python3 -m venv "$AVD_VENV"
    fi
    source "$AVD_VENV/bin/activate"
    python -m pip install --quiet -r requirements.txt
    ansible-galaxy collection install -r collections/requirements.yml \
        -p "$ANSIBLE_COLLECTIONS_PATH" --force
    printf '%s\n' "$requested_hash" > "$AVD_DEPS_FINGERPRINT.tmp"
    mv "$AVD_DEPS_FINGERPRINT.tmp" "$AVD_DEPS_FINGERPRINT"
fi

source "$AVD_VENV/bin/activate"
ansible --version
ansible-galaxy collection list arista.avd
'''
            }
        }

        stage('3 - Syntax check and AVD build') {
            steps {
                withCredentials([
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''#!/usr/bin/env bash
set -euo pipefail
# Jenkins secret-text credential "ask-vault-pass" is not an Ansible CLI option.
# Convert it to a restricted, short-lived file for non-interactive Vault use.
umask 077
VAULT_PASSWORD_FILE="$(mktemp)"
trap 'rm -f "$VAULT_PASSWORD_FILE"' EXIT
printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE"
# Keep the existing encrypted group_vars/FABRIC/vault.yml untouched.
# Git ignores it; the checkout stage must not clean/delete the workspace.
source "$AVD_VENV/bin/activate"
ansible-inventory -i inventory.yml --graph
ansible-playbook -i inventory.yml build.yml \
    --vault-password-file "$VAULT_PASSWORD_FILE" --syntax-check
ansible-playbook -i inventory.yml build.yml \
    --vault-password-file "$VAULT_PASSWORD_FILE"

# Stop the pipeline if AVD failed to render ANY of the six devices.
for device in DC1-Spine1 DC1-Spine2 DC1-Leaf1 DC1-Leaf2 DC1-Leaf3 DC1-Leaf4; do
    test -s "intended/configs/${device}.cfg" || {
        echo "Missing intended configuration for ${device}" >&2
        exit 1
    }
done
'''
                }
            }
        }

        stage('4 - Publish intended configurations') {
            steps {
                // Treat configuration and topology artifacts as sensitive data.
                archiveArtifacts artifacts: 'intended/configs/*.cfg,documentation/**/*',
                                 allowEmptyArchive: false
                echo 'AVD build complete. Deployment is next if DEPLOY is enabled, after config diff and manual approval.'
            }
        }

        stage('5 - Capture running configs and create diffs') {
            when {
                expression { return params.DEPLOY }
            }
            steps {
                withCredentials([
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''#!/usr/bin/env bash
set -euo pipefail
# Jenkins secret-text credential "ask-vault-pass" is not an Ansible CLI option.
# Convert it to a restricted, short-lived file for non-interactive Vault use.
umask 077
VAULT_PASSWORD_FILE="$(mktemp)"
trap 'rm -f "$VAULT_PASSWORD_FILE"' EXIT
printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE"
source "$AVD_VENV/bin/activate"
mkdir -p running_snapshots config_diff

# Temporary read-only playbook. arista.eos.eos_config backup:true
# reads the running configuration; there is no configuration input here.
cat > .jenkins_running_snapshot.yml <<'YAML'
---
- name: Capture pre-deployment running configurations
  hosts: FABRIC
  gather_facts: false
  tasks:
    - name: Back up current running config
      arista.eos.eos_config:
        backup: true
        backup_options:
          dir_path: "{{ playbook_dir }}/running_snapshots"
          filename: "{{ inventory_hostname }}.cfg"
YAML

ansible-playbook -i inventory.yml .jenkins_running_snapshot.yml \
    --vault-password-file "$VAULT_PASSWORD_FILE" --limit "$TARGET"

# Produce unified text diffs for ALL selected hosts. diff exit 1 means
# a difference, not a pipeline failure; status 2+ is an error.
count=0
while IFS= read -r device; do
    [[ -n "$device" ]] || continue
    running="running_snapshots/${device}.cfg"
    intended="intended/configs/${device}.cfg"
    test -s "$running" || { echo "Missing running backup: $running" >&2; exit 1; }
    test -s "$intended" || { echo "Missing intended config: $intended" >&2; exit 1; }

    if diff -u --label "${device}:running" --label "${device}:intended" \
        "$running" "$intended" > "config_diff/${device}.diff"; then
        echo "${device}: no textual changes"
    else
        result=$?
        [[ "$result" -eq 1 ]] || exit "$result"
        echo "${device}: CHANGED - inspect config_diff/${device}.diff"
    fi
    count=$((count + 1))
done < <(ansible -i inventory.yml "$TARGET" --list-hosts \
    --vault-password-file "$VAULT_PASSWORD_FILE" | tail -n +2 | sed 's/^[[:space:]]*//')

[[ "$count" -gt 0 ]] || { echo 'No devices selected' >&2; exit 1; }
echo "Generated running-vs-intended textual diffs for $count device(s)."
'''
                }
                archiveArtifacts artifacts: 'config_diff/*.diff', allowEmptyArchive: false
            }
        }

        stage('6 - MANUAL APPROVAL') {
            when {
                expression { return params.DEPLOY }
            }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Review the archived config_diff artifacts. Deploy to ${params.TARGET}?",
                          ok: 'Approve deployment'
                }
            }
        }

        stage('7 - Deploy via Arista eAPI') {
            when {
                expression { return params.DEPLOY }
            }
            steps {
                withCredentials([
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''#!/usr/bin/env bash
set -euo pipefail
# Jenkins secret-text credential "ask-vault-pass" is not an Ansible CLI option.
# Convert it to a restricted, short-lived file for non-interactive Vault use.
umask 077
VAULT_PASSWORD_FILE="$(mktemp)"
trap 'rm -f "$VAULT_PASSWORD_FILE"' EXIT
printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE"
source "$AVD_VENV/bin/activate"
# The repository's deploy.yml includes serial: 1 and pre-change backups.
# This role may REPLACE the full running configuration; approval is required.
ansible-playbook -i inventory.yml deploy.yml \
    --vault-password-file "$VAULT_PASSWORD_FILE" --limit "$TARGET"
'''
                }
            }
        }

        stage('8 - Post-deployment BGP checks') {
            when {
                expression { return params.DEPLOY }
            }
            steps {
                withCredentials([
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''#!/usr/bin/env bash
set -euo pipefail
# Jenkins secret-text credential "ask-vault-pass" is not an Ansible CLI option.
# Convert it to a restricted, short-lived file for non-interactive Vault use.
umask 077
VAULT_PASSWORD_FILE="$(mktemp)"
trap 'rm -f "$VAULT_PASSWORD_FILE"' EXIT
printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE"
source "$AVD_VENV/bin/activate"
# Displays neighbour state. Follow up with ANTA/assertions to fail on bad state.
ansible -i inventory.yml "$TARGET" -m arista.eos.eos_command \
    -a '{"commands":["show ip bgp summary","show bgp evpn summary"]}' \
    --vault-password-file "$VAULT_PASSWORD_FILE"
'''
                }
            }
        }
    }

    post {
        always {
            // Keep backups for troubleshooting/rollback; restrict Jenkins access.
            archiveArtifacts artifacts: 'running_snapshots/*.cfg,config_backup/**/*',
                             allowEmptyArchive: true
            sh '''#!/usr/bin/env bash
set -e
# Never remove the existing encrypted Vault file.
rm -f .jenkins_running_snapshot.yml
'''
        }
        success {
            echo 'Pipeline passed.'
        }
        failure {
            echo 'Pipeline failed. Inspect Jenkins console output and artifacts.'
        }
    }
}
