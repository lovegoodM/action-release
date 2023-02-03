#!/bin/sh -l

set -e

printf '%d args: "%s"\n' "$#" "$@"
echo "RUNNER_WORKSPACE: $RUNNER_WORKSPACE"
echo "GITHUB_WORKSPACE: $GITHUB_WORKSPACE"

#
# Input verification
#
TOKEN="${INPUT_TOKEN}"
if [ -z "${TOKEN}" ]; then
  >&2 printf "\nERR: Invalid input: 'token' is required, and must be specified.\n"
  >&2 printf "\tNote: It's necessary to interact with Github's API.\n\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  token: \${{ secrets.GITHUB_TOKEN }}\n"
  >&2 printf "\t  ...\n"
  exit 1
fi

# Try getting $TAG from action input
TAG="${INPUT_TAG}"

# [fallback] Try getting $TAG from ENVironment VARiable
#   NOTE: Can be set in a step before using ex:
#     echo ::set-env name=RELEASE_TAG::"v1.0.0"
if [ -z "${TAG}" ]; then
  TAG="${RELEASE_TAG}"
fi

# [fallback] Try getting $TAG from Github context (only works on git-tag push action)
if [ -z "${TAG}" ]; then
  TAG="$(echo "${GITHUB_REF}" | grep 'refs/tags/' | awk -F/ '{print $NF}')"
fi

# If all ways of getting the TAG failed, exit with an error
if [ -z "${TAG}" ]; then
  >&2 printf "\nERR: Invalid input: 'tag' is required, and must be specified.\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  tag: v0.0.1\n"
  >&2 printf "\t  ...\n\n"
  >&2 printf "Note: To use dynamic TAG, set RELEASE_TAG env var in a prior step, ex:\n"
  >&2 printf '\techo ::set-env name=RELEASE_TAG::"v1.0.0"\n\n'
  exit 1
fi

# Verify that gzip: option is set to any of the allowed values
if [ "${INPUT_GZIP}" != "true" ] && [ "${INPUT_GZIP}" != "false" ] && [ "${INPUT_GZIP}" != "folders" ]; then
  >&2 printf "\nERR: Invalid input: 'gzip' can only be not set, or one of: true, false, folders\n"
  >&2 printf "\tNote: It defines what to do with assets before uploading them.\n\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  gzip: true\n"
  >&2 printf "\t  ...\n"
  exit 1
fi

BASE_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"

#
## Check for Github Release existence
#
RELEASE_ID="$(curl -sS -H "Authorization: Bearer ${TOKEN}"  "${BASE_URL}" | jq -r --arg TAG ${TAG} '.[] | select(.tag_name == $TAG) | .id')"

if [ -n "${RELEASE_ID}" ] && [ "${INPUT_ALLOW_OVERRIDE}" != "true" ] && [ "${INPUT_ALLOW_DEL}" != "true" ]; then
  >&2 printf "\nERR: Release '%s' already exists, and overriding is not allowed.\n" "${TAG}"
  >&2 printf "\tNote: Either use different 'tag:' name, or 'allow_override:'\n\n"
  >&2 printf "Try:\n"
  >&2 printf "\tuses: meeDamian/github-release@TAG\n"
  >&2 printf "\twith:\n"
  >&2 printf "\t  ...\n"
  >&2 printf "\t  allow_override: true\n"
  exit 1
fi
[ -n "${RELEASE_ID}" ] && printf "\nRELEASE_ID: %d\n" "$RELEASE_ID"

# If no `name:` passed as input, but RELEASE_NAME env var is set, use it as the name
if [ -z "${INPUT_NAME}" ] && [ -n "${RELEASE_NAME}" ]; then
  INPUT_NAME="${RELEASE_NAME}"
else
  INPUT_NAME="${TAG}"
fi

#
## Create, or update release on Github
#
# For a given string return either `null` (if empty), or `"quoted string"` (if not)
toJsonOrNull() {
  if [ -z "$1" ]; then
    echo null
    return
  fi

  if [ "$1" = "true" ] || [ "$1" = "false" ]; then
    echo "$1"
    return
  fi

  echo "\"$1\""
}

METHOD="POST"
URL="${BASE_URL}"
if [ -n "${RELEASE_ID}" ] && [ "${INPUT_ALLOW_DEL}" = "true" ]; then
  CODE="$(curl -sS -X DELETE --write-out "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/${RELEASE_ID}")"
  [ "${CODE}" -eq "204" ] && printf "Delete %s to Github release asset has success\n" ${TAG}
  INPUT_ALLOW_DEL='yes'
elif [ -n "${RELEASE_ID}" ] && [ "${INPUT_ALLOW_OVERRIDE}" = "true" ]; then
  METHOD="PATCH"
  URL="${URL}/${RELEASE_ID}"
fi

# Creating the object in a PATCH-friendly way
CODE="$(jq -nc \
  --arg tag_name              "${TAG}" \
  --argjson target_commitish  "$(toJsonOrNull "${INPUT_COMMITISH}")"  \
  --argjson name              "$(toJsonOrNull "${INPUT_NAME}")"       \
  --argjson body              "$(toJsonOrNull "${INPUT_BODY}")"       \
  --argjson draft             "$(toJsonOrNull "${INPUT_DRAFT}")"      \
  --argjson prerelease        "$(toJsonOrNull "${INPUT_PRERELEASE}")" \
  '{$tag_name, $target_commitish, $name, $body, $draft, $prerelease} | del(.[] | nulls)' | \
  curl -sS -X "${METHOD}" -d @- \
  --write-out "%{http_code}" -o "/tmp/${METHOD}.json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json" \
  "${URL}")"

