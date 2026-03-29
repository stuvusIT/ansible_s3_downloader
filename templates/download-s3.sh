#!/usr/bin/env bash

# Enforce strict execution context
set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
readonly PARENT_DATASET="{{ s3_parent_dataset }}"
readonly API_ENDPOINT="{{ s3_endpoint }}"
readonly TRANSFERS="${TRANSFERS:-8}"
readonly CHECKERS="${CHECKERS:-16}"

# Force rclone to run without any configuration file on disk
export RCLONE_CONFIG="/dev/null"

export RCLONE_CONFIG_REMOTE_TYPE=s3
export RCLONE_CONFIG_REMOTE_PROVIDER=Other
export RCLONE_CONFIG_REMOTE_ENDPOINT="{{ s3_endpoint }}"
export RCLONE_CONFIG_REMOTE_ENV_AUTH=true
export RCLONE_CONFIG_REMOTE_REGION="dummy-region"
export RCLONE_CONFIG_REMOTE_ROLE_ARN="arn:aws:iam:::role/GlobalReaderRole"
export RCLONE_CONFIG_REMOTE_ROLE_SESSION_NAME="download"
export AWS_ENDPOINT_URL_STS="{{ s3_endpoint }}"

export AWS_ACCESS_KEY_ID="{{ s3_aws_access_key_id }}"
export AWS_SECRET_ACCESS_KEY="{{ s3_aws_secret_key }}"
export AWS_DEFAULT_REGION="dummy-region"
export REMOTE="remote"

EXCLUDED_BUCKETS="{% for bucket in s3_excluded_buckets %}{{ bucket }}{% if not loop.last %},{% endif %}{% endfor %}"




# --- Logging ---
log_msg() {
    local level="$1"
    local msg="$2"
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [${level^^}] ${msg}" >&2
}

# --- Dependency Management ---
check_dependencies() {
    local missing_deps=0

    for cmd in curl jq zfs; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_msg "err" "Required command not found: ${cmd}"
            missing_deps=1
        fi
    done

    return "${missing_deps}"
}

# --- API Interaction ---
fetch_bucket_list() {
    local response

    # Execute API call. The -f flag ensures HTTP 4xx/5xx return a non-zero exit code.
    if ! response=$(curl -s -f -X GET --aws-sigv4 "aws:amz:default:s3" \
        -K <(echo "user=\"${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}\"") \
        "${API_ENDPOINT}/admin/bucket?format=json"); then
        log_msg "err" "Failed to fetch buckets from API."
        return 1
    fi

    # Parse JSON. The -e flag ensures jq returns an error if the result is null/empty.
    if ! jq -e -r '.[]' <<< "${response}"; then
        log_msg "err" "Failed to parse JSON response or bucket list is empty."
        return 1
    fi

    return 0
}

# --- ZFS Management ---
ensure_parent_dataset() {
    if ! zfs list -H -o name "${PARENT_DATASET}" >/dev/null 2>&1; then
        log_msg "info" "Creating parent dataset: ${PARENT_DATASET}"
        if ! zfs create -p "${PARENT_DATASET}"; then
            log_msg "err" "Failed to create parent dataset."
            return 1
        fi
    fi
    return 0
}

create_zfs_dataset() {
    local dataset_name="$1"

    if zfs list -H -o name "${dataset_name}" >/dev/null 2>&1; then
        log_msg "info" "Dataset already exists: ${dataset_name}"
        return 0
    fi

    log_msg "info" "Creating dataset: ${dataset_name}"

    if ! zfs create "${dataset_name}"; then
        log_msg "err" "Failed to create dataset: ${dataset_name}"
        return 1
    fi

    return 0
}

create_zfs_snapshot() {
    local dataset_name="$1"
    local snapshot_name="{{ s3_snapshot_name_format }}"

    log_msg "info" "Creating snapshot: ${dataset_name}@${snapshot_name}"

    if ! zfs snapshot "${dataset_name}@${snapshot_name}"; then
        log_msg "err" "Failed to create snapshot: ${dataset_name}@${snapshot_name}"
        return 1
    fi

    return 0
}

is_excluded() {
    local bucket="$1"
    local IFS=','
    for excluded in $EXCLUDED_BUCKETS; do
        [[ "$bucket" == "$excluded" ]] && return 0
    done
    return 1
}

download_bucket() {
    rclone sync $REMOTE:"$1" "$2" \
    --fast-list \
    --transfers "$TRANSFERS" \
    --checkers "$CHECKERS" \
    --buffer-size 32M \
    --error-on-no-transfer
}


# --- Main Execution Flow ---
main() {
    # Lock to prevent concurrent runs
    local lock_dir="${RUNTIME_DIRECTORY:-/var/lock}"
    exec {lock_fd}<>"${lock_dir}/download-s3.lock"
    if ! flock -n -x "${lock_fd}"; then
        log_msg "err" "Another instance of the script is already running. Exiting."
        exit 0
    fi


    log_msg "info" "Starting S3 bucket ZFS provisioning..."

    # Pre-flight checks
    check_dependencies || exit 1
    ensure_parent_dataset || exit 1

    # Fetch data
    local buckets
    if ! buckets=$(fetch_bucket_list); then
        log_msg "err" "Aborting provisioning due to API or parsing failure."
        exit 1
    fi

    if [[ -z "${buckets}" ]]; then
        log_msg "warning" "No buckets returned from the API."
        exit 0
    fi

    exit_code=0

    # Iterate and apply state
    while IFS= read -r bucket; do

        if is_excluded "$bucket" ; then
            log_msg "warning" "Skipping excluded bucket: $bucket"
            continue
        fi

        # Sanitize bucket name to strictly conform to ZFS naming rules
        local clean_bucket=$(echo "${bucket}" | tr -cd 'a-zA-Z0-9.-')

        [[ -z "${clean_bucket}" ]] && continue

        create_zfs_dataset "${PARENT_DATASET}/${clean_bucket}" || {
            log_msg "warning" "Skipping to the next bucket due to zfs creation error."
            continue
        }

        retry=0
        success=0
        while (( retry < 5 )); do

            ((++retry))
            DEST="/$PARENT_DATASET/$clean_bucket"
            download_bucket "$clean_bucket" "$DEST" || {
                success=$?
                if (( success == 9 )); then
                    log_msg "warning" "No files to transfer for bucket: $clean_bucket. Marking as success."
                    success=0
                    break
                elif ((success != 0 )); then
                    log_msg "err" "Attempt $retry: Failed to sync bucket: $clean_bucket. Retrying..."
                fi

                sleep 5
                continue
            }
            success=0
            break
        done

        if (( success != 0 && success != 9)); then
            log_msg "err" "Failed to sync bucket after 5 attempts: $clean_bucket. Giving up and moving to the next bucket."
            exit_code=1
            continue
        fi

    create_zfs_snapshot "${PARENT_DATASET}/${clean_bucket}" || {
        log_msg "warning" "Failed to create snapshot for bucket: ${clean_bucket}"
    }

    log_msg "info" "Finished processing bucket: ${bucket}"


    done <<< "${buckets}"

    exit "${exit_code}"
}

# Execute main only if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
