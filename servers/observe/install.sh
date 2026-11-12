#!/bin/bash

bold=$(tput bold)
normal=$(tput sgr0)

# A stale copy of this script would miss files added since it was downloaded, so refuse to
# run unless it matches the one on main. $(...) strips trailing newlines on both sides.
# Everything the installer downloads lives in one place in lucuma-deploy.
BASE_URL=https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/servers/observe

INSTALL_URL=$BASE_URL/install.sh
if LATEST_INSTALL=$(curl -sSf "$INSTALL_URL"); then
    if [ "$LATEST_INSTALL" != "$(cat "${BASH_SOURCE[0]}")" ]; then
        echo "This install.sh is out of date. Download the current one and run it instead:"
        echo
        echo "    curl $INSTALL_URL >install.sh"
        echo "    chmod +x install.sh"
        echo "    ./install.sh"
        exit 1
    fi
else
    echo "WARNING: Could not check whether install.sh is up to date. Continuing with this copy."
fi

mkdir ~/observe
cd ~/observe
curl $BASE_URL/config.sh.template >config.sh.template
curl $BASE_URL/start.sh >start.sh
curl $BASE_URL/stop.sh >stop.sh
curl $BASE_URL/restart.sh >restart.sh
curl $BASE_URL/update.sh >update.sh
curl $BASE_URL/observe.sh >observe.sh
chmod +x *.sh
mkdir ~/observe/conf
mkdir ~/observe/log

# Creating symbolic link to run observe as a command
echo "Creating symbolic link to run observe as a command"
mkdir -p ~/bin
ln -s ~/observe/observe.sh ~/bin/observe
echo "Observe command installed"
echo "For more information run"
echo "  >> ${bold}observe help${normal}"