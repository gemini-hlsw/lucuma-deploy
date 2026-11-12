# AWS: deploying a static site from the build archive to an S3 bucket and invalidating the
# CloudFront cache of the target. Credentials come from the environment (AWS_PROFILE or the
# default profile).
#
# The CI archives every build at s3://<archive bucket>/builds/<git sha>/ (see aws_archive_bucket in
# systems.sh), so a promotion or a rollback copies that archive onto the target bucket instead of
# one environment's bucket onto another.

# The archive URL of a build: s3://<archive bucket>/builds/<sha>
aws_archive_url() {
  local system=$1
  local sha=$2
  echo "s3://${aws_archive_bucket["$system"]}/builds/$sha"
}

# Succeeds when the archive holds an index.html, i.e. the build is archived. stderr is kept so a
# credentials or network error is not mistaken for a missing build.
aws_archive_exists() {
  aws s3 ls "$1/index.html" > /dev/null
}

# Copy an archived build onto the latest/ prefix of a bucket, server side: the CloudFront
# distributions use origin path /latest. The copy uses `cp`, not `sync`: sync skips files of the
# same size when the source is older, which is the case whenever an earlier build is deployed (a
# rollback, or a promotion whose archive predates the target's last write), and would keep the
# newer index.html and sw.js. The assets go first so a user who loads the new index.html mid-copy
# still finds its bundles; then everything else; then one sync --delete removes the stale files,
# only once the new build is complete. Since the target is a prefix, --delete never reaches builds/
# in the archive bucket. --copy-props metadata-directive keeps the object metadata (Cache-Control,
# Content-Type) of the archive. With "dryrun" as the fourth argument nothing is copied, the commands
# only list what they would do (without --only-show-errors, which would hide the listing).
aws_deploy_build() {
  local archive=$1
  local target_bucket=$2
  local label=$3
  local mode=${4:-}
  local -a extra=(--only-show-errors)
  if [ "$mode" = dryrun ]; then
    extra=(--dryrun)
  fi
  local target="s3://$target_bucket/latest"
  if aws s3 cp "$archive/assets" "$target/assets" --recursive \
    --copy-props metadata-directive "${extra[@]}" \
    && aws s3 cp "$archive" "$target" --recursive --exclude "assets/*" \
      --copy-props metadata-directive "${extra[@]}" \
    && aws s3 sync "$archive" "$target" --delete \
      --copy-props metadata-directive "${extra[@]}"; then
    echo "  ✓ $label copied from $archive to $target"
  else
    echo "  ! $label ... FAILED"
    exit 1
  fi
}

# Invalidate every path of a CloudFront distribution and print the invalidation id.
aws_invalidate() {
  local distribution=$1
  local label=$2
  local id
  if id=$(aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" \
    --query Invalidation.Id --output text); then
    echo "  ✓ $label invalidation $id created on $distribution"
  else
    echo "  ! $label ... FAILED"
    exit 1
  fi
}
