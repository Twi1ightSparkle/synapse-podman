#!/bin/bash
# shellcheck source=/dev/null

# Quickly spin up a Synapse + Postgres in Podman for testing.
# Copyright (C) 2024  Twilight Sparkle
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
    delete:     Delete the environment, Synapse/Postgres data, and config files.
    gencom:     Regenerate the Podman Compose file.
    genele:     Regenerate the Element Web config file.
    gensyn:     Regenerate the Synapse config and log config files.
    help:       This help text.
    rsa:        Restart all containers.
    rse:        Restart the Element Web container.
    rss:        Restart the Synapse container.
    setup:      Create, edit, (re)start the environment.
    stop:       Stop the environment without deleting it.

Note: rsa and setup will recreate all containers and remove orphaned
containers. Synapse/Postgres data is not deleted.
EOT
}

# Load config
if [ -f "$configFile" ]; then
    source "$configFile"
else
    synapseImage="ghcr.io/element-hq/synapse:latest"
    synapsePort=8448
    synapseAdditionalVolumes=""
    postgresImage="docker.io/postgres:latest"
    portgresPort=5432
    enableAdminer=true
    adminerImage="docker.io/adminer:latest"
    adminerPort=10001
    enableElementWeb=true
    elementImage="vectorim/element-web:latest"
    elementPort=10000
fi

# This variable needs to be exported so it can be used with yq
export synapsePortEnv="$synapsePort"

# Vars
synapseData="$workDirFullPath/synapse"
composeFile="$workDirFullPath/compose.yml"
elementConfigFile="$workDirFullPath/elementConfig.json"
serverName="localhost:$synapsePort"
synapseConfigFile="$synapseData/homeserver.yaml"
synapseLogConfigFile="$synapseData/localhost:$synapsePort.log.config"

# Check that required programs are installed on the system
function checkRequiredPrograms {
    programs=(bash podman yq)
    missing=""
    for program in "${programs[@]}"; do
        if ! hash "$program" &>/dev/null; then
            missing+="\n- $program"
        fi
    done
    if [ -n "$missing" ]; then
        echo -e "Required programs are missing on this system. Please install:$missing"
        exit 1
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
        podmanPermissions "$volume" "991"
    done
}

# Create Synapse admin account
function createAdminAccount {
    podman exec \
        "$workDirBaseName-synapse-1" \
        /bin/bash \
        -c "register_new_matrix_user \
            --admin \
            --config /data/homeserver.yaml \
            --password admin \
            --user admin"
    exit 0
}

# Delete the environment
function deleteEnvironment {
    msg="Enter YES to confirm deleting the environment, Postgres volume, and the directories/files synapse/, "
    msg+="compose.yml, and elementConfig.json: "
    read -rp "$msg" verification
    [[ "$verification" != "YES" ]] && exit 0
    podman compose down --remove-orphans
    podman volume rm "${workDirBaseName}_postgresData"
    [[ -f "$composeFile" ]] && rm -rf "$composeFile"
    [[ -f "$elementConfigFile" ]] && rm -rf "$elementConfigFile"
    [[ -d "$synapseData" ]] && rm -rf "$synapseData"
}

# Create the Podman compose file
function generatePodmanCompose {
    synapseAdditionalVolumesYaml=""
    for volume in "${synapseAdditionalVolumes[@]}"; do
        synapseAdditionalVolumesYaml+="\n      - $volume:Z"
    done

    # We need $verification 
    if [[ -f "$composeFile" ]]; then
         read -rp "Overwrite $composeFile? [y/N]: " verification
    else
        verification=y
    fi

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ ! -f "$composeFile" ]] || [[ "$verification" == "y" ]] && cat <<EOT > "$composeFile"
# This file is managed by $scriptPath

volumes:
    postgresData:

