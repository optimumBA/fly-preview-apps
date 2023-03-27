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
app="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_NAME}"
app_db="$app-db"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true

  # destroy postgres db as well
  if flyctl status --app "$app_db"; then
    flyctl apps destroy "$app_db" -y || true
  fi
  # destroy created volumes
  # flyctl volumes destroy <id> -y || true
  exit 0
fi

# Check if app exists,
# if not, launch it, but don't deploy yet
if ! flyctl status --app "$app"; then
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"

  echo "|> creating app ====>>"
  flyctl launch --no-deploy --copy-config --name "$app" --region "$region" --org "$org"
  echo "|> app created successfully ====>>"

  sleep 2

  # Restore the original config file
  cp "$config.bak" "$config"
fi

# look for "migrate" file in the app files
# if it exists, the app probably needs DB.
if [ -e "rel/overlays/bin/migrate" ]; then
  # only create db if the app lauched successfully
  if flyctl status --app "$app"; then
    if flyctl status --app "$app_db"; then
      echo "$app_db already exists"
    else
      echo "|> creating DB ====>>"
      flyctl postgres create --name "$app_db" --org "$org" --region "$region" --vm-size shared-cpu-1x --initial-cluster-size 1 --volume-size 10
      echo "|> DB created successfully ====>>"
    fi
    # attaching db to the app if it was created successfully
    echo "|> attaching DB ====>>"
    if $(flyctl postgres attach "$app_db" --app "$app" -y); then
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
# check if app name has dashes, and replace with underscore
# Fly.io does not accept dashes in volume names
# if [[ "$app" =~ "-" ]]; then
#   volume=${app//-/_}
# fi

if flyctl status --app "$app"; then
  while IFS= read -r line; do
    if [[ $line == "[mounts]" ]]; then
      echo "|> creating volume ====>>"
      fly volumes create temporary_volume --app "$app" --region "$region" --size 1
      echo "|> volume created successfully ====>>"
    fi
  done <"$config"
fi

# Deploy the app.
echo "|> deploying app ====>>"
flyctl deploy --config "$config" --app "$app" --region "$region" --strategy immediate
echo "|> app deployed successfuly ====>>"

# set neccessary secrets
echo "|> setting secrets ====>>"
fly secrets set PHX_HOST="$app".fly.dev --app "$app"
echo "|> secrets set successfully ====>>"

# import any environment secrets that may be required
# if [ -n "$INPUT_SECRETS" ]; then
#   echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
# fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >>$GITHUB_OUTPUT
echo "url=https://$hostname" >>$GITHUB_OUTPUT
echo "id=$appid" >>$GITHUB_OUTPUT
echo "name=$app" >>$GITHUB_OUTPUT
