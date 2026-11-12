#!/usr/bin/env bash

# Promote everything from dev to staging. Extra arguments (e.g. --dry-run) are passed through.
exec "$(dirname "${BASH_SOURCE[0]}")/promote.sh" dev staging "$@"