services:
  synapse:
    image: $synapseImage
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      - SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
    ports:
      - 127.0.0.1:8008-8009:8008-8009/tcp
      - 127.0.0.1:$synapsePort:$synapsePort/tcp
    volumes:
      - $synapseData:/data:Z$synapseAdditionalVolumesYaml

  postgres:
    image: $postgresImage
    restart: unless-stopped
    environment:
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
      - POSTGRES_PASSWORD=password
      - POSTGRES_USER=synapse
    ports:
      - 127.0.0.1:$portgresPort:5432/tcp
    volumes:
      - postgresData:/var/lib/postgresql/data
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableAdminer" == true ]] && [[ "$verification" == "y" ]] && cat <<EOT >> "$composeFile"

  adminer:
    image: $adminerImage
    restart: unless-stopped
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
    ports:
      - 127.0.0.1:$adminerPort:8080/tcp
EOT

    # If user agreed to overwrite AND the target file to overwrite exists
    [[ "$enableElementWeb" == true ]] && [[ "$verification" == "y" ]] && cat <<EOT >> "$composeFile"

  elementweb:
    image: $elementImage
    restart: unless-stopped
    ports:
      - 127.0.0.1:$elementPort:80/tcp
    volumes:
        - $elementConfigFile:/app/config.json:Z
EOT
}

# Generate Element Web config if not present or ask to overwrite
function generateElementConfig {
    [[ -f "$elementConfigFile" ]] && read -rp "Overwrite $elementConfigFile? [y/N]: " verification
    
    # If user agreed to overwrite AND the target file to overwrite exists
    [[ ! -f "$elementConfigFile" ]] || [[ "$verification" == "y" ]] && cat <<EOT > "$elementConfigFile"
{
    "${workDirBaseName}_notice": "This file is managed by $scriptPath",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "dangerously_allow_unsafe_and_insecure_passwords": true,
    "default_country_code": "US",
    "default_federate": true,
    "default_server_config": {
        "m.homeserver": {
            "base_url": "http://$serverName",
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
    "features": {
        "feature_jump_to_date": true,
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

# Generate Synapse config if not present or ask to overwrite
function generateSynapseConfig {
    # Ask the user to overwtie if EITHER the Syanspe config file OR Synapse log config file exists
    [[ -f "$synapseConfigFile" ]] || [[ -f "$synapseLogConfigFile" ]] && \
        read -rp "Overwrite $synapseConfigFile and $synapseLogConfigFile? [y/N]: " verification

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

        # Customize Synapse config
        yq -i '.handlers.file.filename = "/data/homeserver.log"' "$synapseLogConfigFile"
        yq -i 'del(.listeners[0].bind_addresses)' "$synapseConfigFile"
        yq -i '
            .listeners[0].bind_addresses[0] = "0.0.0.0" |
            .listeners[0].port = env(synapsePortEnv) |
            .database.name = "psycopg2" |
            .database.args.user = "synapse" |
            .database.args.password = "password" |
            .database.args.database = "synapse" |
            .database.args.host = "postgres" |
            .database.args.cp_min = 5 |
            .database.args.cp_max = 10 |
            .trusted_key_servers[0].accept_keys_insecurely = true |
            .suppress_key_server_warning = true |
            .enable_registration = true |
            .enable_registration_without_verification = true |
            .presence.enabled = false |
            .user_directory.enabled = true |
            .user_directory.search_all_users = true |
            .user_directory.prefer_local_users = true
        ' "$synapseConfigFile"
    fi
}

# Create/Start/Restart comtainers
function restartAll {
    podman compose up --detach --force-recreate --remove-orphans
}

# Restart the Element Web container
function restartElement {
    podman restart "$workDirBaseName-elementweb-1"
}

# Restart the Synapse container
function restartSynapse {
    podman restart "$workDirBaseName-synapse-1"
}

# Stop the environment
function stopEnvironment {
    podman compose stop
}

checkRequiredPrograms
checkRequiredDirectories

case $1 in
    admin)      createAdminAccount      ;;
    delete)     deleteEnvironment       ;;
    gencom)     generatePodmanCompose   ;;
    genele)     generateElementConfig   ;;
    gensyn)     generateSynapseConfig   ;;
    rsa)        restartAll              ;;
    rse)        restartElement          ;;
    rss)        restartSynapse          ;;
    setup)
        generatePodmanCompose
        generateElementConfig
        generateSynapseConfig
        restartAll
        ;;
    stop)       stopEnvironment         ;;
    *)          help                    ;;
esac
