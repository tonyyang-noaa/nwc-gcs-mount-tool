# GCS Bucket Mounting Tool

`gcs_mount.ps1` is a Windows PowerShell WPF application for mounting Google Cloud Storage buckets as local Windows drive letters. It wraps `rclone`, WinFsp, and the Google Cloud CLI with a small desktop UI so users can sign in, save bucket mount profiles, connect or disconnect drives, and optionally auto-mount selected buckets at Windows login.

The repo also includes `gcs_mount_admin.ps1`, an administrative/maintenance variant of the same tool. It keeps the `Refresh Folder` button that was removed from the standard user-facing script.

## What It Does

- Mounts one or more Google Cloud Storage buckets as Windows drives.
- Uses `rclone` with Google Cloud Storage authentication.
- Stores multiple mount profiles with bucket name, project ID, drive letter, and auto-mount preference.
- Provides a WPF desktop UI for sign-in, bucket lookup, mount configuration, connection, disconnection, and global settings.
- Saves settings under `%APPDATA%\GCSMountApp`.
- Creates a Windows Startup shortcut when one or more mounts are marked for auto-mount.
- Tunes transfer throughput with configurable rclone settings:
  - parallel transfers
  - checkers
  - per-file buffer size
  - VFS read-ahead
  - multi-thread streams
  - chunk size
- Uses rclone VFS caching for mounted-drive behavior.
- Watches mounted-drive deletes and prunes empty Google Cloud Console folder records so deleted empty folders do not continue to appear in the Cloud Console.
- Runs root folder reconciliation in the background so the mounted drive and Cloud Console folder view stay aligned for empty root folders.

## Requirements

- Windows with Windows PowerShell 5.1.
- WinFsp installed.
- `rclone.exe` installed.
- Google Cloud CLI installed with `gcloud.cmd` or `gcloud.ps1` available.
- Google account permissions for the target GCS buckets.
- Access to create, list, and delete folder records in buckets that use hierarchical namespace.

## Run From PowerShell

Open PowerShell in the project folder and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount.ps1
```

To start in auto-mount mode:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount.ps1 -AutoMount
```

Auto-mount mode waits briefly, mounts profiles marked for auto-mount, and can start hidden through the Windows Startup shortcut created by the app.

To run the admin/maintenance variant:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount_admin.ps1
```

## Script Variants

### `gcs_mount.ps1`

Use this as the standard user-facing application. It supports authentication, bucket selection, drive mounting, disconnection, auto-mount, transfer tuning, and automatic Cloud Console folder cleanup.

This version does not show the `Refresh Folder` button. It is intended for normal daily use so users have a simpler interface and do not need to decide when to run manual folder repair actions.

### `gcs_mount_admin.ps1`

Use this version for administrative maintenance or troubleshooting. It includes everything in `gcs_mount.ps1` plus the `Refresh Folder` button.

The `Refresh Folder` workflow is useful when Google Cloud Console shows folder records that the mounted drive cannot list, especially empty folders created directly in the Cloud Console. It lets an administrator select a mounted-drive parent folder, scan for Console folders missing from the mounted drive, and create rclone-visible compatibility markers for selected folders.

Use `gcs_mount_admin.ps1` when:

- an administrator needs to repair folder visibility between Cloud Console and the mounted drive;
- empty Cloud Console folders need compatibility markers so rclone can show them;
- troubleshooting requires the manual folder refresh workflow.

Use `gcs_mount.ps1` when:

- users only need to mount, disconnect, and auto-mount buckets;
- the simpler production UI is preferred;
- folder cleanup should be handled automatically in the background.

## First-Time Setup

1. Run `gcs_mount.ps1`.
2. Open `Settings`.
3. Set the folder path that contains `rclone.exe`.
4. Set the WinFsp path if needed.
5. Choose a cache directory with enough free space.
6. Adjust transfer performance settings if desired.
7. Select `Sign In to Google Cloud` and complete the browser authentication flow.
8. Enter a Google Cloud project ID.
9. Select `Fetch Buckets`, or type the bucket name manually.
10. Choose an available drive letter.
11. Select whether the mount should auto-mount at Windows login.
12. Save and mount the drive.

## Package As An EXE

If `Invoke-ps2exe` is available, build the GUI executable with:

```powershell
Invoke-ps2exe -inputFile .\gcs_mount.ps1 -outputFile .\dist\GCS_Manager.exe -noConsole -STA -title 'GCS Bucket Mounting Tool' -description 'GCS Bucket Mounting Tool' -product 'GCS Bucket Mounting Tool' -version '0.0.0.0'
```

To package the admin/maintenance variant, change the input and output names:

```powershell
Invoke-ps2exe -inputFile .\gcs_mount_admin.ps1 -outputFile .\dist\GCS_Manager_Admin.exe -noConsole -STA -title 'GCS Bucket Mounting Tool Admin' -description 'GCS Bucket Mounting Tool Admin' -product 'GCS Bucket Mounting Tool' -version '0.0.0.0'
```

Run the packaged app with:

```powershell
.\dist\GCS_Manager.exe
```

## Runtime Files

The app writes runtime files to:

```text
%APPDATA%\GCSMountApp
```

Important files include:

- `settings_multi.json`: saved global settings and mount profiles.
- `rclone.log`: shared app and cleanup log.
- `rclone_<drive>.log`: per-drive rclone logs.
- `console_folder_cleanup_worker.ps1`: helper script generated by the app for Cloud Console folder cleanup.
- `console_folder_root_reconcile_scheduler.ps1`: helper script generated by the app for periodic root folder reconciliation.

## Folder Delete Behavior

Google Cloud Storage hierarchical namespace buckets can show empty folder records in the Cloud Console even after a mounted drive no longer shows that folder. This app treats the mounted drive as the user-facing source of truth for empty folders.

When files or folders are deleted from the mounted drive, the app queues cleanup work through `gcloud storage` to remove empty folder records. It also periodically compares root folders visible in the mounted drive against root folders visible in the Cloud Console and prunes Console-only empty root folders.

The cleanup is intentionally conservative around non-empty folders. Folders with remaining cloud contents are kept.

## Transfer Performance Settings

Use `Settings` to adjust performance-related values:

- `Parallel Transfers`: number of simultaneous file transfers.
- `Checkers`: number of parallel metadata checks.
- `Buffer per Open File (MB)`: memory buffer used by rclone for each open file.
- `VFS Read Ahead (MB)`: amount of data rclone reads ahead for mounted-drive reads.
- `Multi-thread Streams`: number of streams for larger downloads.
- `Chunk Size (MB)`: read chunk size for VFS reads.

Higher values can improve throughput on fast networks, but they can also increase memory usage, API activity, and local cache pressure.

## Troubleshooting

- If authentication does not open a browser, close stale `rclone config` processes and try signing in again.
- If a drive does not appear, confirm WinFsp is installed and the selected drive letter is available.
- If bucket fetch fails, confirm the project ID and Google account permissions.
- If a mounted drive is slow, review cache location, cache size, transfer settings, and available disk space.
- If Cloud Console still shows a recently deleted empty folder, wait for the background reconciliation cycle and refresh the Cloud Console page.
- Check `%APPDATA%\GCSMountApp\rclone.log` for cleanup and mount status messages.

## Main Script

The application is implemented in:

```text
gcs_mount.ps1
gcs_mount_admin.ps1
```
