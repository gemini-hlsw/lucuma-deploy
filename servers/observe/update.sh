#!/bin/bash

SCRIPTS_DIR=~/observe

# Where the lucuma-deploy files are fetched from. The override exists for tests only.
RAW_URL=${LUCUMA_DEPLOY_RAW_URL:-https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main}

usage() {
    echo "Usage: observe update [--force-version <tag>]"
    echo "  Without arguments, deploys the noirlab/gpp-obs tag of the current lucuma-deploy bundle"
    echo "  of this server's environment (staging or production, taken from SITE in config.sh)."
    echo "  --force-version <tag> deploys the given tag instead, after asking for confirmation."
}

FORCED_TAG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force-version)
            if [ -z "$2" ]; then
                usage
                exit 1
            fi
            FORCED_TAG="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unexpected argument [$1]"
            echo
            usage
            exit 1
            ;;
    esac
done

. $SCRIPTS_DIR/config.sh

case "$SITE" in
    staging-gn|staging-gs|production-gn|production-gs) ENVIRONMENT="${SITE%-*}" ;;
    *)
        echo "ERROR: Cannot determine the environment of this server from SITE [$SITE] in $SCRIPTS_DIR/config.sh."
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
    PROMOTED_TAG=$(echo "$TAGS" | sed -n 's/^observe=//p' | head -1 | tr -d '\r ')
    PROMOTED_BUNDLE=$(echo "$TAGS" | sed -n 's/^bundle=//p' | head -1 | tr -d '\r ')
fi

if [ -n "$FORCED_TAG" ]; then
    TAG="$FORCED_TAG"
    if [ "$TAG" != "$PROMOTED_TAG" ]; then
        echo "You shouldn't deploy a version other than the one last promoted on staging and production servers. This may break compatibility with other systems."
        echo
        if [ -n "$PROMOTED_TAG" ]; then
            echo "The version last promoted to $ENVIRONMENT (bundle $PROMOTED_BUNDLE) is $PROMOTED_TAG; 'observe update' deploys it."
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
        echo "  (the file is missing, or it has no observe= or bundle= line)"
        echo "Nothing was changed."
        exit 1
    fi
    TAG="$PROMOTED_TAG"
    BUNDLE="$PROMOTED_BUNDLE"
    echo "Version last promoted to $ENVIRONMENT (bundle $BUNDLE): $TAG"
    if [ "$TAG" = "$(cat $SCRIPTS_DIR/deployed-version 2>/dev/null)" ] && [ "$BUNDLE" = "$(cat $SCRIPTS_DIR/deployed-bundle 2>/dev/null)" ]; then
        echo "Already on $TAG (bundle $BUNDLE)"
        exit 0
    fi
fi

IMAGE=noirlab/gpp-obs:$TAG

echo "Logging into DockerHub..."
echo $DOCKERHUB_TOKEN | docker login -u $DOCKERHUB_USER --password-stdin

echo "Pulling image [$IMAGE]..."
if ! docker pull $IMAGE; then
    echo "ERROR: Could not pull image [$IMAGE]. Observe was not stopped."
    exit 1
fi

echo "$TAG" > $SCRIPTS_DIR/deployed-version
# A forced deploy is not on any bundle, so a stale id would be a lie.
if [ -n "$BUNDLE" ]; then
    echo "$BUNDLE" > $SCRIPTS_DIR/deployed-bundle
else
    rm -f $SCRIPTS_DIR/deployed-bundle
fi

$SCRIPTS_DIR/stop.sh
$SCRIPTS_DIR/start.sh
