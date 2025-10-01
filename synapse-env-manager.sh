#!/bin/bash
# shellcheck source=/dev/null

# Quickly spin up a Synapse and friends in Podman for testing.
# Copyright (C) 2025  Twilight Sparkle
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

scriptPath="$(readlink -f "$0")"
workDirFullPath="$(dirname "$scriptPath")"
workDirBaseName="$(basename "$workDirFullPath")"
configFile="$workDirFullPath/config.env"

function help {
    cat <<EOT
Usage: $scriptPath <option>

Options:
    admin:      Create Synapse admin account (username: admin. password: admin).
    comp:       Create MAS compatibility admin token for user admin.
    delete:     Delete the environment, Synapse/Postgres data, and config files.
    gencom:     Regenerate the Podman Compose file.
    genele:     Regenerate the Element Web config file.
    genhook:    Regenerate the Hookshot config file.
    genmas:     Regenerate the Matrix-Authentication-Service config file.
    genng:      Regenerate the Nginx config file.
    gensyn:     Regenerate the Synapse config and log config files.
    help:       This help text.
    links:      Print links.
    pull:       Pull all container images.
    rsa:        Restart all containers.
    rse:        Restart the Element Web container.
    rsh:        Restart the Hookshot container.
    rsm:        Restart the Matrix-Authentication-Service container.
    rsn:        Restart the Nginx container.
    rss:        Restart the Synapse container.
    rssa:       Restart the Synapse Admin container.
    setup:      Create, edit, (re)start the environment.
    stop:       Stop the environment without deleting it.

Note: rsa and setup will recreate all containers and remove orphaned
containers. Synapse/Postgres/Hookshot/Redis data is not deleted.
EOT
}

# Load config
[[ -f "$configFile" ]] && source "$configFile"

# Set any defaults not specified in the config file
[[ ! "$nginxImage" ]] && nginxImage="docker.io/nginx:latest"
[[ ! "$ingressPort" ]] && ingressPort=8080
[[ ! "$listenPort" ]] && listenPort="$ingressPort"

[[ ! "$serverName" ]] && serverName="127.0.0.1"
[[ ! "$synapseHost" ]] && synapseHost="127.0.0.10"
[[ ! "$masHost" ]] && masHost="127.0.0.15"
[[ ! "$elementHost" ]] && elementHost="127.0.0.20"
[[ ! "$hookshotHost" ]] && hookshotHost="127.0.0.25"
[[ ! "$synapseAdminHost" ]] && synapseAdminHost="127.0.0.30"
[[ ! "$adminerHost" ]] && adminerHost="127.0.0.35"
[[ ! "$mailhogHost" ]] && mailhogHost="127.0.0.40"

[[ ! "$synapseImage" ]] && synapseImage="ghcr.io/element-hq/synapse:latest"
[[ ! "$synapseEnablePresence" ]] && synapseEnablePresence=true
[[ ! "$synapseAdditionalVolumes" ]] && synapseAdditionalVolumes=()

[[ ! "$enableMas" ]] && enableMas=true
[[ ! "$masImage" ]] && \
    masImage="ghcr.io/element-hq/matrix-authentication-service:latest"

[[ ! "$enableMailhog" ]] && enableMailhog="$enableMas"
[[ ! "$mailhogImage" ]] && mailhogImage="docker.io/mailhog/mailhog:latest"

[[ ! "$postgresImage" ]] && postgresImage="docker.io/postgres:latest"

[[ ! "$enableAdminer" ]] && enableAdminer=false
[[ ! "$adminerImage" ]] && adminerImage="docker.io/adminer:latest"

[[ ! "$enableElementWeb" ]] && enableElementWeb=true
[[ ! "$elementImage" ]] && elementImage="ghcr.io/element-hq/element-web:latest"

[[ ! "$enableHookshot" ]] && enableHookshot=false
[[ ! "$hookshotEncryption" ]] && hookshotEncryption=false
[[ ! "$hookshotImage" ]] && \
    hookshotImage="ghcr.io/matrix-org/matrix-hookshot:latest"
