#!/bin/bash
# shellcheck source=/dev/null

# Quickly spin up a Synapse and friends in Podman for testing.
# Copyright (C) 2025-2026  Twilight Sparkle
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
    genssl:     Regenerate SSL certificate.
    gensyn:     Regenerate the Synapse config and log config files.
    help:       This help text.
    links:      Print links.
    ps:         podman compose ps
    pull:       Pull all container images.
    rsa:        Restart all containers.
    rsea:       Restart the Element Admin container.
    rsew:       Restart the Element Web container.
    rsh:        Restart the Hookshot container.
    rsk:        Restart the Ketesa container.
    rsm:        Restart the Matrix-Authentication-Service container.
    rsn:        Restart the Nginx container.
    rspm:       Restart the MAS Postgres container.
    rsps:       Restart the Synapse Postgres container.
    rss:        Restart the Synapse container.
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
[[ ! "$ingressPort" ]] && ingressPort=8443
[[ ! "$listenPort" ]] && listenPort="443"

[[ ! "$enableSSL" ]] && enableSSL=true

[[ ! "$serverName" ]] && serverName="matrix.local"
[[ ! "$adminerHost" ]] && adminerHost="adminer.matrix.local"
[[ ! "$elementAdminHost" ]] && elementAdminHost="admin.matrix.local"
[[ ! "$elementHost" ]] && elementHost="element.matrix.local"
[[ ! "$hookshotHost" ]] && hookshotHost="hookshot.matrix.local"
[[ ! "$ketesaHost" ]] && ketesaHost="ketesa.matrix.local"
[[ ! "$mailhogHost" ]] && mailhogHost="mailhog.matrix.local"
[[ ! "$masHost" ]] && masHost="mas.matrix.local"
[[ ! "$synapseHost" ]] && synapseHost="synapse.matrix.local"

[[ ! "$synapseImage" ]] && synapseImage="ghcr.io/element-hq/synapse:latest"
[[ ! "$synapseEnablePresence" ]] && synapseEnablePresence=true
[[ ! "$synapseAdditionalVolumes" ]] && synapseAdditionalVolumes=()

[[ ! "$enableMas" ]] && enableMas=true
[[ ! "$masImage" ]] && \
    masImage="ghcr.io/element-hq/matrix-authentication-service:latest"

[[ ! "$enableEmail" ]] && enableEmail=false
[[ ! "$mailhogImage" ]] && mailhogImage="docker.io/mailhog/mailhog:latest"

[[ ! "$postgresImage" ]] && postgresImage="docker.io/postgres:18"
[[ ! "$customPostgresConfig" ]] && customPostgresConfig=false

[[ ! "$enableAdminer" ]] && enableAdminer=false
[[ ! "$adminerImage" ]] && adminerImage="docker.io/adminer:latest"

[[ ! "$enableElementAdmin" ]] && enableElementAdmin=true
[[ ! "$elementAdminImage" ]] \
    && elementAdminImage="oci.element.io/element-admin:latest"

[[ ! "$enableElementWeb" ]] && enableElementWeb=true
[[ ! "$elementImage" ]] && elementImage="ghcr.io/element-hq/element-web:latest"

[[ ! "$enableHookshot" ]] && enableHookshot=false
[[ ! "$hookshotEncryption" ]] && hookshotEncryption=false
[[ ! "$hookshotImage" ]] && \
    hookshotImage="ghcr.io/matrix-org/matrix-hookshot:latest"
[[ ! "$redisImage" ]] && redisImage="docker.io/redis:latest"

[[ ! "$enableKetesa" ]] && enableKetesa=true
[[ ! "$ketesaImage" ]] && ketesaImage="ghcr.io/etkecc/ketesa:latest"

# Check for incompatible options
if [[ "$enableMas" == true ]] && [[ "$enableHookshot" == true ]] && \
    [[ "$hookshotEncryption" == true ]]; then
    echo "Hookshot encryption is not compatible with MAS. \
https://github.com/matrix-org/matrix-hookshot/issues/980"
    exit 1
fi

if [[ "$enableMas" == false ]] && [[ "$enableElementAdmin" == true ]]; then
    echo "Element Admin is only available when MAS is enabled"
    exit 1
fi

if [[ "$enableSSL" != true ]]; then
    echo "Disabling SSL is currently not supported"
    exit 1
fi

# Vars
nginxConfigFile="$workDirFullPath/nginx.conf"
composeFile="$workDirFullPath/compose.yml"

publicKeyFile="$workDirFullPath/$serverName-public.pem"
privateKeyFile="$workDirFullPath/$serverName-private.pem"

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

postgresConfigFileMas="$workDirFullPath/postgresql-mas.conf"
postgresConfigFileSynapse="$workDirFullPath/postgresql-synapse.conf"

# Is "podman compose" or "podman-compose" installed on this system
composeDash=false

# These variables needs to be exported so it can be used with yq
export serverNameEnv="$serverName"
export synapseEnablePresenceEnv="$synapseEnablePresence"

# Check that required programs are installed on the system
function checkRequiredPrograms {
    local programs=(bash mkcert podman yq)
    local missing=""
    local program
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
        composeDash=true
    fi
}

