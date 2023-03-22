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
app_db="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_NAME}-db"
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
  flyctl apps destroy "$app_db" -y || true
  exit 0
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org"
  # set neccessary secrets
  fly secrets set PHX_HOST="$app".fly.dev --app "$app"
  # Restore the original config file
  cp "$config.bak" "$config"
fi

# find a way to create postgres for the app here👇
# basically, look for "migrate" file in the app files
# if it exists, the app probably needs DB.
if stat rel/overlays/bin/migrate; then
  flyctl postgres create --name "$app_db" --org "$org" --region "$region" --vm-size shared-cpu-1x --initial-cluster-size 1 --volume-size 10
  fly volumes create "$app" --app "$app" --region "$region"
fi

# check if the app needs volumes, then create them
# if [ grep -q \[mounts\] "$config" ]; then
#   fly volumes create "$app" --app "$app" --region "$region"
#   # 🎯 then, update the config, to have the newly created volume name
# fi

# Scale the VM before the deploy.
# this is probably not needed at the moment
# if [ -n "$INPUT_VM" ]; then
#   flyctl scale --app "$app" vm "$INPUT_VM"
# fi
# if [ -n "$INPUT_MEMORY" ]; then
#   flyctl scale --app "$app" memory "$INPUT_MEMORY"
# fi
# if [ -n "$INPUT_COUNT" ]; then
#   flyctl scale --app "$app" count "$INPUT_COUNT"
# fi

# import any environment secrets that may be required
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Attach postgres cluster to the app if specified.
if [ -n "$APP_NAME" ]; then
  flyctl postgres attach --app "$APP_NAME" || true
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
flyctl deploy --config "$config" --app "$app" --region "$region" --image "$image" --strategy immediate

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT