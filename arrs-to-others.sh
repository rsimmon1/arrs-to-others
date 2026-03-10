#!/bin/bash

set -e

# ==================== Configuration ====================
# Downloads/source location
ARRS_LOCATION="${ARRS_LOCATION:-/srv/media/}"

# Comma-separated list of source folder names
ARRS_FOLDERS_CSV="${ARRS_FOLDERS:-movies,tvshows}"

# Local backup/staging area on the local drive
BACKUP_LOCATION="${BACKUP_LOCATION:-/srv/backup/}"

# Sleep interval between checks (seconds)
SLEEP_INTERVAL="${SLEEP_INTERVAL:-60}"

# Trigger file name created after a successful copy
TRIGGER_FILE="${TRIGGER_FILE:-TRIGGERCOPY.TXT}"

# Log file path
LOG_FILE="${LOG_FILE:-log_run.txt}"

# Destinations configuration (semicolon-separated destinations, pipe-separated fields)
# Format: name|share|mount|dest_folder1,dest_folder2;name2|share2|mount2|dest_folder1,dest_folder2
# Example for two destinations:
#   plex26|//plex26.randrservices.com/PlexData|/mnt/plex26|Movies,TV Shows;qnap|//qnap.example.com/PlexData|/mnt/qnap|Movies,TV Shows
DESTINATIONS="${DESTINATIONS:-plex26|//plex26.randrservices.com/PlexData|/mnt/plex26|Movies,TV Shows}"

# ==================== Parse Configuration ====================
# Parse source folders into an array
IFS=',' read -ra ARRS_FOLDERS_ARR <<< "$ARRS_FOLDERS_CSV"

# Parse destinations into parallel arrays
IFS=';' read -ra DEST_ENTRIES <<< "$DESTINATIONS"

declare -a DEST_NAMES
declare -a DEST_SHARES
declare -a DEST_MOUNTS
declare -a DEST_FOLDERS_CSV

for entry in "${DEST_ENTRIES[@]}"; do
    IFS='|' read -r name share mount folders <<< "$entry"
    DEST_NAMES+=("$name")
    DEST_SHARES+=("$share")
    DEST_MOUNTS+=("$mount")
    DEST_FOLDERS_CSV+=("$folders")
done

# ==================== Functions ====================

# Function to check and mount a CIFS share if not already mounted
mount_if_needed() {
    local share=$1
    local mountpoint=$2

    # Ensure the mount point directory exists
    if [ ! -d "$mountpoint" ]; then
        echo "Creating mount point $mountpoint"
        mkdir -p "$mountpoint"
    fi

    # Use findmnt to check if the mount point is already used
    if findmnt -rno TARGET "$mountpoint" > /dev/null; then
        echo "$mountpoint is already mounted."
    else
        echo "Attempting to mount $share to $mountpoint"
        if ! mount.cifs "$share" "$mountpoint" -o "user=$SYNC_USERNAME,password=$SYNC_PASSWORD,vers=2.1"; then
            echo "Failed to mount $share on $mountpoint"
            dmesg | tail -10
        fi
    fi
}

# ==================== Mount All Destinations ====================
echo "==================== Mounting destinations ===================="
for d in "${!DEST_NAMES[@]}"; do
    echo "Mounting ${DEST_NAMES[d]}: ${DEST_SHARES[d]} -> ${DEST_MOUNTS[d]}"
    mount_if_needed "${DEST_SHARES[d]}" "${DEST_MOUNTS[d]}"
done

df -h

echo "==================== Configuration ===================="
echo "Downloads location: $ARRS_LOCATION"
echo "Source folders: ${ARRS_FOLDERS_ARR[*]}"
echo "Backup location: $BACKUP_LOCATION"
echo "Sleep interval: $SLEEP_INTERVAL seconds"
echo "Destinations:"
for d in "${!DEST_NAMES[@]}"; do
    IFS=',' read -ra dest_folders <<< "${DEST_FOLDERS_CSV[d]}"
    echo "  ${DEST_NAMES[d]}: ${DEST_SHARES[d]} -> ${DEST_MOUNTS[d]}"
    for f in "${!ARRS_FOLDERS_ARR[@]}"; do
        echo "    ${ARRS_FOLDERS_ARR[f]} -> ${dest_folders[f]}"
    done
done
echo "========================================================"

# ==================== Main Loop ====================
while true; do
    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    echo -n "START: ${START_TIME} " >> "$LOG_FILE"
    echo -n "START: ${START_TIME} "

    FILES_FOUND=false

    # Step 1: Check for files in any source folder
    for folder in "${ARRS_FOLDERS_ARR[@]}"; do
        if [ -n "$(ls -A "${ARRS_LOCATION}${folder}" 2>/dev/null)" ]; then
            FILES_FOUND=true
            break
        fi
    done

    if [ "$FILES_FOUND" = true ]; then
        echo
        echo "============ Files found - processing ============"

        # Step 2: Create a local backup for each destination
        for d in "${!DEST_NAMES[@]}"; do
            dest_name="${DEST_NAMES[d]}"
            echo "--- Creating backup for ${dest_name} ---"

            for folder in "${ARRS_FOLDERS_ARR[@]}"; do
                src="${ARRS_LOCATION}${folder}"
                backup_dir="${BACKUP_LOCATION}${dest_name}/${folder}"

                if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
                    mkdir -p "$backup_dir"
                    echo "  Backing up $src -> $backup_dir"
                    cp -a "$src"/. "$backup_dir"/
                fi
            done
        done

        # Step 3: Remove files from the downloads location
        echo "--- Removing files from downloads location ---"
        for folder in "${ARRS_FOLDERS_ARR[@]}"; do
            src="${ARRS_LOCATION}${folder}"
            if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
                echo "  Cleaning $src"
                find "$src" -mindepth 1 -delete
            fi
        done

        # Step 4: Rsync each backup to its destination in order
        for d in "${!DEST_NAMES[@]}"; do
            dest_name="${DEST_NAMES[d]}"
            dest_mount="${DEST_MOUNTS[d]}"
            IFS=',' read -ra dest_folders <<< "${DEST_FOLDERS_CSV[d]}"

            echo "--- Syncing to ${dest_name} ---"

            for f in "${!ARRS_FOLDERS_ARR[@]}"; do
                backup_dir="${BACKUP_LOCATION}${dest_name}/${ARRS_FOLDERS_ARR[f]}"
                dest_dir="${dest_mount}/${dest_folders[f]}"

                if [ -d "$backup_dir" ] && [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
                    echo
                    echo "  *************** ${backup_dir} to ${dest_dir} ***************"
                    ls "$backup_dir" || true
                    rsync -r -ah --remove-source-files -P "$backup_dir"/ "$dest_dir" || true
                    find "$backup_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
                    echo "${START_TIME}" > "${dest_dir}/${TRIGGER_FILE}"
                    echo "  *************** ${backup_dir} to ${dest_dir} Done ***************"
                fi
            done
        done

        echo "============ Processing complete ============"
    else
        for folder in "${ARRS_FOLDERS_ARR[@]}"; do
            echo -n " No files ${ARRS_LOCATION}${folder} "
        done
    fi

    FINISH_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo " FINISH: ${FINISH_TIME}" >> "$LOG_FILE"
    echo " FINISH: ${FINISH_TIME} "

    sleep "$SLEEP_INTERVAL"
done
