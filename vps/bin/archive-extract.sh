#!/bin/sh
# Runs in a container of the WordPress image (GNU tar, no network needed), started by
# migrate-site.sh. Extracts the main
# wp-content (the one closest to the archive root) from /source/<archive> into /import.
# Other WordPress installs in subfolders, caches and symbolic links are left out.
# Settings from the environment: ARCHIVE (file name in /source), OWNER (uid:gid).
set -eu

archive="/source/$ARCHIVE"

# path of the main wp-content/, e.g. "" or "public_html/"
prefix=$(tar -tf "$archive" | sed -n 's|^\(\./\)\{0,1\}\(.*\)wp-content/$|\2|p' \
    | awk '{ print length, $0 }' | sort -n | head -n 1 | cut -d' ' -f2-)
if ! tar -tf "$archive" | grep -Eq "^(\./)?${prefix}wp-content/"; then
    echo "no wp-content/ in the archive" >&2
    exit 1
fi
leading=$(tar -tf "$archive" | head -n 1 | grep -q '^\./' && echo './' || true)
strip=$(printf '%s' "$prefix" | tr -cd '/' | wc -c)
[ -z "$leading" ] || strip=$((strip + 1))
echo "extracting ${leading}${prefix}wp-content" >&2

mkdir -p /import/files
tar -xf "$archive" -C /import/files --strip-components="$strip" \
    --no-same-owner --no-same-permissions \
    --exclude="${leading}${prefix}wp-content/cache" \
    --exclude="${leading}${prefix}wp-content/et-cache" \
    --exclude="${leading}${prefix}wp-content/upgrade" \
    --exclude="${leading}${prefix}wp-content/upgrade-temp-backup" \
    "${leading}${prefix}wp-content"
find /import/files -type l -delete
chown -R "$OWNER" /import