[[ ! "$redisImage" ]] && redisImage="docker.io/redis:latest"

[[ ! "$enableSynapseAdmin" ]] && enableSynapseAdmin=true
[[ ! "$synapseAdminImage" ]] && \
    synapseAdminImage="ghcr.io/etkecc/synapse-admin:latest"

if [[ "$enableMas" == true ]] && [[ "$enableHookshot" == true ]]; then
    echo "Hookshot encryption is not compatible with MAS. \
https://github.com/matrix-org/matrix-hookshot/issues/980"
    exit 1
fi

# Vars
nginxConfigFile="$workDirFullPath/nginx.conf"
composeFile="$workDirFullPath/compose.yml"

synapseData="$workDirFullPath/synapse"
synapseConfigFile="$synapseData/homeserver.yaml"
synapseGeneratedLogConfigFile="$synapseData/$serverName.log.config"
synapseLogConfigFile="$synapseData/log.config.yaml"

masConfigFile="$workDirFullPath/masConfig.yaml"

elementConfigFile="$workDirFullPath/elementConfig.json"

hookshotData="$workDirFullPath/hookshot"
hookshotConfigFile="$hookshotData/config.yml"
hookshotPasskeyFile="$hookshotData/passkey.pem"
hookshotRegistrationFile="$hookshotData/registration.yml"


composeDash="false"

# These variables needs to be exported so it can be used with yq
export serverNameEnv="$serverName"
export synapseEnablePresenceEnv="$synapseEnablePresence"

# Check that required programs are installed on the system
function checkRequiredPrograms {
    programs=(bash podman yq)
    missing=""
    for program in "${programs[@]}"; do
        if ! hash "$program" &>/dev/null; then
            missing+="\n- $program"
        fi
    done
    if [[ -n "$missing" ]]; then
        echo -e "Required programs are missing on this system. \
Please install:$missing"
        exit 1
    fi

    if hash podman-compose &>/dev/null; then
        composeDash="true"
    fi
}

# Set Podman namespace permissions
function podmanPermissions {
    path="$1"
    ownerId="$2"
    podman unshare find "$path" -type d -exec chmod 775 {} +
    podman unshare find "$path" -type f -exec chmod 664 {} +
    podman unshare chown "$ownerId" -R "$path"
}

# Check for required directories and set permissions for Synapse
function checkRequiredDirectories {
    [[ ! -d "$synapseData" ]] &&
        mkdir "$synapseData" &&
        podmanPermissions "$synapseData" "991"

    for volume in "${synapseAdditionalVolumes[@]}"; do
        [[ -e "$volume" ]] && podmanPermissions "$volume" "991"
    done
}

# Create Synapse admin account
function createAdminAccount {
    if [[ "$enableMas" == true ]]; then
        podman exec \
            "$workDirBaseName-mas" \
            mas-cli manage register-user \
                --admin \
                --email admin@example.com \
                --ignore-password-complexity \
                --password admin \
                --yes \
                admin
    else
        podman exec \
            "$workDirBaseName-synapse" \
            /bin/bash \
            -c "register_new_matrix_user \
                --admin \
                --config /data/homeserver.yaml \
                --password admin \
                --user admin"
    fi
    exit 0
}

# Create MAS compatibility token
function createCompatibilityToken {
    if [[ "$enableMas" == true ]]; then
        podman exec \
            "$workDirBaseName-mas" \
            mas-cli manage issue-compatibility-token \
                --yes-i-want-to-grant-synapse-admin-privileges \
                admin
    fi
    exit 0
}

