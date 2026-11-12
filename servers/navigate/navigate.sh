#!/bin/bash

NAVIGATE_DIR=~/navigate
VERSION_FILE="$NAVIGATE_DIR/deployed-version"
BUNDLE_FILE="$NAVIGATE_DIR/deployed-bundle"

# Where the lucuma-deploy files are fetched from. The override exists for tests only.
RAW_URL=${LUCUMA_DEPLOY_RAW_URL:-https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main}

# The deployed tag lives only in the state file written by 'update'
if [ -s "$VERSION_FILE" ]; then
    NAVIGATE_TAG=$(cat "$VERSION_FILE")
    export NAVIGATE_TAG
fi

compose() {
    docker compose -f "$NAVIGATE_DIR/docker-compose.yml" --env-file "$NAVIGATE_DIR/.env" "$@"
}

# Check if the right number of arguments was received
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "ERROR: You must provide one of the following arguments: start, stop, update [--force-version <tag>], version or help."
    exit 1
fi

bold=$(tput bold)
normal=$(tput sgr0)

# Get the argument
option="$1"

case "$option" in
    start)
        if [ -z "$NAVIGATE_TAG" ]; then
            echo "No deployed version found. Run 'navigate update' first."
            exit 1
        fi
        echo "Starting Navigate $NAVIGATE_TAG"
        compose up -d
        ;;
    stop)
        echo "Stoping Navigate"
        # Placeholder so compose can parse the file; 'down' doesn't use images
        export NAVIGATE_TAG=${NAVIGATE_TAG:-unset}
        compose down
        ;;
    update)
        update_usage() {
            echo "Usage: navigate update [--force-version <tag>]"
            echo "  Without arguments, deploys the lucuma-ts release tag of the current lucuma-deploy bundle of this server's"
            echo "  environment (staging or production, taken from SITE in .env)."
            echo "  --force-version <tag> deploys the given tag instead, after asking for confirmation."
        }
        FORCED_TAG=""
        if [ "$2" = "--force-version" ] && [ -n "$3" ]; then
            FORCED_TAG="$3"
        elif [ -n "$2" ]; then
            echo "ERROR: Unexpected arguments [${*:2}]"
            echo
            update_usage
            exit 1
        fi

        SITE=$(grep -E '^SITE=' "$NAVIGATE_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')
        case "$SITE" in
            staging-gn|staging-gs|production-gn|production-gs) ENVIRONMENT="${SITE%-*}" ;;
            *)
                echo "ERROR: Cannot determine the environment of this server from SITE [$SITE] in $NAVIGATE_DIR/.env."
                echo "  SITE must be one of staging-gn, staging-gs, production-gn or production-gs."
                exit 1
                ;;
        esac

        # The tag and bundle id lucuma-deploy's promote.sh recorded for this environment.
        # No jq on the servers, so the flat key=value lines of current.tags are parsed with sed.
        TAGS_URL="$RAW_URL/bundles/$ENVIRONMENT/current.tags"
        PROMOTED_TAG=""
        PROMOTED_BUNDLE=""
        if TAGS=$(curl -sSf "$TAGS_URL"); then
            PROMOTED_TAG=$(echo "$TAGS" | sed -n 's/^navigate=//p' | head -1 | tr -d '\r ')
            PROMOTED_BUNDLE=$(echo "$TAGS" | sed -n 's/^bundle=//p' | head -1 | tr -d '\r ')
        fi

        if [ -n "$FORCED_TAG" ]; then
            TAG="$FORCED_TAG"
            if [ "$TAG" != "$PROMOTED_TAG" ]; then
                echo "You shouldn't deploy a version other than the one last promoted on staging and production servers. This may break compatibility with other systems."
                echo
                if [ -n "$PROMOTED_TAG" ]; then
                    echo "The version last promoted to $ENVIRONMENT (bundle $PROMOTED_BUNDLE) is $PROMOTED_TAG; 'navigate update' deploys it."
                else
                    echo "Could not determine the version last promoted to $ENVIRONMENT."
                fi
                echo
                read -r -p "If you have a REALLY REALLY good reason to deploy $TAG, type 'yes' to continue: " ANSWER
                if [ "$ANSWER" != "yes" ]; then
                    echo "Aborted. Nothing was changed."
                    exit 1
                fi
            fi
            BUNDLE=""
        else
            if [ -z "$PROMOTED_TAG" ] || [ -z "$PROMOTED_BUNDLE" ]; then
                echo "ERROR: Could not determine the version last promoted to $ENVIRONMENT from"
                echo "  $TAGS_URL"
                echo "  (the file is missing, or it has no navigate= or bundle= line)"
                echo "Nothing was changed."
                exit 1
            fi
            TAG="$PROMOTED_TAG"
            BUNDLE="$PROMOTED_BUNDLE"
            echo "Version last promoted to $ENVIRONMENT (bundle $BUNDLE): $TAG"
            if [ "$TAG" = "$(cat "$VERSION_FILE" 2>/dev/null)" ] && [ "$BUNDLE" = "$(cat "$BUNDLE_FILE" 2>/dev/null)" ]; then
                echo "Already on $TAG (bundle $BUNDLE)"
                exit 0
            fi
        fi
        echo "Updating Navigate to $TAG"
        if ! docker pull "noirlab/gpp-nav:$TAG"; then
            echo "ERROR: Could not pull noirlab/gpp-nav:$TAG. Nothing was changed."
            exit 1
        fi
        if ! docker pull "noirlab/gpp-nav-configs:$TAG"; then
            echo "ERROR: Could not pull noirlab/gpp-nav-configs:$TAG. Nothing was changed."
            exit 1
        fi
        # Stop with the old tag (or placeholder if there was none)
        export NAVIGATE_TAG=${NAVIGATE_TAG:-unset}
        compose down
        echo "$TAG" > "$VERSION_FILE"
        # A forced deploy is not on any bundle, so a stale id would be a lie.
        if [ -n "$BUNDLE" ]; then
            echo "$BUNDLE" > "$BUNDLE_FILE"
        else
            rm -f "$BUNDLE_FILE"
        fi
        export NAVIGATE_TAG="$TAG"
        compose up -d
        ;;
    version)
        if [ -s "$VERSION_FILE" ]; then
            if [ -s "$BUNDLE_FILE" ]; then
                echo "$(cat "$VERSION_FILE") (bundle $(cat "$BUNDLE_FILE"))"
            else
                cat "$VERSION_FILE"
            fi
        else
            echo "No deployed version"
            exit 1
        fi
        ;;
    help)
        echo "To run Navigate you should provide a valid agument"
        echo "Possible argument options are 'start', 'stop', 'update [--force-version <tag>]', 'version' and 'help'"
        echo -e "  ${bold}start${normal}: Will start Navigate containers"
        echo -e "  ${bold}stop${normal}: Will stop Navigate containers"
        echo -e "  ${bold}update${normal}: Will pull the navigate images with the release tag of the current lucuma-deploy bundle of this server's environment (from SITE in .env), record it in deployed-version and deployed-bundle and recreate the containers. Does nothing when the server is already on that bundle"
        echo -e "  ${bold}update --force-version <tag>${normal}: Same, but with the given lucuma-ts release tag (e.g. v0.16.16) instead of the bundle's. Asks for confirmation; the server is no longer on a bundle afterwards"
        echo -e "  ${bold}version${normal}: Will show the currently deployed tag and, when there is one, its bundle id"
        echo -e "  ${bold}help${normal}: Will show this message"
        ;;
    *)
        echo "Error: Invalid argument, use 'help' command for instructions."
        exit 1
        ;;
esac
