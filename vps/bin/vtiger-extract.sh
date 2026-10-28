#!/bin/sh
# Runs in a container of the WordPress image (GNU tar and BusyBox unzip, no network needed),
# started by migrate-vtiger.sh. From /source/<archive> (.tar, .tar.gz, .tgz or .zip) extracts
# the main vtiger install (the folder with vtigerversion.php closest to the archive root)
# into /html. Left out: other vtiger installs in subfolders, logs, caches, compiled
# templates, archives (old patches, backups) and symbolic links.
# Settings from the environment: ARCHIVE (file name in /source), OWNER (uid:gid).
set -eu

archive="/source/$ARCHIVE"
work=/html/.extract
rm -rf "$work"
mkdir -p "$work"

list_entries() {
    case "$archive" in
        *.zip) unzip -l "$archive" | awk 'NR > 3 && $1 ~ /^[0-9]+$/ && NF >= 4 { sub(/^ *[0-9]+ +[^ ]+ +[^ ]+ +/, ""); print }' ;;
        *) tar -tf "$archive" ;;
    esac
}

# folders that hold a vtiger install, shortest first: the first one is the main install
installs=$(list_entries | sed -n 's|^\(.*\)vtigerversion\.php$|\1|p' | awk '{ print length " " $0 }' | sort -n | cut -d' ' -f2-)
root=$(printf '%s\n' "$installs" | head -n 1)
[ -n "$installs" ] || { echo "no vtigerversion.php in the archive" >&2; exit 1; }
echo "extracting vtiger from \"${root:-/}\"" >&2

# exclusions, all anchored to the install folder: runtime data that is rebuilt (whole
# folders), nested installs, and archives left in the install folder itself (old patches,
# backups). Archives in subfolders are kept: storage/ holds attachments with their
# original extension.
folders="logs cache test/templates_c old_patch"
nested_installs=$(printf '%s\n' "$installs" | tail -n +2)
for nested in $nested_installs; do echo "skipping the other install in $nested" >&2; done

case "$archive" in
    *.zip)
        # BusyBox unzip: * also matches "/", so the root archives are not excluded here
        patterns=""
        for folder in $folders; do patterns="$patterns ${root}${folder}/*"; done
        for nested in $nested_installs; do patterns="$patterns ${nested}*"; done
        # shellcheck disable=SC2086  # one pattern per word
        unzip -q -o "$archive" "${root}*" -d "$work" -x $patterns
        ;;
    *)
        set -- --anchored --no-wildcards-match-slash \
            --exclude="${root}*.zip" --exclude="${root}*.tar.gz" --exclude="${root}*.tgz" \
            --wildcards-match-slash
        for folder in $folders; do set -- "$@" --exclude="${root}${folder}/*"; done
        for nested in $nested_installs; do set -- "$@" --exclude="${nested%/}"; done
        tar -xf "$archive" -C "$work" --no-same-owner --no-same-permissions "$@" "${root:-.}"
        ;;
esac

# the install folder becomes /html
src="$work/$root"
find "$src" -mindepth 1 -maxdepth 1 -exec mv {} /html/ \;
rm -rf "$work"
mkdir -p /html/logs /html/cache /html/test/templates_c
find /html -type l -delete
chown -R "$OWNER" /html