# Delete the environment
function deleteEnvironment {
    msg="Enter YES to confirm deleting the environment, Postgres volume, and \
the directories/files hookshot/, synapse/, compose.yml, masConfig.yaml, \
nginx.conf, and elementConfig.json: "
    read -rp "$msg" verification
    [[ "$verification" != "YES" ]] && exit 0

    if [[ "$composeDash" == "true" ]]; then
        podman-compose down
    else
        podman compose down
    fi

    podman volume rm "${workDirBaseName}_hookshotEncryptionData"
    podman volume rm "${workDirBaseName}_masPostgresData"
    podman volume rm "${workDirBaseName}_postgresData"
    podman volume rm "${workDirBaseName}_redisData"
    [[ -f "$composeFile" ]] && rm -rf "$composeFile"
    [[ -f "$elementConfigFile" ]] && rm -rf "$elementConfigFile"
    [[ -d "$hookshotData" ]] && rm -rf "$hookshotData"
    [[ -f "$masConfigFile" ]] && rm -rf "$masConfigFile"
    [[ -f "$nginxConfigFile" ]] && rm -rf "$nginxConfigFile"
    [[ -d "$synapseData" ]] && rm -rf "$synapseData"
}

# Create the Podman compose file
function generatePodmanCompose {
    if [[ "$enableHookshot" == true ]]; then
        synapseAdditionalVolumes+=(
          "$hookshotRegistrationFile:/appservices/hookshot.yaml"
        )
    fi

    synapseAdditionalVolumesYaml=""
    for volume in "${synapseAdditionalVolumes[@]}"; do
        synapseAdditionalVolumesYaml+="
      - $volume:Z"
    done

    # We need $verification 
    if [[ -f "$composeFile" ]]; then
         read -rp "Overwrite $composeFile? [y/N]: " verification
    else
        verification=y
    fi

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ ! -f "$composeFile" ]] || [[ "$verification" == "y" ]] && \
        cat <<EOT > "$composeFile"
# This file is managed by $scriptPath

volumes:
    hookshotEncryptionData:
    masPostgresData:
    postgresData:
    redisData:

services:
  nginx:
    container_name: $workDirBaseName-nginx
    image: $nginxImage
    restart: unless-stopped
    volumes:
    - $nginxConfigFile:/etc/nginx/conf.d/custom.conf
    ports:
    - "$ingressPort:80"
    environment:
    - NGINX_PORT=80

  synapse:
    container_name: $workDirBaseName-synapse
    image: $synapseImage
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      - SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
    ports:
      - 127.0.0.1:47601-47602:8008-8009/tcp
      - 127.0.0.1:47600:8448/tcp
    volumes:
      - $synapseData:/data:Z$synapseAdditionalVolumesYaml

  postgres:
    container_name: $workDirBaseName-postgres
    image: $postgresImage
    restart: unless-stopped
    environment:
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
      - POSTGRES_PASSWORD=password
      - POSTGRES_USER=synapse
    ports:
      - 127.0.0.1:47610:5432/tcp
    volumes:
      - postgresData:/var/lib/postgresql/data
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableAdminer" == true ]] && [[ "$verification" == "y" ]] && \
        cat <<EOT >> "$composeFile"

  adminer:
    container_name: $workDirBaseName-adminer
    image: $adminerImage
    restart: unless-stopped
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
    ports:
      - 127.0.0.1:47603:8080/tcp
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableElementWeb" == true ]] && [[ "$verification" == "y" ]] && \
        cat <<EOT >> "$composeFile"

  elementweb:
    container_name: $workDirBaseName-elementweb
    image: $elementImage
    restart: unless-stopped
    environment:
      - ELEMENT_WEB_PORT=8080
    ports:
      - 127.0.0.1:47604:8080/tcp
    volumes:
        - $elementConfigFile:/app/config.json:Z
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableMas" == true ]] && [[ "$verification" == "y" ]] && \
        cat <<EOT >> "$composeFile"

  mas:
    container_name: $workDirBaseName-mas
    image: $masImage
    restart: unless-stopped
    environment:
      - MAS_CONFIG=/config.yaml
    ports:
      - 127.0.0.1:47605:8080/tcp
    volumes:
      - $masConfigFile:/config.yaml:Z

  mas-postgres:
    container_name: $workDirBaseName-mas-postgres
    image: $postgresImage
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=password
      - POSTGRES_USER=mas
    ports:
      - 127.0.0.1:47609:5432/tcp
    volumes:
      - masPostgresData:/var/lib/postgresql/data
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableMailhog" == true ]] && [[ "$verification" == "y" ]] && \
        cat <<EOT >> "$composeFile"

  mailhog:
    container_name: $workDirBaseName-mailhog
    image: $mailhogImage
    restart: unless-stopped
    ports:
      - 127.0.0.1:47612:8025
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableSynapseAdmin" == true ]] && [[ "$verification" == "y" ]] && \
        cat <<EOT >> "$composeFile"

  synapseadmin:
    container_name: $workDirBaseName-synapseadmin
    image: $synapseAdminImage
    restart: unless-stopped
    environment:
      - SERVER_PORT=8080
    ports:
      - 127.0.0.1:47611:8080/tcp
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableHookshot" == true ]] && [[ "$verification" == "y" ]] && \
        cat <<EOT >> "$composeFile"

  hookshot:
    container_name: $workDirBaseName-hookshot
    image: $hookshotImage
    ports:
      - 127.0.0.1:47607:9993
      - 127.0.0.1:47606:9993
    restart: unless-stopped
    volumes:
      - $hookshotData:/data:Z
      - hookshotEncryptionData:/encryption

  redis:
    command: redis-server --save 20 1 --loglevel warning
    container_name: $workDirBaseName-redis
    image: $redisImage
    ports:
      - 127.0.0.1:47608:6379
    restart: unless-stopped
    volumes:
      - redisData:/data
