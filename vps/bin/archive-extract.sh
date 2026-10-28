#!/bin/sh
# Runs in a container of the WordPress image (GNU tar and BusyBox unzip, no network needed),
# started by migrate-site.sh. From /source/<archive> (.tar, .tar.gz, .tgz or .zip) extracts
# into /import:
#   files/wp-content   the main wp-content (the one closest to the archive root), no caches
#   wp-config.php      next to it or one level above, if the archive has it
# Other WordPress installs in subfolders and symbolic links are left out.
# Settings from the environment: ARCHIVE (file name in /source), OWNER (uid:gid).
set -eu

archive="/source/$ARCHIVE"
work=/import/.extract
rm -rf "$work" /import/files/wp-content
mkdir -p "$work" /import/files

list_entries() {
    case "$archive" in
        # "  Length  Date  Time  Name": keep the name
        *.zip) unzip -l "$archive" | awk 'NR > 3 && $1 ~ /^[0-9]+$/ && NF >= 4 { sub(/^ *[0-9]+ +[^ ]+ +[^ ]+ +/, ""); print }' ;;
        *) tar -tf "$archive" ;;
    esac
}

# folder holding the main wp-content/, e.g. "", "./", "public_html/": the shortest path
# before the first "wp-content/" of every entry
root=$(list_entries | awk '{ i = index($0, "wp-content/"); if (i) print length(substr($0, 1, i - 1)) " " substr($0, 1, i - 1) }' \
    | sort -n -u | head -n 1 | cut -d' ' -f2-)
if ! list_entries | grep -q "^${root}wp-content/"; then
    echo "no wp-content/ in the archive" >&2
    exit 1
fi
parent=""
case "$root" in ""|./) ;; *) parent=$(dirname "${root%/}")/ ;; esac
[ "$parent" != "./" ] || parent=""
echo "extracting ${root}wp-content" >&2

case "$archive" in
    *.zip)
        unzip -q -o "$archive" "${root}wp-content/*" -d "$work" \
            -x "${root}wp-content/cache/*" "${root}wp-content/et-cache/*" \
               "${root}wp-content/upgrade/*" "${root}wp-content/upgrade-temp-backup/*"
        unzip -q -o "$archive" "${root}wp-config.php" -d "$work" 2>/dev/null \
            || { [ -z "$parent" ] || unzip -q -o "$archive" "${parent}wp-config.php" -d "$work" 2>/dev/null; } \
            || true
        ;;
    *)
        tar -xf "$archive" -C "$work" --no-same-owner --no-same-permissions \
            --exclude="${root}wp-content/cache" \
            --exclude="${root}wp-content/et-cache" \
            --exclude="${root}wp-content/upgrade" \
            --exclude="${root}wp-content/upgrade-temp-backup" \
            "${root}wp-content"
        tar -xf "$archive" -C "$work" --no-same-owner "${root}wp-config.php" 2>/dev/null \
            || { [ -z "$parent" ] || tar -xf "$archive" -C "$work" --no-same-owner "${parent}wp-config.php" 2>/dev/null; } \
            || true
        ;;
esac

mv "$work/${root}wp-content" /import/files/wp-content
for config in "$work/${root}wp-config.php" "$work/${parent}wp-config.php"; do
    if [ -f "$config" ]; then
        mv "$config" /import/wp-config.php
        chmod 600 /import/wp-config.php
        echo "wp-config.php found in the archive" >&2
        break
    fi
done
rm -rf "$work"
find /import/files -type l -delete
chown -R "$OWNER" /import