# Set Podman namespace permissions
function podmanPermissions {
    local path="$1"
    local ownerId="$2"
    podman unshare find "$path" -type d -exec chmod 775 {} +
    podman unshare find "$path" -type f -exec chmod 664 {} +
    podman unshare chown "$ownerId" -R "$path"
}

function simplePodman {
    local command="$1"
    if [[ "$composeDash" == true ]]; then
        podman-compose "$command"
    else
        podman compose "$command"
    fi
}

# Check for required directories and set permissions for Synapse
function checkRequiredDirectories {
    [[ ! -d "$synapseData" ]] &&
        mkdir "$synapseData" &&
        podmanPermissions "$synapseData" "991"

    local volume
    local path
    for volume in "${synapseAdditionalVolumes[@]}"; do
        path="${volume%%:*}"
        [[ -e "$path" ]] && podmanPermissions "$path" "991"
    done
}

# Create Synapse admin account
function createAdminAccount {
    if [[ "$enableMas" == true ]]; then
        podman exec "$workDirBaseName-mas" mas-cli manage register-user \
            --admin --email admin@example.com --ignore-password-complexity \
            --password admin --yes admin
    else
        podman exec "$workDirBaseName-synapse" /bin/bash \
            -c "register_new_matrix_user --admin \
            --config /data/homeserver.yaml --password admin --user admin"
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
    local msg="Enter yes in uppercase to confirm deleting the environment, all \
Podman volumes, and all config/data files/directories: "

    local verification
    read -rp "$msg" verification
    [[ "$verification" != "YES" ]] && exit 0

    [[ -f "$composeFile" ]] && simplePodman down

    local volume
    for volume in hookshotEncryptionData masPostgresData postgresData redisData
    do
        podman volume exists "${workDirBaseName}_$volume" > /dev/null \
            && podman volume rm "${workDirBaseName}_$volume"
    done

    local files=("$composeFile" "$elementConfigFile" "$masConfigFile"
        "$nginxConfigFile" "$postgresConfigFileMas" "$postgresConfigFileSynapse"
        "$privateKeyFile" "$publicKeyFile" "$hookshotData" "$synapseData")
    local file
    for file in "${files[@]}"; do
        [[ -e "$file" ]] && rm -rf "$file"
    done
}

