#!/bin/bash

# Quickly spin up a Synapse + Postgres in docker for testing.
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
workDir="$(dirname "$scriptPath")"
configFile="$workDir/config.env"

function help {
    cat <<EOT
Usage: $scriptPath <option>

Options:
    admin:      Create Synapse admin account (username: admin. password: admin).
    delete:     Delete the environment, Synapse/Postgres data, and config files.
    gendock:    Regenerate the Docker Compose file.
    genele:     Regenerate the Element Web config file.
    gensyn:     Regenerate the Synapse config and log config files.
    help:       This help text.
    restartall: Restart all containers.
    restartele: Restart the Element Web container.
    restartsyn: Restart the Synapse container.
    setup:      Create, edit, (re)start the environment.
    stop:       Stop the environment without deleting it.

Note: restartall and setup will recreate all containers and remove orphaned
containers. Synapse/Postgres data is not deleted.
EOT
}

# Load config
if [ ! -f "$configFile" ]; then
    echo "Unable to load config file $configFile"
    exit 1
fi
source "$configFile"

# This variable needs to be exported so it can be used with yq
export synapsePortEnv="$synapsePort"

# Vars
serverName="localhost:$synapsePort"
synapseData="$workDir/synapse"
postgresData="$workDir/postgres"
elementConfigFile="$workDir/elementConfig.json"
logConfigFile="$synapseData/localhost:$synapsePort.log.config"
synapseConfigFile="$synapseData/homeserver.yaml"
dockerComposeFile="$workDir/docker-compose.yaml"

# Check that required programs are installed on the system
function checkRequiredPrograms {
    programs=(bash docker docker-compose yq)
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

# Check for required directories
function checkRequiredDirectories {
    [[ ! -d "$synapseData" ]] && mkdir "$synapseData"
}

# Create Synapse admin account
function createAdminAccount {
    docker exec \
        synapse-docker-synapse-1 \
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
    msg="Enter YES to confirm deleting the environment and the directories/files postgres, synapse, docker-compose.yaml, and elementConfig.json: "
    read -rp "$msg" verification
    [[ "$verification" != "YES" ]] && exit 0
    docker-compose down --remove-orphans
    [ -f "$dockerComposeFile" ] && rm -rf "$dockerComposeFile"
    [ -f "$elementConfigFile" ] && rm -rf "$elementConfigFile"
    [ -f "$postgresData" ] && rm -rf "$postgresData"
    [ -f "$synapseData" ] && rm -rf "$synapseData"
}

# Create the docker-compose file or ask to overwrite
function generateDockerCompose {
    synapseAdditionalVolumesYaml=""
    for volume in "${synapseAdditionalVolumes[@]}"; do
        synapseAdditionalVolumesYaml+="
      - $volume"
    done

    [[ -f "$dockerComposeFile" ]] && read -rp "Overwrite $dockerComposeFile? [y/N]: " verification
    [ "$verification" == "y" ] || [[ ! -f "$dockerComposeFile" ]] && cat <<EOT > "$dockerComposeFile"
# This file is managed by $scriptPath
version: "3"
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
      - $synapseData:/data$synapseAdditionalVolumesYaml

  postgres:
    image: docker.io/postgres:16
    restart: unless-stopped
    environment:
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
      - POSTGRES_PASSWORD=password
      - POSTGRES_USER=synapse
    ports:
      - 127.0.0.1:$portgresPort:5432/tcp
    volumes:
      - $postgresData:/var/lib/postgresql/data
EOT

    [ "$enableAdminer" == true ] && [ "$verification" == "y" ] && cat <<EOT >> "$dockerComposeFile"

  adminer:
    image: docker.io/adminer:latest
    restart: unless-stopped
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
    ports:
      - 127.0.0.1:$adminerPort:8080/tcp
EOT

    [ "$enableElementWeb" == true ] && [ "$verification" == "y" ] && cat <<EOT >> "$dockerComposeFile"

  elementweb:
    image: $elementImage
    restart: unless-stopped
    ports:
      - 127.0.0.1:$elementPort:80/tcp
    volumes:
      - $elementConfigFile:/app/config.json:ro
EOT
}

# Generate Element Web config if not present or ask to overwrite
function generateElementConfig {
    [[ -f "$elementConfigFile" ]] && read -rp "Overwrite $elementConfigFile? [y/N]: " verification
    [ "$verification" == "y" ] || [[ ! -f "$elementConfigFile" ]] && cat <<EOT > "$elementConfigFile"
{
    "synapse-docker_notice": "This file is managed by $scriptPath",
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
        "participant_limit": 8,
        "url": "https://call.element.io"
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
    "roomDirectory": {
        "servers": [
            "$serverName"
        ]
    },
    "setting_defaults": {
        "FTUE.userOnboardingButton": false,
        "MessageComposerInput.ctrlEnterToSend": true,
        "UIFeature.Feedback": false,
        "UIFeature.advancedSettings": true,
        "UIFeature.shareSocial": false,
        "alwaysShowTimestamps": true,
        "automaticErrorReporting": false,
        "ctrlFForSearch": true,
        "developerMode": true,
        "dontSendTypingNotifications": true,
        "sendReadReceipts": false,
        "sendTypingNotifications": false,
        "showChatEffects": false
    },
    "show_labs_settings": true
}
EOT
}

# Generate Synapse config if not present or ask to overwrite
function generateSynapseConfig {
    [[ -f "$synapseConfigFile" ]] || [[ -f "$logConfigFile" ]] && \
        read -rp "Overwrite $synapseConfigFile and $logConfigFile? [y/N]: " verification
    if [ "$verification" == "y" ] || [[ ! -f "$synapseConfigFile" ]]; then
        [ -f "$synapseConfigFile" ] && rm "$synapseConfigFile"
        [ -f "$logConfigFile" ] && rm "$logConfigFile"

        docker run \
            --entrypoint "/bin/bash" \
            --interactive \
            --rm \
            --tty \
            --volume "$synapseData":/data \
            "$synapseImage" \
            -c "python3 -m synapse.app.homeserver \
                --config-path /data/homeserver.yaml \
                --data-directory /data \
                --generate-config \
                --report-stats no \
                --server-name $serverName"

        # Customize Synapse config
        yq -i '.handlers.file.filename = "/data/homeserver.log"' "$logConfigFile"
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
            .presence.enabled = false
        ' "$synapseConfigFile"
    fi
}

# Create/Start/Restart comtainers
function restartAll {
    docker-compose up --detach --force-recreate --remove-orphans
}

# Restart the Element Web container
function restartElement {
    docker restart synapse-docker-elementweb-1
}

# Restart the Synapse container
function restartSynapse {
    docker restart synapse-docker-synapse-1
}

# Stop the environment
function stopEnvironment {
    docker-compose stop
}

checkRequiredPrograms
checkRequiredDirectories

case $1 in
    admin)      createAdminAccount      ;;
    delete)     deleteEnvironment       ;;
    gendock)    generateDockerCompose   ;;
    genele)     generateElementConfig   ;;
    gensyn)     generateSynapseConfig   ;;
    restartall) restartAll              ;;
    restartele) restartElement          ;;
    restartsyn) restartSynapse          ;;
    setup)
        generateDockerCompose
        generateElementConfig
        generateSynapseConfig
        restartAll
        ;;
    stop)       stopEnvironment         ;;
    *)          help                    ;;
esac
