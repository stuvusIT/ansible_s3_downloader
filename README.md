# s3_downloader

Ansible role to install dependencies and configure a script (`download-s3.sh`) to download/sync S3 buckets to local ZFS datasets using `rclone` and the AWS CLI.

For managing snapshot retention or replication to another host [stuvusIT/ansible_zrepl](https://github.com/stuvusIT/ansible_zrepl) can be used.

## Requirements

The role relies on the following tools (the role installs most of them automatically):
- `curl`
- `jq`
- `rclone`
- `awscli`
- `zfs` (ZFS must be configured on the host system to allow creating datasets).

The basic assumption is that a zpool exists already, the datasets are created by the script as needed.
One child dataset per bucket is created automatically if needed and snapshots are taken after the sync is complete.

### Permissions

The script makes use of the Ceph RGW AdminOps API to list all buckets, so `--caps buckets=read` has to be granted to the user.
Additionally, a role needs to be created to allow access to the content of all buckets.
The script uses the [STS](https://docs.ceph.com/en/squid/radosgw/STS/) support in Ceph RGW to assume this role and access the objects.

## Role Variables

Settable variables for this role are found in `defaults/main.yml`.

| Name                         | Required/Default         | Description                                                                            |
| ---------------------------- | ------------------------ | -------------------------------------------------------------------------------------- |
| `s3_endpoint`                | `https://s3.example.com` | The S3 API endpoint URL.                                                               |
| `s3_parent_dataset`          | `backups/s3`             | The parent ZFS dataset where buckets will be downloaded.                               |
| `s3_aws_access_key_id`       | `dummy`                  | The AWS access key ID for authentication.                                              |
| `s3_aws_secret_key`          | `dummy`                  | The AWS secret key for authentication.                                                 |
| `s3_download_timer_schedule` | `daily`                  | Schedule for the systemd timer (e.g. `daily`, `weekly`, or systemd OnCalendar format). |
| `s3_excluded_buckets`        | `[]`                     | A list of bucket names to exclude from the download processes.                         |

## Example

```yml
- hosts: backup-server
  roles:
    - role: s3_downloader
      vars:
        s3_endpoint: "https://s3.your-domain.com"
        s3_parent_dataset: "tank/backups/s3"
        s3_aws_access_key_id: "your-access-key"
        s3_aws_secret_key: "your-secret-key"
        s3_download_timer_schedule: "*-*-* 02:00:00"
        s3_excluded_buckets:
          - ignore-bucket-1
          - ignore-bucket-2
```

## License

This work is licensed under the [MIT License](./LICENSE).


## Author Information

- [Sven Feyerabend](https://github.com/SF2311) _sven.feyerabend @ stuvus.uni-stuttgart.de_