# Check if feature is enabled, and if yes, check if any of passed paths exists.
# If feature is not enabled, return 1.
# If none of the paths exists, return 0.
# If any of the paths exist, ask the user if they want to overwrite.
# Return 0 if files should be overwritten, 1 if not.
function checkOverwrite {
    local enabled="$1"
    [[ "${enabled}" == false ]] && return 1

    shift

    local existingCount=0
    local path
    for path in "$@"; do
        [[ -e "$path" ]] && (( existingCount+=1 ))
    done

    [[ "$existingCount" == 0 ]] && return 0

    local pathString=""
    local path
    for path in "$@"; do
        pathString+=${path##*/}
        pathString+=", "
    done
    pathString=${pathString::-2}

    local verification
    read -rp "Overwrite $pathString? [y/N]: " verification
    [[ "$verification" == "y" ]] && return 0

    return 1
}

# Print compose healthcheck block
function healthcheck {
    local test="$1"
    cat <<EOT
    healthcheck:
      interval: 5s
      retries: 5
      start_period: 10s
      test: $test
      timeout: 10s
EOT
}

# The MAS bits in Synapses config file
function masSynapseConfig {
    export masManagement="https://$masHost:$listenPort/"
    yq --inplace '
        .enable_registration = false |
        .matrix_authentication_service.enabled = true |
        .matrix_authentication_service.endpoint = "http://mas:8080/" |
        .matrix_authentication_service.secret = "secret"
    ' "$synapseConfigFile"
}

# Fetch Postgres sample config file from container
function fetchPostgresConfig {
    local overwrite=0
    checkOverwrite "$customPostgresConfig" "$postgresConfigFileSynapse" \
        "$postgresConfigFileMas" || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

    touch "$postgresConfigFileSynapse"
    podman run --entrypoint "/bin/bash" --interactive --rm --tty \
        --volume "$postgresConfigFileSynapse":/tmp/postgresql.conf:Z \
        "$postgresImage" \
        -c "cat /usr/share/postgresql/postgresql.conf.sample \
            > /tmp/postgresql.conf"
    cp "$postgresConfigFileSynapse" "$postgresConfigFileMas"
}

# Create the Podman compose file
function generatePodmanCompose {
    local overwrite=0
    checkOverwrite true "$composeFile" || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

    if [[ "$enableHookshot" == true ]]; then
        synapseAdditionalVolumes+=(
          "$hookshotRegistrationFile:/appservices/hookshot.yaml"
        )
    fi

    synapseAdditionalVolumesYaml=""
    local volume
    for volume in "${synapseAdditionalVolumes[@]}"; do
        synapseAdditionalVolumesYaml+="
      - $volume:z"
    done

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
    environment:
      - NGINX_PORT=$ingressPort
$(healthcheck "curl --fail --max-time 2 --show-error --silent http://localhost:80")
    image: $nginxImage
    ports:
      - "127.0.0.1:$ingressPort:$ingressPort/tcp"
    restart: unless-stopped
    volumes:
      - $nginxConfigFile:/etc/nginx/conf.d/custom.conf:Z
      - $privateKeyFile:/tmp/private.key:Z
      - $publicKeyFile:/tmp/public.key:Z

  synapse:
    container_name: $workDirBaseName-synapse
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
$(healthcheck "curl --fail --max-time 2 --show-error --silent http://localhost:8448/health")
    image: $synapseImage
    ports:
      - 127.0.0.1:47601-47602:8008-8009/tcp
      - 127.0.0.1:47600:8448/tcp
      - 127.0.0.1:47615:19090/tcp
    restart: unless-stopped
    volumes:
      - $synapseData:/data:Z$synapseAdditionalVolumesYaml

  postgres:
    container_name: $workDirBaseName-postgres
    environment:
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
      - POSTGRES_PASSWORD=password
      - POSTGRES_USER=synapse
$(healthcheck "pg_isready")
    image: $postgresImage
    ports:
      - 127.0.0.1:47610:5432/tcp
    restart: unless-stopped
    volumes:
      - postgresData:/var/lib/postgresql
EOT

    [[ "$enableAdminer" == true ]] && cat <<EOT >> "$composeFile"

  adminer:
    container_name: $workDirBaseName-adminer
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
$(healthcheck "curl --fail --max-time 2 --show-error --silent http://localhost:8080")
    image: $adminerImage
    ports:
      - 127.0.0.1:47603:8080/tcp
    restart: unless-stopped
EOT

    [[ "$enableElementAdmin" == true ]] && cat <<EOT >> "$composeFile"

  elementadmin:
    container_name: $workDirBaseName-elementadmin
    environment:
      - SERVER_NAME=$serverName
$(healthcheck "wget --no-verbose --tries=1 --spider http://localhost:8080 || exit 1")
    image: $elementAdminImage
    ports:
      - 127.0.0.1:47616:8080/tcp
    restart: unless-stopped
EOT

    [[ "$enableElementWeb" == true ]] && cat <<EOT >> "$composeFile"

  elementweb:
    container_name: $workDirBaseName-elementweb
    environment:
      - ELEMENT_WEB_PORT=8080
$(healthcheck "wget --no-verbose --tries=1 --spider http://localhost:8080 || exit 1")
    image: $elementImage
    ports:
      - 127.0.0.1:47604:8080/tcp
    restart: unless-stopped
    volumes:
        - $elementConfigFile:/app/config.json:Z
EOT

    [[ "$enableMas" == true ]] && cat <<EOT >> "$composeFile"

  mas:
    container_name: $workDirBaseName-mas
    depends_on:
      mas-postgres:
        condition: service_healthy
    environment:
      - MAS_CONFIG=/config.yaml
    image: $masImage
    ports:
      - 127.0.0.1:47605:8080/tcp
    restart: unless-stopped
    volumes:
      - $masConfigFile:/config.yaml:Z

  mas-postgres:
    container_name: $workDirBaseName-mas-postgres
    environment:
      - POSTGRES_PASSWORD=password
      - POSTGRES_USER=mas
$(healthcheck "pg_isready")
    image: $postgresImage
    ports:
      - 127.0.0.1:47609:5432/tcp
    restart: unless-stopped
    volumes:
      - masPostgresData:/var/lib/postgresql
EOT

    [[ "$enableEmail" == true ]] && cat <<EOT >> "$composeFile"

  mailhog:
    container_name: $workDirBaseName-mailhog
$(healthcheck "wget --no-verbose --tries=1 --spider http://localhost:8025 || exit 1")
    image: $mailhogImage
    ports:
      - 127.0.0.1:47612:8025/tcp
      - 127.0.0.1:47613:1025/tcp
    restart: unless-stopped
EOT

    [[ "$enableKetesa" == true ]] && cat <<EOT >> "$composeFile"

  ketesa:
    container_name: $workDirBaseName-ketesa
    environment:
      - SERVER_PORT=8080
$(healthcheck "wget --no-verbose --tries=1 --spider http://localhost:8080 || exit 1")
    image: $ketesaImage
    ports:
      - 127.0.0.1:47611:8080/tcp
      - 127.0.0.1:47614:80/tcp
    restart: unless-stopped
EOT

    [[ "$enableHookshot" == true ]] && cat <<EOT >> "$composeFile"

  hookshot:
    container_name: $workDirBaseName-hookshot
    depends_on:
      redis:
        condition: service_healthy
      synapse:
        condition: service_healthy
    image: $hookshotImage
    ports:
      - 127.0.0.1:47606-47607:9993-9994/tcp
      - 127.0.0.1:47617:7775/tcp
    restart: unless-stopped
    volumes:
      - $hookshotData:/data:z
      - hookshotEncryptionData:/encryption

  redis:
    command: redis-server --save 20 1 --loglevel warning
    container_name: $workDirBaseName-redis
$(healthcheck "["CMD", "redis-cli", "--raw", "incr", "ping"]")
    image: $redisImage
    ports:
      - 127.0.0.1:47608:6379/tcp
    restart: unless-stopped
    volumes:
      - redisData:/data
EOT

    # Add Postgres config file mounts to compose file
    if [[ "$customPostgresConfig" == true ]]; then
        export pgManMount="$postgresConfigFileMas:/etc/postgresql/postgresql.conf:Z"
        export pgSynMount="$postgresConfigFileSynapse:/etc/postgresql/postgresql.conf:Z"

        yq --inplace '.services.postgres.volumes += [env(pgSynMount)]' \
            "$composeFile"

        [[ "$enableMas" == true ]] && yq --inplace '
            .services.mas-postgres.volumes += [env(pgManMount)]
        ' "$composeFile"

        export cmd="postgres -c config_file=/etc/postgresql/postgresql.conf"
        yq --inplace '.services.postgres.command += env(cmd)' "$composeFile"
        [[ "$enableMas" == true ]] && \
            yq --inplace '.services.mas-postgres.command += env(cmd)' \
            "$composeFile"
    fi
}

# Generate Element Web config
function generateElementConfig {
    local overwrite=0
    checkOverwrite "$enableElementWeb" "$elementConfigFile" || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

    cat <<EOT > "$elementConfigFile"
{
    "${workDirBaseName}_notice": "This file is managed by $scriptPath",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "dangerously_allow_unsafe_and_insecure_passwords": true,
    "default_country_code": "GB",
    "default_federate": true,
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$synapseHost:$listenPort",
            "server_name": "$serverName"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "default_theme": "light",
    "default_widget_container_height": 280,
    "disable_3pid_login": false,
    "disable_custom_urls": false,
    "disable_guests": false,
    "disable_login_language_selector": false,
    "element_call": {
        "brand": "Element Call",
        "disable": false,
        "use_exclusively": false
    },
    "enable_presence_by_hs_url": {
        "https://$synapseHost:$listenPort": $synapseEnablePresence,
        "https://$serverName": $synapseEnablePresence
    },
    "features": {
        "feature_jump_to_date": true,
        "feature_release_announcement": false,
        "feature_state_counters": true
    },
    "force_verification": false,
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
        "breadcrumbs": true,
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

# Generate Hookshot config
function generateHookshotConfig {
    local overwrite=0
    checkOverwrite "$enableHookshot" "$hookshotData" "$hookshotConfigFile" \
        "$hookshotPasskeyFile" "$hookshotRegistrationFile" || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

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
  mediaUrl: https://$synapseHost:$listenPort
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
  urlPrefix: https://$hookshotHost:$listenPort/webhook/
  userIdPrefix: _webhooks_
  waitForComplete: false
listeners:
  - bindAddress: 0.0.0.0
    port: 9994
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
  publicUrl: https://$hookshotHost:$listenPort/widgetapi/v1/static/
  roomSetupWidget:
    addOnInvite: false
EOT

    [[ "$hookshotEncryption" == true ]] && \
        yq --inplace '.encryption.storagePath = "/encryption"' \
        "$hookshotConfigFile"

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
    local passkeyB64="LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUpRZ0lCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQ1N3d2dna29BZ0VBQW9JQ0FRREUwS3V6djRXZTY0RTcKaGdJMjQ0RTdlVGZNd1hkL0VncFlSem9GWWZ2Vlh1TUYvdVE2THZVTXpuNG96MjhrNzlGOW5jS2taNy9Qa1NTbApZeWo2bGRYenFvVnZQVHZ6Um81WDJGSFBuMFdRdHVDOTBld2w1akYwV2F5S1JQYiswVGZGdHQ1dW9vTnA3dFEzCkhST0l0SzNEZ1dITDFKOEZia1dkQXJ2a3ZYYVQxcGMvNkcxV3NDUDNPR2U2cUhYdHdSRXdEQ3NFZFlEQW45M3kKOWRYNDRJblZOMWl0SENpWTkxQ3MyUHBTWXhab1d4Z2V1Q0NYUjJMRmY1RVhqbHU2eEQ3SU9OVEJoVGtPdlFYLwp1bktXeXNJNXBVWnA5bTJGRUxXT0pJV3NGTkJPOXVFVFdqMVVpVUZZMHZwckppRW13S05NM29CUGZBa0pQWk1vCmloQWNwcUZ2aEhvcmVFS3VKaExRWlNMK09kVmRYQWdMN2Q3UkVicTVsMndtKzFVRXQzdEdXeXhkMTZvY013WVUKQ0xBUUpKVS9tUm1qcWhiekg3cDJPSURtNWhkQ255UVFTOTAwT0cwOGZrNDlEakdBODkzUE5hUkYzUGlzalRRSApHRnpxQzJxRjVLOFV0bVpid1VVTXc4NkJHWnhnVnNlVWYyUGU4TVkxMUVHUTQvTGdtdW5zUXNGYkRHWFVLeVByCk4vY1IvbGdZSmVlUmQxcTFZbnVMK0lic3grSnFnUE9uS1dtVmtwUlZ2QTcyNUZZQy9WOGc3d2NkWlJCcEowYWMKYlZmbFdzNVpydVpaeFJZaVJEM3JSdmt6R1FDbCtiSkNIZHU3TElSRU5NUENLVjB3aXVuN0pWTUFOSEUxajNqYQpQTWFNcTNrRFh6ZmthWHo3V2tJVE10KzVDV2ltR1FJREFRQUJBb0lDQURiK04zdmFIL1B2eWdSZnhXNmcweE5UCkk0eEs0cURXNFowWkNkVkhNNTdEREp3NFJIMGRjY3RLUjJZUHovWjZMQWIxZGRXS1I4WXZ3QldXUjNUOU9QTUUKeXBQeWdEWFJtU1JpaFRtR1AySFlONlBTYkRHS3lIYkNON3ZLMlZrS0RKTnFMV3lzYkJ2RlovYWVZVDdwZlVRTApldEFCY1EyTGFsZ2MwM051blJ0aDhwRWcyS3hJTzBSd3Rrc3Bsd24vMEZXa2tNQ0dOSnVlRDk0N1lyWlB4ek9VCmEycXpXNFNpVmlCMTREdjFBK1hVemtDSElsUWkxaTVwSHBsK1paTWlFb2pQbUdNYVhuOEh3ZzFhZzNvdTNXWk8KRUFhN25JNTV4TUVhNDE3WjBmcStjTlYvZVhPTmhuelROcldKeWVtU0dnNzRmTkc0enEyT1R2Z2MyN09sdTZWMwpkQWRmZm1lMjFndGpHNU5WQlhQcDNKWnVIVWE2c3RaZUhraHR6SG15amkvL2Ezc1hDME1nNnpvM3RPcStEYk5uClEzVlRVSFFaRmNtQldMOXlHZEVVU1R1SnU2Y3JJTlR5OHhpN1VRS0tJSHBVRWZKYWluN0FPZHcrRFN6SllWTmgKclp1aTNUSWI5MTI5OUxCaGRMMWlmaUJsQkpHbzRYQS8rbENhNTBsOVNFaE14elcyeEJKcS96ZVJ1RDNvV3I2ZApCQ2RrYnJxTTY2OHpFR0szanBNMFRMUU12QmtRT3lMdnlNS3BwS0J4bitIbHV1RDRsQVg4Um9ScVVGZVdmdUR1CndLWTBMZUVqT29ETm5FYWYzSC9WZUZtNXVjaHN1Y3FJOGdzRTMyOGdncGhXUFhVKzJsaHJ6ZW1RVWNFV2hLVTMKMldnbklLcFR5QURqbU1xUElDZWhBb0lCQVFEME5mQ2ptUFJwa052cE1DbjM2UmtBd1NTeDhSZ0NzTmc0NHg1aQpLSFFMT0UzRWNnVkdLeFNpalZIWlZDQzM4Um9MU2NZcXVNK3VSLzdNdUR6N1pyMVZPZmJiRjJ4TElod3N4eWE5ClhqUld6bVFKMXl6bnZ3SFh4UDRucUlIOEd0RU9hY25VOU5XVGdCcitUdkh3Qng0cTJiV0UrSnNZRlNiUW1zZy8Kc2N6a1hablNHNnVpVk5WdXFEWVdacDJBTTFyelNJbldFbHdIdytEMjdGQ0NjTi9YOWhwbk5Ydll3MlNzMkJSWQplYWZLWTUxbHU4MHNmTXBibXJRb205Wm1FOUVnRjZ4T1RhNWtuVWdZU0ZXL1JzMWtoRFNuZ1k3NWVIbStnOWRZCjl2bGtqeWhBUzZNd1RGL3d3bGU5emZKZVQzY1RYenNoTmh3UmdnWEJEb2tKdFc3bkFvSUJBUURPVVA3eWpoekEKclZGTGJNRjF6aXRRYStyL3RSQ0VjcWluUnhHWnFpcnBxYmN5UDJaS0RkRmdMaDR3Q3RGTVVEODFJNjQwNmZJWgp2U09Od0dCbUI5S1luZkIzUlVQY29TRXBDbzhETDBMVzgyV0QrNGhtSFhjYzRHQ2ZtZmtHRGhvZkVHNGFlRWJjCmphd0ZiN09KUHU5UE9LYXQyZ0VkTksxNGZOWDlSNTAySWNYbU1uUzZIa21SMllFNWdDRzVMMzF6NVlucUhjQ2sKamxkNjErM3FLaVpNMWhEU0ZTYmN3MTFrREhheklGTkljM2ZUbWJzWFNtSzcxdGdLU2J0dHBmYUhaMkYxS1FIawoxVUhoYzJmY2lNQzd3d2lmeTZqUEpJU0dMYjV0MWFuSkt5c2Z4bktuR1cvZlJIaDBoZzlJREtRcXd0cENyR2JpCkRKamJsL09iVjZML0FvSUJBREp2Zlc1Y0pZWXoyNmNTUW1pbjVIa0thcWl4VVRNbEVOTFczU3lLakVUUThRYTAKUWJDWEx5RFBMT3RFZTZsaGl1NXY0eFJwck1LaXJkWGI2d1JFMks5a1ZENDFYVEU3THpSMFFPVDFNcndHemhSVwpNemo5Y3NUOE16MC9pUERuSE92c0h6bnpBclQrelJSZWU0c0YvVTMrUG9YaXppMHdHUjhXQ0d0WExpaXZ5QmZqCmpSUHVqMUhXUGExc3JmU1BKcVorQWJHTGd5UTdhUmUyQUg2Z0R5ckw4ZklFMHJvV3lKRUY0MVhPY2ovVFNPdDgKMk1mcVVlU1BVOHZiTzNGRGdIb3ZTVysyaldETU50cUUvZWlPRjljOWtwNVJuSlNiTkJHTHF3cjluczRNM3RSQQppc2hyelppc21uQmh1eitOQzl1ZFhGbmtrZkZ2dC82Q0lQMDNVbHNDZ2dFQWZPM0dzeEVpai9saTlJMFNTRWRqCkt2dHQvUkNpdzlDNkZ6Q05rOExhNFVxSFI4SGtLb3RiY1NYNzJaTnpVUVoyZjdMdlZkTWphanFCUU9Cd2Z0ZlYKeWR3NU03K1piQXVWak1oNytLMnhoMzh5eFV5V04xODROU0FZNGd2V0lyaC9VTGdlTTZFSko1d1J3ZWoxaWZHMQo3djZhejBMbTBjeUlEaUZwWWtqdkJVeEdEVElZUkdyNm1YcGZLWFpROVZXd1hYRnNwWHNHbjU0aGtwMFZ6MmxlCmI4QmZ4eFpQeGZYMm94SjQvZFpoRjhuemtRblJwRFRDdklOSHBsTW5UeW5qc2ZJRHJYSDdWNWxhbnkzR2dsKzgKZFBXUVQxSi9FWTlIUUFpSyt1OGFORm9UYnRZM3JyOVVZcG1QWnQrV2VVWk9VaVpUQzNSaGlCZWdwN2ZISnhWVgorUUtDQVFFQTBCOGpENWFtTFlEVlNmREtoWDN3Qm5nK2wvREw0UUpsdytnR3hBNDRJY1V2Q25FN3IvclhsM0s5CmRVZmFGUHNpZU4vdGZld0RFTmxyT3EvcnIrLzJTdHBmTlpvMUxSSlVsS2NTSmRodVpEU0JsMy9wL2tMdWxwNUQKVnhlQmRZbkdJeGZxZmxlMTdnSUxaNWRJZmt4a253dHJ0ZXEzMkZDNUhQZjl0YmdSL0l0YnRvSkp2NXdhTEdNTgorZkZOQzFhQ1FJSXZIQ0REZnMyR2VvRTZ0elRmUkRwRFNMdjh2QlVwSFFFbVZmOG5FYlhIaUM4dWQ0cGdkWVF6Cm1BSVpwL29TKzZiU0dOQ01sRzdhQ3J4QllhN003LzZ0RnhTNEc5NUpJTC95azVZTjRPL3hVQkRNcGdFWFdLZU8KS0VMS2IxcGo4Si9qcDVwUnA1QXR5RzJpTXd4RUtnPT0KLS0tLS1FTkQgUFJJVkFURSBLRVktLS0tLQ=="
    echo "$passkeyB64" | base64 --decode > "$hookshotPasskeyFile"

    podmanPermissions "$hookshotData" "991"
}

# Generate MAS config
function generateMasConfig {
    local overwrite=0
    checkOverwrite "$enableMas" "$masConfigFile" || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

    # Delete the files so MAS can re-generate them
    [[ -f "$masConfigFile" ]] && rm "$masConfigFile"

    # Use MAS' built-in executable to generate default config file
    podman run --interactive --quiet --rm --tty "$masImage" \
        config generate | grep -v INFO > "$masConfigFile"

    yq --inplace 'del(.http.trusted_proxies)' "$masConfigFile"
    yq --inplace 'del(.http.listeners[0].binds[0])' "$masConfigFile"
    yq --inplace 'del(.database)' "$masConfigFile"
    export masManagement="https://$masHost:$listenPort"
    export swaggerCallback="https://$masHost:$listenPort/api/doc/oauth2-callback"
    yq --inplace '
        .account.password_registration_email_required = false |
        .account.password_registration_enabled = true |
        .clients[0].client_auth_method = "client_secret_basic" |
        .clients[0].client_id = "0000000000000000000SYNAPSE" |
        .clients[0].client_secret = "secret" |
        .clients[1].client_auth_method = "client_secret_post" |
        .clients[1].client_id = "01JTTHHQBMKE8W3VCXRVFVW04P" |
        .clients[1].client_secret = "secret" |
        .clients[1].redirect_uris[0] = "https://element-hq.github.io/matrix-authentication-service/api/oauth2-redirect.html" |
        .clients[1].redirect_uris[1] = env(swaggerCallback) |
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
        .http.trusted_proxies[0] = "192.168.0.0/16" |
        .http.trusted_proxies[1] = "172.16.0.0/12" |
        .http.trusted_proxies[2] = "10.0.0.0/8" |
        .http.trusted_proxies[3] = "127.0.0.0/8" |
        .http.trusted_proxies[4] = "fd00::/8" |
        .http.trusted_proxies[5] = "::1/128" |
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

    masSynapseConfig

    if [[ "$enableEmail" == true ]]; then
        export masEmailFrom="mas@$serverName"
        yq --inplace '
            .account.password_registration_email_required = true |
            .email.from = env(masEmailFrom) |
            .email.hostname = "mailhog" |
            .email.mode = "plain" |
            .email.port = 1025 |
            .email.reply_to = env(masEmailFrom) |
            .email.transport = "smtp"
        ' "$masConfigFile"
    fi
}

# Print Nginx headers for default reverse proxy
function commonProxyHeaders {
    cat <<EOT
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        client_max_body_size 50M;
        proxy_http_version 1.1;
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
EOT
}

# Print a standard Nginx config server {} block
function standardProxyServer {
    local comment="$1"
    local host="$2"
    local proxy="$3"

    cat <<EOT

# $comment
server {
    listen $ingressPort ssl;
    server_name $host;

    ssl_certificate /tmp/public.key;
    ssl_certificate_key /tmp/private.key;

    location / {
        proxy_pass http://$proxy;
$(commonProxyHeaders)
    }
}
EOT
}

# Generate Nginx config
function generateNginxConfig {
    local overwrite=0
    checkOverwrite true "$nginxConfigFile" || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

    cat <<EOT > "$nginxConfigFile"
# Well-known
server {
    listen $ingressPort ssl;
    server_name $serverName;

    ssl_certificate /tmp/public.key;
    ssl_certificate_key /tmp/private.key;

    location /.well-known/matrix/client {
        return 200 '{"m.homeserver":{"base_url":"https://$synapseHost:$listenPort"}}';
        add_header Content-Type application/json;
        add_header 'Access-Control-Allow-Origin' '*';
    }
    location /.well-known/matrix/server {
        return 200 '{"m.server": "$synapseHost:$listenPort"}';
        add_header Content-Type application/json;
    }
    location /_matrix/client/unstable/registration/email/submit_token {
        proxy_pass http://synapse:8448;
$(commonProxyHeaders)
    }
}
EOT

    if [[ "$enableMas" == false ]]; then
        standardProxyServer "Synapse" "$synapseHost" \
        "synapse:8448" >> "$nginxConfigFile"

    else
        cat <<EOT >> "$nginxConfigFile"

# Synapse
server {
    listen $ingressPort ssl;
    server_name $synapseHost;

    ssl_certificate /tmp/public.key;
    ssl_certificate_key /tmp/private.key;

    location ~ ^/_matrix/client/(.*)/(login|logout|refresh) {
        proxy_pass http://mas:8080;
$(commonProxyHeaders)
    }
    location / {
        proxy_pass http://synapse:8448;
$(commonProxyHeaders)
    }
}

$(standardProxyServer "MAS" "$masHost" "mas:8080")

EOT
    fi

    [[ "$enableEmail" == true ]] && \
        standardProxyServer "Mailhog" "$mailhogHost" \
        "mailhog:8025" >> "$nginxConfigFile"

    [[ "$enableElementAdmin" == true ]] && \
        standardProxyServer "Element Admin" "$elementAdminHost" \
        "elementadmin:8080" >> "$nginxConfigFile"

    [[ "$enableElementWeb" == true ]] && \
        standardProxyServer "Element Web" "$elementHost" \
        "elementweb:8080" >> "$nginxConfigFile"

    [[ "$enableHookshot" == true ]] && \
        standardProxyServer "Hookshot" "$hookshotHost" \
        "hookshot:9994" >> "$nginxConfigFile"

    [[ "$enableAdminer" == true ]] && \
        standardProxyServer "Adminer" "$adminerHost" \
        "adminer:8080" >> "$nginxConfigFile"

    [[ "$enableKetesa" == true ]] && \
        standardProxyServer "Ketesa" "$ketesaHost" \
        "ketesa:8080" >> "$nginxConfigFile"
}

# Generate an SSL certificate
function generateSslCertificate {
    local overwrite=0
    checkOverwrite "$enableSSL" "$publicKeyFile" "$privateKeyFile" \
        || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

    # Delete the files so they can be re-generated
    [[ -f "$publicKeyFile" ]] && rm "$publicKeyFile"
    [[ -f "$privateKeyFile" ]] && rm "$privateKeyFile"

    mkcert -cert-file "$publicKeyFile" -key-file "$privateKeyFile" \
        "*.$serverName" "$serverName"
}

# Generate Synapse config
function generateSynapseConfig {
    local overwrite=0
    checkOverwrite true "$synapseConfigFile" "$synapseLogConfigFile" \
        "$synapseData/$serverName.signing.key" || overwrite=$?
    [[ "$overwrite" == 1 ]] && return 0

    # Delete the files so Synapse can re-generate them
    [[ -f "$synapseConfigFile" ]] && rm "$synapseConfigFile"
    [[ -f "$synapseLogConfigFile" ]] && rm "$synapseLogConfigFile"

    # Use Synapse's built-in executable to generate default config files
    podman run --entrypoint "/bin/bash" --interactive --rm --tty --volume \
        "$synapseData":/data:Z "$synapseImage" \
        -c "python3 -m synapse.app.homeserver \
            --config-path /data/homeserver.yaml \
            --data-directory /data \
            --generate-config \
            --report-stats no \
            --server-name $serverName"

    podmanPermissions "$synapseData" "991"

    mv "$synapseGeneratedLogConfigFile" "$synapseLogConfigFile"

    # Customise Synapse config
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
        .trusted_key_servers[0].accept_keys_insecurely = true |
        .user_directory.enabled = true |
        .user_directory.prefer_local_users = true |
        .user_directory.search_all_users = true
    ' "$synapseConfigFile"

    if [[ "$enableEmail" == true ]]; then
        export synapseEmailFrom="Your Friendly %(app)s homeserver <mas@$serverName>"
        export elementUrl="https://$elementHost:$listenPort"
        yq --inplace '
            .email.client_base_url = env(elementUrl) |
            .email.enable_notifs = true |
            .email.enable_tls = false |
            .email.force_tls = false |
            .email.invite_client_location = env(elementUrl) |
            .email.notif_for_new_users = true |
            .email.notif_from = env(synapseEmailFrom) |
            .email.require_transport_security = false |
            .email.smtp_host = "mailhog" |
            .email.smtp_port = 1025 |
            .email.validation_token_lifetime = "15m"
        ' "$synapseConfigFile"
    fi

    if [[ "$enableHookshot" == true ]]; then
        yq --inplace '
            .app_service_config_files[0] = "/appservices/hookshot.yaml"
        ' "$synapseConfigFile"
    fi

    if [[ "$enableHookshot" == true ]] && \
        [[ "$hookshotEncryption" == true ]]
    then
        yq --inplace '
            .experimental_features.msc2409_to_device_messages_enabled = true |
            .experimental_features.msc3202_device_masquerading = true |
            .experimental_features.msc3202_transaction_extensions = true
        ' "$synapseConfigFile"
    fi

    [[ "$enableMas" == true ]] && masSynapseConfig
}

# Print links
function printLinks {
    local links="Links:\n\n- Synapse server name: $serverName"
    links+="\n- Synapse endpoint:    https://$synapseHost:$listenPort"
    [[ "$enableElementAdmin" == true ]] && \
        links+="\n- Element Admin:       https://$elementAdminHost:$listenPort"
    [[ "$enableElementWeb" == true ]] && \
        links+="\n- Element Web:         https://$elementHost:$listenPort"
    [[ "$enableMas" == true ]] && \
        links+="\n- MAS:                 https://$masHost:$listenPort"
    [[ "$enableMas" == true ]] && \
        links+="\n- MAS Swagger UI:      https://$masHost:$listenPort/api/doc/"
    [[ "$enableAdminer" == true ]] && \
        links+="\n- Adminer:             https://$adminerHost:$listenPort"
    [[ "$enableKetesa" == true ]] && \
        links+="\n- Ketesa:              https://$ketesaHost:$listenPort?\
username=admin&password=admin&server=https://$synapseHost:$listenPort"
    [[ "$enableEmail" == true ]] && \
        links+="\n- Mailhog:             https://$mailhogHost:$listenPort"

    echo -e "$links"                
}

# Restart a container with no extra tasks
function restartContainer {
    local containerName="$1"
    local restartNginx="$2"

    podman restart "$workDirBaseName-$containerName"
    [[ "$restartNginx" == true ]] && podman restart "$workDirBaseName-nginx"
}

# Restart the MAS container
function restartMas {
    podman restart "$workDirBaseName-mas"
    podman exec --interactive --tty "$workDirBaseName-mas" mas-cli config check
    podman exec --interactive --tty \
        "$workDirBaseName-mas" mas-cli config sync --prune
    restartContainer "nginx" false
}

# Create/Start/Restart containers
function restartAll {
    if [[ "$composeDash" == true ]]; then
        podman-compose up --detach --force-recreate
    else
        podman compose up --detach --force-recreate --remove-orphans
    fi
    restartContainer "nginx" false
}

# Run checks
checkRequiredPrograms
checkRequiredDirectories

# Parse command line option
case $1 in
    admin)      createAdminAccount                      ;;
    comp)       createCompatibilityToken                ;;
    delete)     deleteEnvironment                       ;;
    gencom)     generatePodmanCompose                   ;;
    genele)     generateElementConfig                   ;;
    genhook)    generateHookshotConfig                  ;;
    genmas)     generateMasConfig                       ;;
    genng)      generateNginxConfig                     ;;
    genssl)     generateSslCertificate                  ;;
    gensyn)     generateSynapseConfig                   ;;
    links)      printLinks                              ;;
    ps)         simplePodman ps                         ;;
    pull)       simplePodman pull                       ;;
    rsa)        restartAll                              ;;
    rsea)       restartContainer "elementadmin" true    ;;
    rsew)       restartContainer "elementweb" true      ;;
    rsh)        restartContainer "hookshot" true        ;;
    rsk)        restartContainer "ketesa" true          ;;
    rsn)        restartContainer "nginx" false          ;;
    rspm)       restartContainer "mas-postgres" false   ;;
    rsps)       restartContainer "postgres" false       ;;
    rss)        restartContainer "synapse" true         ;;
    rsm)        restartMas                              ;;
    setup)
        fetchPostgresConfig
        generatePodmanCompose
        generateNginxConfig
        generateElementConfig
        generateHookshotConfig
        generateSynapseConfig
        generateMasConfig
        generateSslCertificate
        simplePodman pull
        restartAll
        ;;
    stop)       simplePodman stop                       ;;
    *)          help                                    ;;
esac
