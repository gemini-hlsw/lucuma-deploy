# The table of systems: which repo each one is built from, how it is deployed and where its GitHub
# deployment records live. Everything else looks systems up here instead of hardcoding names.

# Bundle order. Promotion runs Heroku, manual, Hasura and Firebase in that order regardless.
all_systems=("Sso" "Itc" "Odb" "Resource" "Explore" "ResourceUi" "AdminUi" "Observe" "Navigate")
docker_systems=("Sso" "Itc" "Odb" "Resource")
firebase_systems=("ResourceUi" "AdminUi")
manual_systems=("Observe" "Navigate")
# Systems deployed to S3 + CloudFront. Explore is hosted there only; it is not on Firebase.
aws_systems=("Explore")

# Databases recorded in a bundle. The Flyway ones are read from the lucuma-odb tree of the system
# that runs the migrations; user_prefs comes from the Hasura migrations in lucuma-apps.
databases=("odb" "sso" "resource" "user_prefs")
flyway_databases=("odb" "sso" "resource")

DEPLOY_REPO="gemini-hlsw/lucuma-deploy"
LUCUMA_APPS_URL="https://github.com/gemini-hlsw/lucuma-apps"

declare -A repo
declare -A image_name
declare -A process_types
declare -A backup
declare -A github_task
declare -A github_env_prefix
declare -A github_env
declare -A manual_command
declare -A firebase_site
declare -A firebase_project
# The CI archives every build at s3://<archive bucket>/builds/<sha>/, always in the dev bucket,
# whatever the environment it is deployed to. Promotions and rollbacks copy from there.
declare -A aws_archive_bucket
declare -A aws_bucket
declare -A aws_distribution
declare -A flyway_system
declare -A flyway_prefix

repo["Sso"]="gemini-hlsw/lucuma-odb"
github_task["Sso"]="deploy:SSO"
image_name["Sso"]="lucuma-sso"
process_types["Sso"]="web"
backup["Sso"]=true

repo["Itc"]="gemini-hlsw/lucuma-odb"
github_task["Itc"]="deploy:ITC"
image_name["Itc"]="itc"
process_types["Itc"]="web"
backup["Itc"]=false

repo["Odb"]="gemini-hlsw/lucuma-odb"
github_task["Odb"]="deploy:ODB"
image_name["Odb"]="lucuma-postgres-odb"
process_types["Odb"]="web calibration obscalc pdfsummary"
backup["Odb"]=true

repo["Resource"]="gemini-hlsw/lucuma-odb"
github_task["Resource"]="deploy:RESOURCE"
image_name["Resource"]="lucuma-resource"
process_types["Resource"]="web"
backup["Resource"]=false

repo["Explore"]="gemini-hlsw/lucuma-apps"
backup["Explore"]=false
aws_archive_bucket["Explore"]="gemini-edu-explore-dev"
aws_bucket["Explore-dev"]="gemini-edu-explore-dev"
aws_bucket["Explore-staging"]="gemini-edu-explore-test"
aws_bucket["Explore-production"]="gemini-edu-explore-prd"
aws_distribution["Explore-dev"]="E3DZG7GNUB60T6"
aws_distribution["Explore-staging"]="E2E5A5UYD8VLF7"
aws_distribution["Explore-production"]="E1VDJ0RPRW1PVL"

repo["ResourceUi"]="gemini-hlsw/lucuma-ts"
github_env_prefix["ResourceUi"]="resource-ui"
github_task["ResourceUi"]="deploy"
backup["ResourceUi"]=false
firebase_project["ResourceUi"]="resource-ae0b7"
firebase_site["ResourceUi-dev"]="resource-ae0b7-dev"
firebase_site["ResourceUi-staging"]="resource-ae0b7-staging"
firebase_site["ResourceUi-production"]="resource-ae0b7"

repo["AdminUi"]="gemini-hlsw/lucuma-ts"
github_env_prefix["AdminUi"]="admin-ui"
github_task["AdminUi"]="deploy"
backup["AdminUi"]=false
firebase_project["AdminUi"]="admin-679f7"
firebase_site["AdminUi-dev"]="admin-679f7-dev"
firebase_site["AdminUi-staging"]="admin-679f7-staging"
firebase_site["AdminUi-production"]="admin-679f7"

repo["Observe"]="gemini-hlsw/lucuma-apps"
backup["Observe"]=false
manual_command["Observe"]="observe update"

repo["Navigate"]="gemini-hlsw/lucuma-ts"
github_task["Navigate"]="deploy"
github_env["Navigate-dev"]="navigate-dev-gn"
github_env["Navigate-staging"]="navigate-staging"
github_env["Navigate-production"]="navigate-production"
backup["Navigate"]=false
manual_command["Navigate"]="navigate update"

flyway_system["odb"]="Odb"
flyway_prefix["odb"]="modules/service/src/main/"
flyway_system["sso"]="Sso"
flyway_prefix["sso"]="modules/sso-service/src/main/"
flyway_system["resource"]="Resource"
flyway_prefix["resource"]="resource/service/src/main/"

is_docker_system() {
  [[ " ${docker_systems[*]} " =~ [[:space:]]${1}[[:space:]] ]]
}

is_firebase_system() {
  [[ " ${firebase_systems[*]} " =~ [[:space:]]${1}[[:space:]] ]]
}

is_aws_system() {
  [[ " ${aws_systems[*]} " =~ [[:space:]]${1}[[:space:]] ]]
}

is_manual_system() {
  [[ " ${manual_systems[*]} " =~ [[:space:]]${1}[[:space:]] ]]
}

map_github_deploy_env() {
  case $1 in
    "dev") echo "development" ;;
    "staging") echo "staging" ;;
    "production") echo "production" ;;
    *) echo "$1" ;;
  esac
}

# Resolve the GitHub deployment environment for a system. Most systems use the shared
# map_github_deploy_env mapping, but systems with a github_env_prefix (e.g. ResourceUi ->
# resource-ui-dev) build the environment from that prefix, and systems with an explicit github_env
# entry (e.g. Navigate-dev) use it verbatim.
get_github_deploy_env() {
  local system=$1
  local env=$2
  if [ -n "${github_env["${system}-${env}"]:-}" ]; then
    echo "${github_env["${system}-${env}"]}"
  elif [ -n "${github_env_prefix["$system"]:-}" ]; then
    echo "${github_env_prefix["$system"]}-${env}"
  else
    map_github_deploy_env "$env"
  fi
}

# Resolve the GitHub deployment task for a system, defaulting to deploy:<system>.
get_github_task() {
  echo "${github_task["$1"]:-deploy:${1}}"
}

get_firebase_site() {
  echo "${firebase_site["${1}-${2}"]:-}"
}

get_aws_bucket() {
  echo "${aws_bucket["${1}-${2}"]:-}"
}

get_aws_distribution() {
  echo "${aws_distribution["${1}-${2}"]:-}"
}

get_heroku_app() {
  echo "${image_name["$1"]}-${2}"
}

# The command the operator must run by hand on the servers of a manual system. It takes no tag:
# the servers deploy the one in the environment's current bundle.
get_manual_command() {
  echo "${manual_command["$1"]}"
}
