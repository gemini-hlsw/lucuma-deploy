#!/bin/bash

SCRIPTS_DIR=~/observe

# Check if an argument was received
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "ERROR: You must provide one of the following arguments: start, stop, restart, update [--force-version <tag>], version or help."
    exit 1
fi

bold=$(tput bold)
normal=$(tput sgr0)

# Get the argument
option="$1"

case "$option" in
    start)
        echo "Starting Observe"
        $SCRIPTS_DIR/start.sh
        ;;
    stop)
        echo "Stoping Observe"
        $SCRIPTS_DIR/stop.sh
        ;;
    restart)
        echo "Restarting Observe"
        $SCRIPTS_DIR/restart.sh
        ;;
    update)
        echo "Updating Observe"
        $SCRIPTS_DIR/update.sh "${@:2}" || exit 1
        ;;
    version)
        if [ ! -s $SCRIPTS_DIR/deployed-version ]; then
            echo "No deployed version"
            exit 1
        fi
        if [ -s $SCRIPTS_DIR/deployed-bundle ]; then
            echo "$(cat $SCRIPTS_DIR/deployed-version) (bundle $(cat $SCRIPTS_DIR/deployed-bundle))"
        else
            cat $SCRIPTS_DIR/deployed-version
        fi
        ;;
    help)
        echo "To run Observe you should provide a valid agument"
        echo "Possible argument options are 'start', 'stop', 'restart', 'update [--force-version <tag>]', 'version' and 'help'"
        echo -e "  ${bold}start${normal}: Will start Observe containers"
        echo -e "  ${bold}stop${normal}: Will stop Observe containers"
        echo -e "  ${bold}restart${normal}: Will restart Observe containers"
        echo -e "  ${bold}update${normal}: Will pull the noirlab/gpp-obs tag of the current lucuma-deploy bundle of this server's environment (from SITE in config.sh), record it in deployed-version and deployed-bundle, and recreate the Observe container with it. Does nothing when the server is already on that bundle"
        echo -e "  ${bold}update --force-version <tag>${normal}: Same, but with the given tag instead of the bundle's. Asks for confirmation; the server is no longer on a bundle afterwards"
        echo -e "  ${bold}version${normal}: Will show the currently deployed tag and, when there is one, its bundle id"
        echo -e "  ${bold}help${normal}: Will show this message"
        ;;
    *)
        echo "Error: Invalid argument, use 'help' command for instructions."
        exit 1
        ;;
esac