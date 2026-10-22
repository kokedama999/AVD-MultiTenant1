// ARISTA AVD CI/CD PIPELINE - learning edition
// ------------------------------------------------------------
// Pull request (PR): generate EOS configs, archive them, and commit
// changed .cfg files back to the PR branch for GitHub review.
// main branch: deploy the ALREADY GENERATED configs from GitHub.
// No manual approval and no post-deployment verification stage.
// All Vault credential IDs and authentication commands are unchanged.
// Jenkins job type: Multibranch Pipeline with GitHub Branch Source.
pipeline {
    // Jenkins can allocate any eligible agent/node to execute this job.
    agent any

    // Pipeline-wide settings; these do not alter network configuration.
    options {
        // Avoid two runs touching the same worktree or target fabric concurrently.
        disableConcurrentBuilds()
        // Timestamp each console line to simplify troubleshooting.
        timestamps()
        // We explicitly perform checkout in our first stage instead.
        skipDefaultCheckout(true)
    }

    // These paths are shared by stages. The cache survives workspace cleanups.
    environment {
        // Persistent Python virtual environment + install-version marker.
        AVD_CACHE = '/var/lib/jenkins/avd-cache' 
        // Ansible searches here for arista.avd and its dependencies.
        ANSIBLE_COLLECTIONS_PATH = '/var/lib/jenkins/avd-cache/collections' 
        // Reuse this repository's Ansible defaults and inventory settings.
        ANSIBLE_CONFIG = 'ansible.cfg' 
    }

    stages {
        // ------------------------------------------------------------
        // STAGE 1: Get code from the branch that triggered Jenkins.
        // For a PR, checking out the source branch allows us to commit
        // generated configuration files back to that same branch.
        // ------------------------------------------------------------
        stage('Checkout') {
            steps {
                // `scm` is populated by Jenkins' Multibranch SCM configuration.
                checkout scm
                // PR builds must operate on the source branch, not Jenkins' synthetic merge commit.
                script {
                    // CHANGE_ID exists on PR builds, not normal main builds.
                    if (env.CHANGE_ID) {
                        sh '''
                            set -eu
                            test -n "${CHANGE_BRANCH:-}"
                            # Fetch the actual PR source head, not the synthetic PR merge ref.
                            git fetch origin "+refs/heads/$CHANGE_BRANCH:refs/remotes/origin/$CHANGE_BRANCH"
                            # Create/reset a local branch at the PR's source commit.
                            git checkout -B avd-pr-source "refs/remotes/origin/$CHANGE_BRANCH"
                        '''
                    }
                }
                sh 'git status --short'
            }
        }

        // ------------------------------------------------------------
        // STAGE 2: Prepare the tools (runs on PRs AND main).
        // Requirements are installed only if unavailable or changed.
        // ------------------------------------------------------------
        stage('Prepare Ansible (cached)') {
            steps {
                sh '''
                    set -eu
                    mkdir -p "$AVD_CACHE" "$ANSIBLE_COLLECTIONS_PATH"
                    # Fingerprint pinned Python + Galaxy dependency manifests.
                    CACHE_HASH=$(cat requirements.txt collections/requirements.yml | sha256sum | awk '{print $1}')
                    # Install only if Ansible is absent or manifests changed.
                    if [ ! -x "$AVD_CACHE/venv/bin/ansible-playbook" ] || \
                       [ ! -f "$AVD_CACHE/requirements.sha256" ] || \
                       [ "$(cat "$AVD_CACHE/requirements.sha256")" != "$CACHE_HASH" ]; then
                        # Isolated Python environment so system packages remain intact.
                        python3 -m venv "$AVD_CACHE/venv"
                        "$AVD_CACHE/venv/bin/python" -m pip install -r requirements.txt
                        # Install Arista AVD (and collection dependencies).
                        "$AVD_CACHE/venv/bin/ansible-galaxy" collection install \
                            -r collections/requirements.yml \
                            -p "$ANSIBLE_COLLECTIONS_PATH" --force
                        printf '%s\\n' "$CACHE_HASH" > "$AVD_CACHE/requirements.sha256"
                    else
                        echo 'Using cached Ansible and Arista AVD.'
                    fi
                '''
            }
        }

        // PRs: render and review only. Never deploy a pull request.
        // ------------------------------------------------------------
        // STAGE 3: PR ONLY. Render intended EOS configurations.
        // `build.yml` invokes eos_designs -> eos_cli_config_gen.
        // Does NOT deploy anything to the devices.
        // ------------------------------------------------------------
        stage('Build AVD configurations (PR only)') {
            // Jenkins skips this stage on the main branch.
            when { changeRequest() }
            steps {
                withCredentials([
                    // Existing Jenkins Secret file, encrypted vault.yml.
                    file(credentialsId: 'avd-vault-file', variable: 'VAULT_FILE'),
                    // Existing Jenkins Secret text, password to unlock the Vault.
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''
                        set -eu
                        umask 077
                        # Password is written to an ephemeral file (never to Git).
                        PASS_FILE=$(mktemp)
                        mkdir -p group_vars/FABRIC
                        # Remove temporary Vault inputs at shell exit, including failures.
                        trap 'rm -f "$PASS_FILE" group_vars/FABRIC/vault.yml' EXIT
                        # Place the encrypted Secret file where group_vars loads it.
                        cp "$VAULT_FILE" group_vars/FABRIC/vault.yml
                        printf '%s\\n' "$VAULT_PASSWORD" > "$PASS_FILE"
                        "$AVD_CACHE/venv/bin/ansible-playbook" \
                            -i inventory.yml build.yml --vault-password-file "$PASS_FILE"
                    '''
                }
            }
        }

        // ------------------------------------------------------------
        // STAGE 4: PR ONLY. Save the rendered output in Jenkins Artifacts
        // for inspection even if GitHub publishing fails later.
        // ------------------------------------------------------------
        stage('Archive generated configurations (PR only)') {
            // Jenkins skips this stage on the main branch.
            when { changeRequest() }
            steps {
                // Archiving is not the same as committing into GitHub's PR diff.
                archiveArtifacts artifacts: 'intended/configs/*.cfg,intended/structured_configs/*.yml,documentation/**',
                                 allowEmptyArchive: false, fingerprint: true
            }
        }

        // ------------------------------------------------------------
        // STAGE 5: PR ONLY. Add generated .cfg files to the PR branch.
        // GitHub's "Files changed" view shows committed Git differences;
        // Jenkins build artifacts alone will NOT show in that view.
        // This requires separate GitHub write permission.
        // ------------------------------------------------------------
        stage('Commit generated configs to PR (PR only)') {
            // Jenkins skips this stage on the main branch.
            when { changeRequest() }
            steps {
                // Separate GitHub write credential. Existing Vault authentication is unchanged.
                withCredentials([string(credentialsId: 'github-avd-push-token', variable: 'GH_PUSH_TOKEN')]) {
                    sh '''
                        set -eu
                        # Do not publish credentials or secrets from device configuration.
                        # Review all generated files before enabling automatic publishing.
                        git config user.name 'avd-jenkins-bot'
                        git config user.email 'avd-jenkins-bot@users.noreply.github.com'
                        # Stage generated files (new, modified, deleted).
                        git add -A intended/configs/
                        # Exit cleanly when the renderer produces no Git diff.
                        if git diff --cached --quiet; then
                            echo 'No generated .cfg changes to commit.'
                            exit 0
                        fi
                        # CI-skip trailer helps avoid a commit-trigger feedback loop.
                        git commit -m 'chore(avd): update generated EOS configs [skip ci]' 
                        # Jenkins PR checkout can be a detached merge commit; push to the PR source branch.
                        test -n "${CHANGE_BRANCH:-}" || { echo 'CHANGE_BRANCH not set'; exit 1; }
                        case "$CHANGE_BRANCH" in
                            *[!A-Za-z0-9._/-]*|'') echo 'Invalid source branch'; exit 1 ;;
                        esac
                        # Ask Git not to log credential data. Use a temporary auth header, not a URL containing the token.
                        set +x
                        AUTH=$(printf 'x-access-token:%s' "$GH_PUSH_TOKEN" | base64 | tr -d '\\n')
                        git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $AUTH" \
                            push https://github.com/kokedama999/AVD-MultiTenant1.git \
                            HEAD:"refs/heads/$CHANGE_BRANCH"
                    '''
                }
            }
        }

        // Merge to main: immediately deploy configurations committed in the PR.
        // No manual approval, rebuild, or post-deploy verification stages.
        // ------------------------------------------------------------
        // STAGE 6: MAIN ONLY, AFTER MERGE. No rebuild and no approval.
        // Applies the .cfg files already reviewed and merged from the PR.
        // NOTE: deploy.yml uses the repository's Arista eAPI role.
        // ------------------------------------------------------------
        stage('Deploy merged configurations (main only)') {
            when {
                allOf {
                    // Branch names are resolved by the Multibranch Pipeline.
                    branch 'main' 
                    not { changeRequest() }
                }
            }
            steps {
                script {
                    // Fail closed rather than deploying with missing intended configs.
                    // This is a file-existence check, NOT post-deploy validation.
                    if (!fileExists('intended/configs/DC1-Leaf1.cfg')) {
                        error('Merged branch does not contain generated intended/configs/*.cfg files. Deployment stopped.')
                    }
                }
                withCredentials([
                    // Existing Jenkins Secret file, encrypted vault.yml.
                    file(credentialsId: 'avd-vault-file', variable: 'VAULT_FILE'),
                    // Existing Jenkins Secret text, password to unlock the Vault.
                    string(credentialsId: 'ask-vault-pass', variable: 'VAULT_PASSWORD')
                ]) {
                    sh '''
                        set -eu
                        umask 077
                        # Password is written to an ephemeral file (never to Git).
                        PASS_FILE=$(mktemp)
                        mkdir -p group_vars/FABRIC
                        # Remove temporary Vault inputs at shell exit, including failures.
                        trap 'rm -f "$PASS_FILE" group_vars/FABRIC/vault.yml' EXIT
                        # Place the encrypted Secret file where group_vars loads it.
                        cp "$VAULT_FILE" group_vars/FABRIC/vault.yml
                        printf '%s\\n' "$VAULT_PASSWORD" > "$PASS_FILE"
                        "$AVD_CACHE/venv/bin/ansible-playbook" \
                            -i inventory.yml deploy.yml \
                            --limit FABRIC --vault-password-file "$PASS_FILE" --diff
                    '''
                }
            }
        }
    }

    // Always attempt to remove any leftover workspace Vault material.
    // This is not a change to the working authentication mechanism.
    post {
        always {
            sh 'rm -f group_vars/FABRIC/vault.yml .vault_pass || true'
        }
    }
}
