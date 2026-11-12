#!/usr/bin/env bash

# Promote everything from staging to production. Extra arguments (e.g. --dry-run) are passed through.
exec "$(dirname "${BASH_SOURCE[0]}")/promote.sh" staging production "$@"
