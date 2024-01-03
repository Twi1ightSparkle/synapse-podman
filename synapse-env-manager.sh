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

# Load config
if [ ! -f "$configFile" ]; then
    echo "Unable to load config file $configFile"
    exit 1
fi
source "$configFile"

export synapsePortEnv="$synapsePort"

# Vars
serverName="localhost:$synapsePort"
synapseData="$workDir/synapse"
postgresData="$workDir/postgres"
elementConfigFile="$workDir/elementConfig.json"
logConfigFile="$synapseData/localhost:$synapsePort.log.config"
synapseConfigFile="$synapseData/homeserver.yaml"
dockerComposeFile="$workDir/docker-compose.yaml"

# Check for required programs
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

# Create admin account
if [ "$1" == "admin" ]; then
    docker exec \
        synapse \
        /bin/bash \
        -c "register_new_matrix_user \
            --admin \
            --config /data/homeserver.yaml \
            --password admin \
            --user admin"
    exit 0
fi

# Delete the environment
if [ "$1" == "delete" ]; then
    read -rp "Enter YES to confirm detleting the environment and the data and postgres directories: " verification
    [[ "$verification" != "YES" ]] && exit 0
    docker-compose down --remove-orphans
    rm -rf "$elementConfigFile"
    rm -rf "$synapseData"
    rm -rf "$dockerComposeFile"
    rm -rf "$postgresData"
    exit 0
fi

# Stop the environment
if [ "$1" == "stop" ]; then
    docker-compose stop
    exit 0
fi

# Any invalid option
if [ "$1" != "setup" ]; then
    cat <<EOT
Usage: $scriptPath <option>

Options:
    admin: Create admin account (username: admin. password: admin)
    delete: Delete the environment
    setup: Create, edit, (re)start the environment
    stop: Stop the environment without deleting it
EOT
  exit 0
fi

# Check for required directories
[[ ! -d "$synapseData" ]] && mkdir "$synapseData"

# Generate Element Web config if not present
[[ ! -f "$elementConfigFile" ]] && cat <<EOT >> "$elementConfigFile"
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "http://$serverName",
            "server_name": "$serverName"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "disable_custom_urls": false,
    "disable_guests": false,
    "disable_login_language_selector": false,
    "disable_3pid_login": false,
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api",
        "https://scalar-staging.riot.im/scalar/api"
    ],
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "defaultCountryCode": "US",
    "showLabsSettings": true,
    "default_federate": true,
    "default_theme": "dark",
    "roomDirectory": {
        "servers": ["matrix.org"]
    },
    "enable_presence_by_hs_url": {
        "https://matrix.org": false,
        "https://matrix-client.matrix.org": false
    },
    "jitsi": {
        "preferredDomain": "meet.element.io"
    }
}
EOT

# Generate Synapse config if not present
[[ ! -f "$synapseConfigFile" ]] && \
    docker run \
        --entrypoint "/bin/bash" \
        --interactive \
        --rm \
        --tty \
        --volume "$synapseData":/data \
        "ghcr.io/matrix-org/synapse:$synapseVersion" \
        -c "python3 -m synapse.app.homeserver \
            --config-path /data/homeserver.yaml \
            --data-directory /data \
            --generate-config \
            --report-stats no \
            --server-name $serverName"

# Customize Synapse config
yq -i '.handlers.file.filename = "/data/homeserver.log"' "$logConfigFile"
yq -i '
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
yq -i 'del(.listeners[0].bind_addresses[0])' "$synapseConfigFile"

# Create docker-compose file
cat <<EOT > "$dockerComposeFile"
# Do NOT edit this file. It's managed by $scriptPath
version: "3"
services:
  synapse:
    image: ghcr.io/matrix-org/synapse:$synapseVersion
    restart: unless-stopped
    environment:
      - SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
    volumes:
      - $synapseData:/data
    depends_on:
      - postgres
    ports:
    #   - 127.0.0.1:8008-8009:8008-8009/tcp
    #   - 127.0.0.1:8008-8009:8008-8009/tcp
      - 127.0.0.1:$synapsePort:$synapsePort/tcp
    #   - 127.0.0.1:$synapsePort-8449:$synapsePort-8449/tcp
  postgres:
    image: docker.io/postgres:12-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=synapse
      - POSTGRES_PASSWORD=password
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
    volumes:
      - $postgresData:/var/lib/postgresql/data
    ports:
      - 127.0.0.1:$portgresPort:5432/tcp
EOT

[ "$enableAdminer" == true ] && cat <<EOT >> "$dockerComposeFile"
  adminer:
    image: docker.io/adminer:latest
    restart: unless-stopped
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
    ports:
      - 127.0.0.1:$adminerPort:8080/tcp
EOT

[ "$enableElementWeb" == true ] && cat <<EOT >> "$dockerComposeFile"
  elementweb:
    image: vectorim/element-web:$elementVersion
    restart: unless-stopped
    volumes:
      - $elementConfigFile:/app/config.json:ro
    ports:
      - 127.0.0.1:$elementPort:80/tcp
EOT

# Create/Start/Restart comtainers
docker-compose up --detach --force-recreate --remove-orphans
