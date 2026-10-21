// Arista AVD 6.3 / EVPN-VXLAN lab pipeline
// Repository: kokedama999/AVD-MultiTenant1
// By default GitHub pushes BUILD ONLY. Deployment requires DEPLOY=true
// and a separate, interactive Jenkins approval.
//
// Required Jenkins credentials:
//   github-avd          : Username/Password (GitHub username + PAT with repository read access)
//   avd-vault-file      : Secret file (encrypted group_vars/FABRIC/vault.yml)
//   ask-vault-pass     : Secret text (Ansible Vault password; existing Jenkins credential ID)

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
            defaultValue: false,
            description: 'OFF by default. Turn ON to compare running configs, request approval and deploy.'
        )
        choice(
            name: 'TARGET',
            choices: ['DC1-Leaf1', 'DC1-Leaf2', 'DC1-Leaf3', 'DC1-Leaf4',
                      'DC1-Spine1', 'DC1-Spine2', 'LEAFS', 'SPINES', 'FABRIC'],
            description: 'Deployment target (the full fabric is ALWAYS built).'
        )
    }

    environment {
        REPO_URL = 'https://github.com/kokedama999/AVD-MultiTenant1.git'
        REPO_BRANCH = 'main'
        ANSIBLE_NOCOLOR = '1'
        PYTHONUNBUFFERED = '1'
    }

    stages {
        stage('1 - Checkout from GitHub') {
            steps {
                deleteDir()
                git branch: env.REPO_BRANCH,
                    credentialsId: 'github-avd',
                    url: env.REPO_URL
                sh 'git log -1 --format="Commit: %h %s"'
            }
        }

        stage('2 - Install Ansible and AVD') {
            steps {
                sh '''#!/usr/bin/env bash
set -euo pipefail
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r requirements.txt
ansible-galaxy collection install -r collections/requirements.yml -p collections
ansible --version | head -n 3
ansible-galaxy collection list arista.avd
'''
            }
        }

        stage('3 - Syntax check and AVD build') {
            steps {
                withCredentials([
                    file(credentialsId: 'avd-vault-file', variable: 'ENCRYPTED_VAULT_FILE'),
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
# This encrypted vault is deliberately NOT stored in Git.
head -n 1 "$ENCRYPTED_VAULT_FILE" | grep -q 'ANSIBLE_VAULT' || {
    echo 'Expected an encrypted Ansible Vault file in avd-vault-file.' >&2
    exit 1
}
install -m 600 "$ENCRYPTED_VAULT_FILE" group_vars/FABRIC/vault.yml
source .venv/bin/activate
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
                echo 'Build complete. GitHub push builds stop here unless DEPLOY was enabled.'
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
source .venv/bin/activate
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
source .venv/bin/activate
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
source .venv/bin/activate
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
            archiveArtifacts artifacts: 'running_snapshots/*.cfg,config_backup/*.conf',
                             allowEmptyArchive: true
            sh '''#!/usr/bin/env bash
set -e
# Remove the temporary encrypted vault from the workspace after EVERY build.
rm -f group_vars/FABRIC/vault.yml .jenkins_running_snapshot.yml
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
