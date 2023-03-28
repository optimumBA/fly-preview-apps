#!/bin/bash

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_NAME=$(echo $GITHUB_REPOSITORY | tr "/" "-")
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_name}
APP="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_NAME}"
APP_DB="$APP-db"
REGION="${INPUT_REGION:-${FLY_REGION:-iad}}"
ORG="${INPUT_ORG:-${FLY_ORG:-personal}}"
IMAGE="$INPUT_IMAGE"
CONFIG="${INPUT_CONFIG:-fly.toml}"

if ! echo "$APP" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$APP" -y || true

  # destroy postgres db as well
  if flyctl status --app "$APP_DB"; then
    flyctl apps destroy "$APP_DB" -y || true
  fi
  # destroy created volumes
  # flyctl volumes destroy <id> -y || true
  exit 0
fi

# Backup the original config file since 'flyctl launch' messes up the [build.args] section
# also, sources value under mounts is modified, for apps that require volumes
cp "$config" "$config.bak"

# Check if app exists,
# if not, launch it, but don't deploy yet
if ! flyctl status --app "$APP"; then

  echo "|> creating $APP ====>>"
  flyctl launch --no-deploy --copy-config --name "$APP" --region "$REGION" --org "$ORG"
  echo "|> $APP created successfully ====>>"
fi

# look for "migrate" file in the app files
# if it exists, the app probably needs DB.
if [ -e "rel/overlays/bin/migrate" ]; then
  # only create db if the app lauched successfully
  if flyctl status --app "$APP"; then
    if flyctl status --app "$APP_DB"; then
      echo "$APP_DB already exists"
    else
      echo "|> creating $APP_DB DB ====>>"
      flyctl postgres create --name "$APP_DB" --org "$ORG" --region "$REGION" --vm-size shared-cpu-1x --initial-cluster-size 1 --volume-size 10
      echo "|> $APP_ID DB created successfully ====>>"
    fi
    # attaching db to the app if it was created successfully
    echo "|> attaching DB ====>>"
    if $(flyctl postgres attach "$APP_DB" --app "$APP" -y); then
      echo "|> DB attached ====>>"
    else
      echo "|> error attaching DB to app ====>>"
    fi
  fi
fi

# find a way to determine if the app requires volumes
# basically, scan the config file if it contains "[mounts]", then create a volume for it
# for now, we're just gonna create it anyway
#
# replace any dash with underscore in app name
# Fly.io does not accept dashes in volume names
VOLUME=$(echo $APP | tr '-' '_')

if grep -q "\[mounts\]" fly.toml; then
  echo "|> creating volume ====>>"
  fly volumes create $VOLUME --app "$APP" --region "$REGION" --size 10
  echo "|> volume created successfully ====>>"

  # modify config file to have the volume name specified above.
  echo "|> updating config to contain new volume name ====>>"

  # modify config file to have the volume name specified above.
  sed -i -e 's/source =.*/source = '\"$VOLUME\"'/' "$CONFIG"
  echo "|> config modified to contain new volume name ====>>"
fi

# Deploy the app.
echo "|> deploying app ====>>"
flyctl deploy --config "$CONFIG" --app "$APP" --region "$REGION" --strategy immediate
echo "|> app deployed successfuly ====>>"

# set neccessary secrets
echo "|> setting secrets ====>>"
fly secrets set PHX_HOST="$APP".fly.dev --app "$APP"
echo "|> secrets set successfully ====>>"

# Restore the original config file
cp "$config.bak" "$config"

# import any environment secrets that may be required
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$APP"
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$APP" --json >status.json
HOSTNAME=$(jq -r .Hostname status.json)
APPID=$(jq -r .ID status.json)
echo "hostname=$HOSTNAME" >>$GITHUB_OUTPUT
echo "url=https://$HOSTNAME" >>$GITHUB_OUTPUT
echo "id=$APPID" >>$GITHUB_OUTPUT
echo "name=$APP" >>$GITHUB_OUTPUT