if [ "${CODE}" != "200" ] && [ "${CODE}" != "201" ]; then
  >&2 printf "\nERR: %s to Github release has failed\n" "${METHOD}"
  >&2 jq < "/tmp/${METHOD}.json"
  exit 1
fi

RELEASE_ID="$(jq '.id' < "/tmp/${METHOD}.json")"

#
## Handle, and prepare assets
#
# If no `files:` passed as input, but `RELEASE_FILES` env var is set, use it instead
if [ -z "${INPUT_FILES}" ] && [ -n "${RELEASE_FILES}" ]; then
  INPUT_FILES="${RELEASE_FILES}"
fi

if [ -z "${INPUT_FILES}" ]; then
  >&2 echo "No assets to upload. All done."
  exit 0
fi

ASSETS="${HOME}/assets"

mkdir -p "${ASSETS}/"

# this loop splits files by the space
for entry in $(echo "${INPUT_FILES}" | tr ' ' '\n'); do

  # Well, that needs explaining…  If delimiter given in `-d` does not occur in string, `cut` always returns
  #   the original string, no matter what the field `-f` specifies.
  #
  # I'm prepanding `:` to `${entry}` in `echo` to ensure match happens, because once it does, `-f` is respected,
  #   and I can easily check fields, and that way:
  #   * `-f 2` always contains the name of the asset
  #   * `-f 3` is either the custom name of the asset,
  #   * `-f 3` is empty, and needs to be set to `-f 2`
  entry="$(echo $entry | tr -d \")"
  ASSET_NAME="$(echo ":${entry}" | cut -d: -f2)"
  ASSET_PATH="$(echo ":${entry}" | cut -d: -f3)"

  if [ -z "${ASSET_PATH}" ]; then
    ASSET_NAME="$(basename "${entry}")"
    ASSET_PATH="${entry}"
  fi

  if [ -n "$(echo "$ASSET_PATH" | grep -e "^${RUNNER_WORKSPACE}/$(basename $RUNNER_WORKSPACE)/")" ]; then
    printf "del GITHUB_WORKSPACE path: %s " "$ASSET_PATH"
    ASSET_PATH=$(echo "$ASSET_PATH" | sed "s#^${RUNNER_WORKSPACE}/$(basename $RUNNER_WORKSPACE)/##g")
    printf "%s\n" "$ASSET_PATH"
  fi

  # this loop, expands possible globs
  for file in ${ASSET_PATH}; do
    # Error out on the only illegal combination: compression disabled, and folder provided
    if [ "${INPUT_GZIP}" != "true" ] && [ -d "${file}" ]; then
        >&2 printf "\nERR: Invalid configuration: 'gzip' cannot be set to 'false' while there are 'folders/' provided.\n"
        >&2 printf "\tNote: Either set 'gzip: folders', or remove directories from the 'files:' list.\n\n"
        >&2 printf "Try:\n"
        >&2 printf "\tuses: meeDamian/github-release@TAG\n"
        >&2 printf "\twith:\n"
        >&2 printf "\t  ...\n"
        >&2 printf "\t  gzip: folders\n"
        >&2 printf "\t  files: >\n"
        >&2 printf "\t    README.md\n"
        >&2 printf "\t    my-artifacts/\n"
        exit 1
    fi

    # Just copy files, if compression not enabled for all
    if [ "${INPUT_GZIP}" != "true" ] && [ -f "${file}" ]; then
      cp "${file}" "${ASSETS}/${ASSET_NAME}"
      continue
    fi

    # In any other case compress
    tar -cf "${ASSETS}/${ASSET_NAME}.tgz" "${file}"
    echo ${file}
  done
done

# At this point all assets to-be-uploaded (if any), are in `${ASSETS}/` folder
if [ "${INPUT_ALLOW_DEL}" = "yes" ]; then
  ASSET_ID=''
else
  ASSET_ID="$(jq '.assets[].id' < "/tmp/${METHOD}.json")"
fi
if [ -n "${ASSET_ID}" ]; then
  echo "==================================="
  printf "Delete existing assets: %s\n" "$(jq '.assets[].name' < "/tmp/${METHOD}.json" | tr "\n" " ")"
  for asset in ${ASSET_ID}; do
    CODE="$(curl -sS -X DELETE \
    --write-out "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/assets/${asset}")"
    if [ "${CODE}" -eq "204" ]; then
      printf "Delete %s to Github release asset has success\n" ${asset}
    fi
  done
  echo "==================================="
fi


echo "Files to be uploaded to Github:"
ls "${ASSETS}/"

UPLOAD_URL="$(echo "${BASE_URL}" | sed -e 's/api/uploads/')"
for asset in "${ASSETS}"/*; do
  FILE_NAME="$(basename "${asset}")"

  [ "$(stat -c %s "${asset}")" -le "0" ] && echo '# flush' >> ${asset}
  CODE="$(curl -sS  -X POST \
    --write-out "%{http_code}" -o "/tmp/${FILE_NAME}.json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Length: $(stat -c %s "${asset}")" \
    -H "Content-Type: $(file -b --mime-type "${asset}")" \
    --upload-file "${asset}" \
    "${UPLOAD_URL}/${RELEASE_ID}/assets?name=${FILE_NAME}")"

  if [ "${CODE}" -ne "201" ]; then
    >&2 printf "\nERR: Uploading %s to Github release has failed\n" "${FILE_NAME}"
    jq < "/tmp/${FILE_NAME}.json"
    exit 1
  fi
done

>&2 echo "All done."
