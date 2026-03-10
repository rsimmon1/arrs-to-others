# arrs-to-others

A containerized file synchronization service that copies media files from a downloads location (e.g., from Sonarr/Radarr) to one or more remote destinations (e.g., QNAP NAS, Plex servers) via CIFS/SMB mounts and rsync.

## How It Works

1. **Check** for files in the configured downloads location (e.g., `/srv/media/`)
2. **Backup** — if files are found, create a local backup copy for each configured destination
3. **Remove** the files from the downloads location
4. **Rsync** each local backup to its remote destination in order, removing the backup files after a successful sync
5. **Sleep** for a configurable interval (default: 60 seconds)
6. **Repeat**

This design ensures all destinations receive the files even if one is slow or temporarily unavailable.

## Configuration

All configuration is done via environment variables:

| Variable | Default | Description |
|---|---|---|
| `SYNC_USERNAME` | *(required)* | Username for CIFS/SMB mounts |
| `SYNC_PASSWORD` | *(required)* | Password for CIFS/SMB mounts |
| `ARRS_LOCATION` | `/srv/media/` | Source downloads directory |
| `ARRS_FOLDERS` | `movies,tvshows` | Comma-separated list of source folder names |
| `BACKUP_LOCATION` | `/srv/backup/` | Local staging/backup directory |
| `SLEEP_INTERVAL` | `60` | Seconds to sleep between checks |
| `TRIGGER_FILE` | `TRIGGERCOPY.TXT` | Trigger file name written after a successful copy |
| `LOG_FILE` | `log_run.txt` | Log file path |
| `DESTINATIONS` | *(see below)* | Destination configuration string |

### DESTINATIONS format

Destinations are defined in a single environment variable using pipe-separated fields and semicolon-separated entries:

```
name|share|mount|dest_folder1,dest_folder2;name2|share2|mount2|dest_folder1,dest_folder2
```

- **name** — a label for the destination (used for backup directory naming)
- **share** — the CIFS/SMB share path (e.g., `//server.example.com/ShareName`)
- **mount** — the local mount point (e.g., `/mnt/server`)
- **dest_folders** — comma-separated destination folder names, mapped positionally to `ARRS_FOLDERS`

#### Example — single destination (default)

```
DESTINATIONS="plex26|//plex26.randrservices.com/PlexData|/mnt/plex26|Movies,TV Shows"
```

This syncs:
- `/srv/media/movies` → `/mnt/plex26/Movies`
- `/srv/media/tvshows` → `/mnt/plex26/TV Shows`

#### Example — multiple destinations

```
DESTINATIONS="plex26|//plex26.randrservices.com/PlexData|/mnt/plex26|Movies,TV Shows;qnap|//qnap.example.com/PlexData|/mnt/qnap|Movies,TV Shows"
```

This syncs to plex26 first, then qnap.

## Docker Usage

### Build

```bash
docker build -t arrs-to-others .
```

### Run

```bash
docker run -d \
  --name arrs-to-others \
  --privileged \
  -e SYNC_USERNAME=myuser \
  -e SYNC_PASSWORD=mypassword \
  -e ARRS_LOCATION=/srv/media/ \
  -e ARRS_FOLDERS=movies,tvshows \
  -e BACKUP_LOCATION=/srv/backup/ \
  -e SLEEP_INTERVAL=60 \
  -e 'DESTINATIONS=plex26|//plex26.randrservices.com/PlexData|/mnt/plex26|Movies,TV Shows;qnap|//qnap.example.com/PlexData|/mnt/qnap|Movies,TV Shows' \
  -v /path/to/media:/srv/media \
  arrs-to-others
```

> **Note:** The container requires `--privileged` or appropriate capabilities (`SYS_ADMIN`, `DAC_READ_SEARCH`) to mount CIFS shares.
