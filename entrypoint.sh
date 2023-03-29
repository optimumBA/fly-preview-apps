#!/bin/sh -l

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
  # destroy app DB
  if flyctl status --app "$APP_DB"; then
    echo "|> destroying $APP_DB ====>>"
    flyctl apps destroy "$APP_DB" -y || true
    echo "|> $APP_DB destroyed successfully ====>>"
  fi

  # destroy associated volumes as well
  if flyctl volumes list --app "$APP"; then
    VOLUME_ID=$(flyctl volumes list --app "$APP" | grep -oh "\w*vol_\w*")
    echo "|> destroying $APP_DB volumes ====>>"
    flyctl apps destroy "$VOLUME_ID" -y || true
    echo "|> $APP_DB destroyed successfully ====>>"
  fi

  # finally, destroy the app
  if flyctl status --app "$APP"; then
    echo "|> destroying $APP ====>>"
    flyctl apps destroy "$APP" -y || true
    echo "|> $APP destroyed successfully====>>"
  fi
  exit 0
fi

# Backup the original config file since 'flyctl launch' messes up the [build.args] section
# also, sources value under mounts is modified, for apps that require volumes
cp "$CONFIG" "$CONFIG.bak"

# Check if app exists,
# if not, launch it, but don't deploy yet
if ! flyctl status --app "$APP"; then

  echo "|> creating $APP app ====>>"
  flyctl launch --no-deploy --copy-config --name "$APP" --region "$REGION" --org "$ORG"
  echo "|> $APP app created successfully ====>>"
fi

# look for "migrate" file in the app files
# if it exists, the app probably needs DB.
if [ -e "rel/overlays/bin/migrate" ]; then
  # only create db if the app lauched successfully
  if flyctl status --app "$APP"; then
    if flyctl status --app "$APP_DB"; then
      echo "$APP_DB DB already exists"
    else
      echo "|> creating $APP_DB DB ====>>"
      flyctl postgres create --name "$APP_DB" --org "$ORG" --region "$REGION" --vm-size shared-cpu-1x --initial-cluster-size 4 --volume-size 10
      echo "|> $APP_DB DB created successfully ====>>"
    fi
    # attaching db to the app if it was created successfully
    echo "|> attaching $APP_DB DB ====>>"
    if flyctl postgres attach "$APP_DB" --app "$APP" -y; then
      echo "|> $APP_DB DB attached ====>>"
    else
      echo "|> error attaching $APP_DB to $APP, attachments exist ====>>"
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
  # create volume only if none exists
  if ! flyctl volumes list --app "$APP" | grep -oh "\w*vol_\w*"; then
    echo "|> creating $VOLUME volume ====>>"
    flyctl volumes create "$VOLUME" --app "$APP" --region "$REGION" --size 10 -y
    echo "|> $VOLUME volume created successfully ====>>"

    # modify config file to have the volume name specified above.
    echo "|> updating config to contain new volume name ====>>"

    # modify config file to have the volume name specified above.
    sed -i -e 's/source =.*/source = '\"$VOLUME\"'/' "$CONFIG"
    echo "|> config modified to contain new volume name ====>>"
  fi
fi

# Deploy the app.
echo "|> deploying $APP app ====>>"
flyctl deploy --config "$CONFIG" --app "$APP" --region "$REGION" --strategy immediate
echo "|> $APP app deployed successfuly ====>>"

# set neccessary secrets
echo "|> setting secrets ====>>"
fly secrets set PHX_HOST="$APP".fly.dev --app "$APP"
echo "|> secrets set successfully ====>>"

# import any environment secrets that may be required
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$APP"
fi

# Restore the original config file
cp "$CONFIG.bak" "$CONFIG"

# Make some info available to the GitHub workflow.
flyctl status --app "$APP" --json >status.json
HOSTNAME=$(jq -r .Hostname status.json)
APPID=$(jq -r .ID status.json)
echo "hostname=$HOSTNAME" >>$GITHUB_OUTPUT
echo "url=https://$HOSTNAME" >>$GITHUB_OUTPUT
echo "id=$APPID" >>$GITHUB_OUTPUT
echo "name=$APP" >>$GITHUB_OUTPUT
