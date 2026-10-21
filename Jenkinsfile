pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timestamps()
        skipDefaultCheckout(true)
    }

    parameters {
        booleanParam(name: 'DEPLOY', defaultValue: false,
                     description: 'Enable deployment after review and manual approval')
        choice(name: 'TARGET', choices: ['FABRIC', 'SPINES', 'LEAFS', 'DC1-Leaf1', 'DC1-Leaf2', 'DC1-Leaf3', 'DC1-Leaf4'],
               description: 'Devices to deploy to (build always renders the full fabric)')
    }

    environment {
        // Persistent across workspace cleanups. Jenkins must be able to write here.
        AVD_CACHE = '/var/lib/jenkins/avd-cache'
        ANSIBLE_COLLECTIONS_PATH = '/var/lib/jenkins/avd-cache/collections'
        ANSIBLE_CONFIG = 'ansible.cfg'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Prepare Ansible (cached)') {
            steps {
                sh '''
                    set -eu
                    mkdir -p "$AVD_CACHE" "$ANSIBLE_COLLECTIONS_PATH"
                    CACHE_HASH=$(cat requirements.txt collections/requirements.yml | sha256sum | awk '{print $1}')

                    if [ ! -x "$AVD_CACHE/venv/bin/ansible-playbook" ] || \
                       [ ! -f "$AVD_CACHE/requirements.sha256" ] || \
                       [ "$(cat "$AVD_CACHE/requirements.sha256")" != "$CACHE_HASH" ]; then
                        echo 'Installing/updating pinned Ansible and Arista collections...'
                        python3 -m venv "$AVD_CACHE/venv"
                        "$AVD_CACHE/venv/bin/python" -m pip install -r requirements.txt
                        "$AVD_CACHE/venv/bin/ansible-galaxy" collection install \
                            -r collections/requirements.yml \
                            -p "$ANSIBLE_COLLECTIONS_PATH" --force
                        printf '%s\n' "$CACHE_HASH" > "$AVD_CACHE/requirements.sha256"
                    else
                        echo 'Using cached Ansible and Arista AVD; skipping installation.'
                    fi
                    "$AVD_CACHE/venv/bin/ansible-playbook" --version | head -n 2
                '''
            }
        }

        stage('Build AVD configurations') {
            steps {
                withCredentials([
                    file(credentialsId: 'avd-vault-file', variable: 'VAULT_FILE'),
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''
                        set -eu
                        umask 077
                        PASS_FILE=$(mktemp)
                        mkdir -p group_vars/FABRIC
                        trap 'rm -f "$PASS_FILE" group_vars/FABRIC/vault.yml' EXIT

                        cp "$VAULT_FILE" group_vars/FABRIC/vault.yml
                        printf '%s\n' "$VAULT_PASSWORD" > "$PASS_FILE"

                        "$AVD_CACHE/venv/bin/ansible-playbook" \
                            -i inventory.yml build.yml --vault-password-file "$PASS_FILE"
                    '''
                }
            }
        }

        stage('Archive intended configurations') {
            steps {
                archiveArtifacts artifacts: 'intended/configs/*.cfg,intended/structured_configs/*.yml,documentation/**',
                                 allowEmptyArchive: false, fingerprint: true
                echo 'Inspect the generated .cfg files under this build\'s Artifacts before approving deployment.'
            }
        }

        stage('Approve deployment') {
            when { expression { params.DEPLOY } }
            steps {
                input message: "Review the generated configuration artifacts. Deploy to ${params.TARGET}?",
                      ok: 'Approve deployment'
            }
        }

        stage('Deploy to Arista') {
            when { expression { params.DEPLOY } }
            steps {
                withCredentials([
                    file(credentialsId: 'avd-vault-file', variable: 'VAULT_FILE'),
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''
                        set -eu
                        umask 077
                        PASS_FILE=$(mktemp)
                        mkdir -p group_vars/FABRIC
                        trap 'rm -f "$PASS_FILE" group_vars/FABRIC/vault.yml' EXIT

                        cp "$VAULT_FILE" group_vars/FABRIC/vault.yml
                        printf '%s\n' "$VAULT_PASSWORD" > "$PASS_FILE"

                        "$AVD_CACHE/venv/bin/ansible-playbook" \
                            -i inventory.yml deploy.yml \
                            --limit "$TARGET" --vault-password-file "$PASS_FILE" --diff
                    '''
                }
            }
        }

        stage('Verify EVPN neighbour status') {
            when { expression { params.DEPLOY } }
            steps {
                withCredentials([
                    file(credentialsId: 'avd-vault-file', variable: 'VAULT_FILE'),
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''
                        set -eu
                        umask 077
                        PASS_FILE=$(mktemp)
                        mkdir -p group_vars/FABRIC
                        trap 'rm -f "$PASS_FILE" group_vars/FABRIC/vault.yml' EXIT

                        cp "$VAULT_FILE" group_vars/FABRIC/vault.yml
                        printf '%s\n' "$VAULT_PASSWORD" > "$PASS_FILE"

                        "$AVD_CACHE/venv/bin/ansible" LEAFS -i inventory.yml \
                            --limit "$TARGET" \
                            -m arista.eos.eos_command \
                            -a '{"commands":["show bgp evpn summary"]}' \
                            --vault-password-file "$PASS_FILE"
                    '''
                }
            }
        }
    }

    post {
        always {
            sh 'rm -f group_vars/FABRIC/vault.yml .vault_pass || true'
        }
    }
}
