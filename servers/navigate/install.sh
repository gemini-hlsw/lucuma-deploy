#!/bin/bash

bold=$(tput bold)
normal=$(tput sgr0)

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# A stale copy of this script would miss files added since it was downloaded, so refuse to
# run unless it matches the one on main. $(...) strips trailing newlines on both sides.
# Everything the installer downloads lives in one place in lucuma-deploy.
BASE_URL=https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/servers/navigate

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

mkdir -p ~/navigate
cd ~/navigate

echo "INSTALLING NAVIGATE"
echo 

# Download scripts
# download <file> <mode>
# docker-compose.yml and navigate.sh are kept read-only so they are not edited on the
# server (install overwrites them). Download to a temp file and move it over, since curl
# can't write to the read-only file directly.
download() {
  curl -fsSL "$BASE_URL/$1" >"$1.tmp" || { echo "ERROR: could not download $1"; rm -f "$1.tmp"; exit 1; }
  mv -f "$1.tmp" "$1"
  chmod "$2" "$1"
}

echo "Downloading scripts"
download docker-compose.yml 444
download navigate.sh 555
download template-env 644
echo

# Require the creation of an .env file using the template-env, unless it exists.
if [ -e .env ]; then
  echo "Keeping existing .env"
  echo
else
  echo "# IMPORTANT!!!!" > .env
  echo "# Please modify this file (.env) using the appropriate values and save the changes." >> .env
  echo "# This values will be used to start the navigate containers cluster." >> .env
  cat template-env >> .env

  # Try to open the file with vim, vi, nano, or emacs
  if command_exists vim; then
    vim .env
  elif command_exists vi; then
    vi .env
  elif command_exists nano; then
    nano .env
  elif command_exists emacs; then
    emacs .env
  else
    echo "No suitable editor found (vim, vi, nano, or emacs)."
    exit 1
  fi
fi

# Create configuration directory - request files
mkdir -p ~/navigate/conf
echo "Navigate configuration directory created in ~/navigate/conf"
echo "Please add the configuration files needed by navigate-server to run properly"
echo "  secrets.conf - To include needed tokens and TLS configuration"
echo "  site.jks - To configure TLS certificate"
echo 

# Creating symbolic link to run navigate as a command
echo "Creating symbolic link to run navigate as a command"
mkdir -p ~/bin
ln -sf ~/navigate/navigate.sh ~/bin/navigate
echo "Navigate command installed"
echo "For more information run"
echo "  >> ${bold}navigate help${normal}"