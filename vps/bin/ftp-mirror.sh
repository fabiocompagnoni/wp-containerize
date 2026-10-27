#!/bin/sh
# Runs inside the mirror container started by migrate-site.sh. Downloads wp-config.php
# and wp-content from the old host into /import. Read only: nothing is written on the source.
# Settings from the environment: FTP_PROTO (ftp|ftps|sftp), FTP_HOST, FTP_USER, FTP_PATH,
# FTP_VERIFY_TLS (yes|no), LFTP_PASSWORD, OWNER (uid:gid of the downloaded files).
set -eu

apk add --no-cache lftp openssh-client >/dev/null

settings="set cmd:fail-exit yes; set net:max-retries 3; set net:timeout 30"
settings="$settings; set net:reconnect-interval-base 5; set sftp:auto-confirm yes"
settings="$settings; set ssl:verify-certificate $FTP_VERIFY_TLS"
case "$FTP_PROTO" in
    ftp)  url="ftp://$FTP_HOST" ;;
    # explicit TLS (AUTH TLS on port 21), required for login and data
    ftps) url="ftp://$FTP_HOST"
          settings="$settings; set ftp:ssl-force true; set ftp:ssl-protect-data true" ;;
    sftp) url="sftp://$FTP_HOST" ;;
    *) echo "unknown protocol $FTP_PROTO" >&2; exit 2 ;;
esac

remote() { lftp -c "$settings; open --env-password -u \"$FTP_USER\" $url; $1"; }

# wp-config.php may also sit one level above the document root
parent=$(dirname "$FTP_PATH")
if ! remote "get \"$FTP_PATH/wp-config.php\" -o /import/wp-config.php" 2>/dev/null \
    && ! remote "get \"$parent/wp-config.php\" -o /import/wp-config.php"; then
    echo "wp-config.php not found in $FTP_PATH or $parent" >&2
    exit 1
fi

echo "downloading $FTP_PATH/wp-content" >&2
# --continue: a second run downloads only what is missing or changed
remote "mirror --continue --parallel=4 --no-perms --no-symlinks \
    --exclude-glob cache/ --exclude-glob upgrade/ \
    \"$FTP_PATH/wp-content\" /import/files/wp-content"

chown -R "$OWNER" /import
