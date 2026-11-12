# Slack notifications. Messages are written with literal \n separators, which become newlines once
# the JSON payload is decoded by Slack. The promotion messages read the per-system arrays of
# promote.sh (source_sha, target_sha, docker_tag, backup).

slack_channel() {
  echo "${GPP_SLACK_CHANNEL:-"#gpp"}"
}

# Print a message the way it would be sent, one indented line per \n.
slack_print_message() {
  echo "  Slack notification to $(slack_channel):"
  printf '%s\n' "$1" | awk '{ gsub(/\\n/, "\n    "); print "    " $0 }'
  echo
}

# Post a message, honouring --skip-slack and a missing or malformed webhook. A Slack failure never
# stops a deployment.
slack_send_text() {
  local message=$1

  if [ "$SKIP_SLACK" = true ]; then
    echo "  ! Slack notifications disabled with --skip-slack flag"
    slack_print_message "$message"
    return 0
  fi

  if [ -z "${GPP_SLACK_WEBHOOK_URL:-}" ]; then
    echo "  ! GPP_SLACK_WEBHOOK_URL not set - skipping Slack notification"
    return 0
  fi

  # Basic URL validation for Slack webhook
  if [[ ! "$GPP_SLACK_WEBHOOK_URL" =~ ^https://hooks\.slack\.com/services/ ]]; then
    echo "  ! Invalid Slack webhook URL format - skipping notification"
    return 0
  fi

  local payload="{\"text\":\"$message\"}"

  if curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$GPP_SLACK_WEBHOOK_URL" > /dev/null; then
    echo "  Slack notification sent successfully"
  else
    echo "  ! Failed to send Slack notification (deployment continues)"
  fi
}

get_git_compare_link() {
  local service=$1

  local github_repo=${repo["$service"]}
  local src=${source_sha["$service"]}
  local tgt=${target_sha["$service"]}

  # Create appropriate GitHub link based on available commit info
  if [ "$tgt" != "none" ]; then
    if [ "$src" != "$tgt" ]; then
      echo "https://github.com/$github_repo/compare/${tgt}...${src}"
    else
      echo "" # Skip meaningless comparison when SHAs are identical
    fi
  else
    echo "https://github.com/$github_repo/commit/${src}"
  fi
}

get_manual_command_note() {
  echo "(deploys ${docker_tag["$1"]})"
}

show_slack_message() {
  local service=$1
  local source_env=$2
  local target_env=$3
  local backup_id=${4:-""}

  local compare_link
  compare_link=$(get_git_compare_link "$service")
  local timestamp
  timestamp=$(utc_timestamp)

  echo "  Slack notification to $(slack_channel):"
  if is_manual_system "$service"; then
    echo "    ⚠️ $service promoted from $source_env → $target_env — manual step required"
  else
    echo "    $service deployed from $source_env → $target_env"
  fi

  if [ -n "$compare_link" ]; then
    echo "    Changes: $compare_link"
  fi

  if is_manual_system "$service"; then
    echo "    Run on the GN and GS $target_env $service servers $(get_manual_command_note "$service"):"
    echo "    \`\`\`$(get_manual_command "$service")\`\`\`"
  fi

  # Include backup ID for the systems that take one
  if [ "${backup["$service"]}" = true ] && [ -n "$backup_id" ] && [ "$backup_id" != "unknown" ]; then
    echo "    Database backup: $backup_id"
  fi

  echo "    Time: $timestamp"
  echo
}

send_slack_notification() {
  local service=$1
  local source_env=$2
  local target_env=$3
  local backup_id=${4:-""}

  if [ "$SKIP_SLACK" = true ]; then
    echo "  ! Slack notifications disabled with --skip-slack flag"
    show_slack_message "$service" "$source_env" "$target_env" "$backup_id"
    return 0
  fi

  local compare_link
  compare_link=$(get_git_compare_link "$service")
  local timestamp
  timestamp=$(utc_timestamp)

  local message="✅ $service deployed from $source_env → $target_env\nTime: $timestamp"

  # Include changes link for Sso, Odb and the UIs
  if [ "$service" = "Sso" ] || [ "$service" = "Odb" ] || [ "$service" = "Explore" ] || [ "$service" = "ResourceUi" ] || [ "$service" = "AdminUi" ]; then
    if [ -n "$compare_link" ]; then
      message="✅ $service deployed from $source_env → $target_env\nChanges: $compare_link"
    else
      message="✅ $service deployed from $source_env → $target_env"
    fi

    # Include backup ID for Odb only
    if [ "$service" = "Odb" ] && [ -n "$backup_id" ] && [ "$backup_id" != "unknown" ]; then
      message="$message\nDatabase backup: $backup_id"
    fi

    message="$message\nTime: $timestamp"
  fi

  if is_manual_system "$service"; then
    message="⚠️ $service promoted from $source_env → $target_env — manual step required"
    if [ -n "$compare_link" ]; then
      message="$message\nChanges: $compare_link"
    fi
    message="$message\nRun on the GN and GS $target_env $service servers $(get_manual_command_note "$service"):"
    message="$message\n\`\`\`$(get_manual_command "$service")\`\`\`"
    message="$message\nTime: $timestamp"
  fi

  slack_send_text "$message"
}

# Rollback message of one system, with the command block for the manual ones.
send_rollback_slack_notification() {
  local service=$1
  local env=$2
  local sha=$3
  local bundle_id=$4
  local tag=${5:-}

  local message="⏪ $service rolled back in $env to ${sha:0:7} (bundle $bundle_id)"
  if is_manual_system "$service"; then
    message="$message\nRun on the GN and GS $env $service servers (deploys $tag):"
    message="$message\n\`\`\`$(get_manual_command "$service")\`\`\`"
  fi
  message="$message\nTime: $(utc_timestamp)"

  slack_send_text "$message"
}

bundle_slack_message() {
  local env=$1
  local id=$2
  echo "📦 $env bundle $id written: https://github.com/$DEPLOY_REPO/blob/main/bundles/$env/$id.json"
}