EOT
}

# Generate Element Web config if not present or ask to overwrite
function generateElementConfig {
    [[ -f "$elementConfigFile" ]] && \
        read -rp "Overwrite $elementConfigFile? [y/N]: " verification
    
    # If user agreed to overwrite AND the target file to overwrite exists
    [[ ! -f "$elementConfigFile" ]] || [[ "$verification" == "y" ]] && \
        cat <<EOT > "$elementConfigFile"
{
    "${workDirBaseName}_notice": "This file is managed by $scriptPath",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "dangerously_allow_unsafe_and_insecure_passwords": true,
    "default_country_code": "US",
    "default_federate": true,
    "default_server_config": {
        "m.homeserver": {
            "base_url": "http://$synapseHost:$listenPort",
            "server_name": "$serverName"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "default_theme": "dark",
    "disable_3pid_login": false,
    "disable_custom_urls": false,
    "disable_guests": false,
    "disable_login_language_selector": false,
    "element_call": {
        "brand": "Element Call",
        "url": "https://call.element.io"
    },
    "enable_presence_by_hs_url": {
        "http://$synapseHost:$listenPort": $synapseEnablePresence,
        "http://$serverName": $synapseEnablePresence
    },
    "features": {
        "feature_jump_to_date": true,
        "feature_release_announcement": false,
        "feature_state_counters": true
    },
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api",
        "https://scalar-staging.riot.im/scalar/api"
    ],
    "jitsi": {
        "preferred_domain": "meet.element.io"
    },
    "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=fU3vlMsMn4Jb6dnEIFsx",
    "room_directory": {
        "servers": [
            "$serverName"
        ]
    },
    "setting_defaults": {
        "alwaysShowTimestamps": true,
        "automaticErrorReporting": false,
        "ctrlFForSearch": true,
        "developerMode": true,
        "dontSendTypingNotifications": true,
        "FTUE.userOnboardingButton": false,
        "MessageComposerInput.ctrlEnterToSend": true,
        "sendReadReceipts": false,
        "sendTypingNotifications": false,
        "showChatEffects": false,
        "UIFeature.advancedSettings": true,
        "UIFeature.Feedback": false,
        "UIFeature.shareSocial": false
    },
    "show_labs_settings": true
}
EOT
}

# Generate Hookshot Web config if not present or ask to overwrite
function generateHookshotConfig {
    msg="Overwrite $hookshotConfigFile and $hookshotRegistrationFile? [y/N]: "
    [[ -f "$hookshotConfigFile" ]] && read -rp "$msg" verification

    if [[ "$enableHookshot" == true && (! -f "$hookshotConfigFile" || "$verification" == "y") ]]
    then
        ## Cleanup everything and recreate directories
        [[ -d "$hookshotData" ]] && rm -rf "$hookshotData"
        mkdir -p "$hookshotData"
        
        # Hookshot config file
        cat <<EOT > "$hookshotConfigFile"
---
bot:
  displayname: Hookshot
bridge:
  bindAddress: 0.0.0.0
  domain: $serverName
  mediaUrl: http://$synapseHost:$listenPort
  port: 9993
  url: http://synapse:8448
cache:
  redisUri: redis://redis:6379
feeds:
  enabled: true
  pollIntervalSeconds: 600
  pollTimeoutSeconds: 30
generic:
  allowJsTransformationFunctions: true
  enableHttpGet: false
  enabled: true
  outbound: true
  urlPrefix: http://$hookshotHost:$listenPort/webhook/
  userIdPrefix: _webhooks_
  waitForComplete: false
listeners:
  - bindAddress: 0.0.0.0
    port: 9993
    resources:
      - webhooks
      - widgets
  - bindAddress: 0.0.0.0
    port: 9101
    resources:
      - metrics
logging:
  colorize: true
  json: false
  # Logging settings. You can have a severity debug,info,warn,error
  level: info
  timestampFormat: HH:mm:ss:SSS
metrics:
  enabled: true
passFile: /data/passkey.pem
permissions:
  - actor: '*'
    services:
      - level: admin
        service: '*'
widgets:
  addToAdminRooms: false
  branding:
    widgetTitle: Hookshot Configuration
  disallowedIpRanges: []
  openIdOverrides:
    $serverName: http://synapse:8448
  publicUrl: http://$hookshotHost:$listenPort/widgetapi/v1/static/
  roomSetupWidget:
    addOnInvite: false
EOT

        if [[ "$hookshotEncryption" == true ]]; then
            yq --inplace '.encryption.storagePath = "/encryption"'  
                "$hookshotConfigFile"
        fi

        # Hookshot registration file
        cat <<EOT > "$hookshotRegistrationFile"
---
as_token: hookshotastoken
de.sorunome.msc2409.push_ephemeral: true
hs_token: hookshothstoken
id: hookshot
namespaces:
  rooms: []
  users:
    - exclusive: true
      regex: '@_webhooks_.*:$serverName'
org.matrix.msc3202: true
push_ephemeral: true
rate_limited: false
sender_localpart: hookshot
url: http://hookshot:9993
EOT

        # Hookshot passkey
        cat <<EOT > "$hookshotPasskeyFile"
-----BEGIN PRIVATE KEY-----
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
KELKb1pj8J/jp5pRp5AtyG2iMwxEKg==
-----END PRIVATE KEY-----
EOT

        podmanPermissions "$hookshotData" "991"
    fi
}

# Generate MAS config if not present or ask to overwrite
function generateMasConfig {
    [[ -f "$masConfigFile" ]] && 
        read -rp "Overwrite $masConfigFile? [y/N]: " verification
    
    # If user agreed to overwrite AND the target file to overwrite exists
    # AND MAS is enabled
    if [[ "$enableMas" == true && (! -f "$masConfigFile" || "$verification" == "y") ]]
    then
        # Delete the files so MAS can re-generate them
        [[ -f "$masConfigFile" ]] && rm "$masConfigFile"

        # Use MAS' built-in executable to generate default config file
        podman run \
          --interactive \
          --quiet \
          --rm \
          --tty \
          "$masImage" \
          config generate | grep -v INFO > "$masConfigFile"

        yq --inplace 'del(.http.trusted_proxies)' "$masConfigFile"
        yq --inplace 'del(.http.listeners[0].binds[0])' "$masConfigFile"
        yq --inplace 'del(.database)' "$masConfigFile"
        export masManagement="http://$masHost:$listenPort"
        export swaggerCallback="http://$masHost:$listenPort/api/doc/oauth2-callback"
        yq --inplace '
            .account.password_registration_enabled = true |
            .clients[0].client_auth_method = "client_secret_basic" |
            .clients[0].client_id = "0000000000000000000SYNAPSE" |
            .clients[0].client_secret = "secret" |
            .clients[1].client_auth_method = "client_secret_post" |
            .clients[1].client_id = "01JTTHHQBMKE8W3VCXRVFVW04P" |
            .clients[1].client_secret = "secret" |
            .clients[1].redirect_uris[0] = "https://element-hq.github.io/matrix-authentication-service/api/oauth2-redirect.html" |
            .clients[1].redirect_uris[0] = env(swaggerCallback) |
            .database.database = "mas" |
            .database.host = "mas-postgres" |
            .database.password = "password" |
            .database.port = 5432 |
            .database.username = "mas" |
            .experimental.access_token_ttl = 86400 |
            .experimental.compat_token_ttl = 86400 |
            .experimental.inactive_session_expiration.expire_compat_sessions = false |
            .experimental.inactive_session_expiration.ttl = 86400 |
            .http.issuer = env(masManagement) |
            .http.listeners[0].binds[0].host = "0.0.0.0" |
            .http.listeners[0].binds[0].port = 8080 |
            .http.listeners[0].resources += [{"name": "adminapi"}] |
            .http.public_base = env(masManagement) |
            .http.trusted_proxies[0] = "0.0.0.0/0" |
            .matrix.endpoint = "http://synapse:8448/" |
            .matrix.kind = "synapse" |
            .matrix.homeserver = env(serverNameEnv) |
            .matrix.secret = "secret" |
            .passwords.minimum_complexity = 0 |
            .policy.client_registration.allow_host_mismatch = true |
            .policy.client_registration.allow_insecure_uris = true |
            .policy.client_registration.allow_missing_client_uri = true |
            .policy.data.admin_clients[0] = "0000000000000000000SYNAPSE" |
            .policy.data.admin_clients[1] = "01JTTHHQBMKE8W3VCXRVFVW04P" |
            .policy.data.admin_users[0] = "admin"
        ' "$masConfigFile"
        export masManagement="http://$masHost:$listenPort/"
        yq --inplace '
          .enable_registration = false |
          .matrix_authentication_service.enabled = true |
          .matrix_authentication_service.endpoint = "http://mas:8080/" |
          .matrix_authentication_service.secret = "secret"
        ' "$synapseConfigFile"

        if [[ "$enableMailhog" == true ]]; then
            export masEmailFrom="mas@$serverName"
            yq --inplace '
                .email.from = env(masEmailFrom) |
                .email.hostname = "mailhog" |
                .email.mode = "plain" |
                .email.port = 1025 |
                .email.reply_to = env(masEmailFrom) |
                .email.transport = "smtp"
            ' "$masConfigFile"
        fi
    fi
}

# Generate Nginx config if not present or ask to overwrite
function generateNginxConfig {
    [[ -f "$nginxConfigFile" ]] && \
        read -rp "Overwrite $nginxConfigFile? [y/N]: " verification
    
    # If user agreed to overwrite AND the target file to overwrite exists
    if [[ ! -f "$nginxConfigFile" ]] || [[ "$verification" == "y" ]]; then
        cat <<EOT > "$nginxConfigFile"
# Well-known
server {
    listen       80;
    server_name  $serverName;
    location /.well-known/matrix/client {
        return 200 '{"m.homeserver":{"base_url":"http://$synapseHost:$listenPort"}}';
        add_header Content-Type application/json;
        add_header 'Access-Control-Allow-Origin' '*';
    }
    location /.well-known/matrix/server {
        return 200 '{"m.server": "$synapseHost:$listenPort"}';
        add_header Content-Type application/json;
    }
}
EOT
        [[ "$enableMas" == false ]] && cat <<EOT >> "$nginxConfigFile"
# Synapse
server {
    listen       80;
    server_name  $synapseHost;
    location ~ ^(/_matrix|/_synapse/client|/_synapse/admin) {
        proxy_pass http://synapse:8448;
        client_max_body_size 50M;
        proxy_http_version 1.1;
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOT

        [[ "$enableMas" == true ]] && cat <<EOT >> "$nginxConfigFile"
# Synapse
server {
    listen       80;
    server_name  $synapseHost;
    location ~ ^/_matrix/client/(.*)/(login|logout|refresh) {
        proxy_pass http://mas:8080;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
    location ~ ^(/_matrix|/_synapse/client|/_synapse/admin) {
        proxy_pass http://synapse:8448;
        client_max_body_size 50M;
        proxy_http_version 1.1;
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
# MAS
server {
    listen       80;
    server_name  $masHost;
    location / {
        proxy_pass http://mas:8080;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT

        [[ "$enableMailhog" == true ]] && cat <<EOT >> "$nginxConfigFile"
# Mailhog
server {
    listen       80;
    server_name  $mailhogHost;
    location / {
        proxy_pass http://mailhog:8025;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT

        [[ "$enableElementWeb" == true ]] && cat <<EOT >> "$nginxConfigFile"
# Element Web
server {
    listen       80;
    server_name  $elementHost;
    location / {
        proxy_pass http://elementweb:8080;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT

        [[ "$enableHookshot" == true ]] && cat <<EOT >> "$nginxConfigFile"
# Hookshot
server {
    listen       80;
    server_name  $elementHost;
    location / {
        proxy_pass http://hookshot:9993;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT

        [[ "$enableSynapseAdmin" == true ]] && cat <<EOT >> "$nginxConfigFile"
# Synapse Admin
server {
    listen       80;
    server_name  $synapseAdminHost;
    location / {
        proxy_pass http://synapseadmin:8080;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT

        [[ "$enableAdminer" == true ]] && cat <<EOT >> "$nginxConfigFile"
# Adminer
server {
    listen       80;
    server_name  $adminerHost;
    location / {
        proxy_pass http://adminer:8080;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT
    fi
}

# Generate Synapse config if not present or ask to overwrite
function generateSynapseConfig {
    # Ask the user to overwrite if EITHER the Synapse config file OR
    # Synapse log config file exists
    [[ -f "$synapseConfigFile" ]] || [[ -f "$synapseLogConfigFile" ]] && \
        read -rp "Overwrite $synapseConfigFile and \
$synapseLogConfigFile? [y/N]: " verification

    if  [[ ! -f "$synapseConfigFile" ]] || [[ "$verification" == "y" ]]; then
        # Delete the files so Synapse can re-generate them
        [[ -f "$synapseConfigFile" ]] && rm "$synapseConfigFile"
        [[ -f "$synapseLogConfigFile" ]] && rm "$synapseLogConfigFile"

        # Use Synapse's built-in executable to generate default config files
        podman run \
            --entrypoint "/bin/bash" \
            --interactive \
            --rm \
            --tty \
            --volume "$synapseData":/data:Z \
            "$synapseImage" \
            -c "python3 -m synapse.app.homeserver \
                --config-path /data/homeserver.yaml \
                --data-directory /data \
                --generate-config \
                --report-stats no \
                --server-name $serverName"

        podmanPermissions "$synapseData" "991"

        mv "$synapseGeneratedLogConfigFile" "$synapseLogConfigFile"

        # Customize Synapse config
        yq --inplace '.handlers.file.filename = "/data/homeserver.log"' \
            "$synapseLogConfigFile"
        yq --inplace 'del(.listeners[0].bind_addresses)' "$synapseConfigFile"
        yq --inplace '
            .database.args.cp_max = 10 |
            .database.args.cp_min = 5 |
            .database.args.database = "synapse" |
            .database.args.host = "postgres" |
            .database.args.password = "password" |
            .database.args.user = "synapse" |
            .database.name = "psycopg2" |
            .enable_registration = true |
            .enable_registration_without_verification = true |
            .listeners[0].bind_addresses[0] = "0.0.0.0" |
            .listeners[0].port = 8448 |
            .log_config = "/data/log.config.yaml" |
            .password_config.pepper = "s3cr3tP3pp3r" |
            .presence.enabled = env(synapseEnablePresenceEnv) |
            .suppress_key_server_warning = true |
            .suppress_key_server_warning = true |
            .trusted_key_servers[0].accept_keys_insecurely = true |
            .user_directory.enabled = true |
            .user_directory.prefer_local_users = true |
            .user_directory.search_all_users = true
        ' "$synapseConfigFile"

        if [[ "$enableHookshot" == true ]] && \
            [[ "$hookshotEncryption" == true ]]
        then
            yq --inplace '
                .app_service_config_files[0] = "/appservices/hookshot.yaml" |
                .experimental_features.msc2409_to_device_messages_enabled = true |
                .experimental_features.msc3202_device_masquerading = true |
                .experimental_features.msc3202_transaction_extensions = true
            ' "$synapseConfigFile"
        fi
    fi
}

# Print links
function printLinks {
    links="Links:\n\n- Synapse server name: $serverName"
    links+="\n- Synapse endpoint:    http://$synapseHost:$listenPort"
    [[ "$enableAdminer" == true ]] && \
        links+="\n- Adminer:             http://$adminerHost:$listenPort"
    [[ "$enableElementWeb" == true ]] && \
        links+="\n- Element Web:         http://$elementHost:$listenPort"
    [[ "$enableMas" == true ]] && \
        links+="\n- MAS:                 http://$masHost:$listenPort"
    [[ "$enableMas" == true ]] && \
        links+="\n- MAS Swagger UI:      http://$masHost:$listenPort/api/doc/"
    [[ "$enableMailhog" == true ]] && \
        links+="\n- Mailhog:             http://$mailhogHost:$listenPort"
    [[ "$enableSynapseAdmin" == true ]] && \
        links+="\n- Synapse Admin:       http://$synapseAdminHost:$listenPort?\
username=admin&password=admin&server=http://$synapseHost:$listenPort"

    echo -e "$links"                
}

# Pull all container images
function pullImages {
    if [[ "$composeDash" == "true" ]]; then
        podman-compose pull
    else
        podman compose pull
    fi
}

# Restart the Element Web container
function restartElement {
    podman restart "$workDirBaseName-elementweb"
}

# Restart the Hookshot container
function restartHookshot {
    podman restart "$workDirBaseName-hookshot"
}

# Restart the MAS container
function restartMas {
    podman restart "$workDirBaseName-mas"
    podman exec --interactive --tty "$workDirBaseName-mas" mas-cli config check
    podman exec --interactive --tty \
        "$workDirBaseName-mas" mas-cli config sync --prune
}

# Restart the Nginx container
function restartNginx {
    podman restart "$workDirBaseName-nginx"
}

# Restart the Synapse container
function restartSynapse {
    podman restart "$workDirBaseName-synapse"
}

# Restart the Synapse Admin container
function restartSynapseAdmin {
    podman restart "$workDirBaseName-synapseadmin"
}

# Stop the environment
function stopEnvironment {
    if [[ "$composeDash" == "true" ]]; then
        podman-compose stop
    else
        podman compose stop
    fi
}

# Create/Start/Restart containers
function restartAll {
    if [[ "$composeDash" == "true" ]]; then
        podman-compose up --detach --force-recreate
    else
        podman compose up --detach --force-recreate --remove-orphans
    fi
    restartNginx
}


checkRequiredPrograms
checkRequiredDirectories

case $1 in
    admin)      createAdminAccount                  ;;
    comp)       createCompatibilityToken            ;;
    delete)     deleteEnvironment                   ;;
    gencom)     generatePodmanCompose               ;;
    genele)     generateElementConfig               ;;
    genhook)    generateHookshotConfig              ;;
    genmas)     generateMasConfig                   ;;
    genng)      generateNginxConfig                 ;;
    gensyn)     generateSynapseConfig               ;;
    links)      printLinks                          ;;
    pull)       pullImages                          ;;
    rsa)        restartAll                          ;;
    rse)        restartElement; restartNginx        ;;
    rsh)        restartHookshot; restartNginx       ;;
    rsm)        restartMas; restartNginx            ;;
    rsn)        restartNginx                        ;;
    rss)        restartSynapse; restartNginx        ;;
    rssa)       restartSynapseAdmin; restartNginx   ;;
    setup)
        generatePodmanCompose
        generateNginxConfig
        generateElementConfig
        generateHookshotConfig
        generateSynapseConfig
        generateMasConfig
        pullImages
        restartAll
        ;;
    stop)       stopEnvironment             ;;
    *)          help                        ;;
esac


