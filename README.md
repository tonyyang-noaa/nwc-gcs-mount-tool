# GCS Bucket Mounting Tool

A Windows PowerShell WPF desktop application suite for mounting Google Cloud Storage (GCS) buckets as local Windows drive letters. It wraps `rclone`, WinFsp, and the Google Cloud CLI (`gcloud`) into an intuitive graphical interface that handles authentication, multi-bucket profile management, drive connection/disconnection, performance tuning, and automated folder lifecycle synchronization.

The repository contains two script variants:
- **`gcs_mount.ps1`**: The standard user-facing application for everyday mounting, auto-mounting, and automated background folder cleanup.
- **`gcs_mount_admin.ps1`**: The administrative/maintenance variant that includes an interactive **Refresh Folder** utility to diagnose and repair folder visibility mismatches between Google Cloud Console and Windows File Explorer.

---

## Table of Contents

- [Overview & Architecture](#overview--architecture)
- [Key Features](#key-features)
- [Script Comparison (`gcs_mount.ps1` vs `gcs_mount_admin.ps1`)](#script-comparison)
- [How Folder Synchronization & Repair Works](#how-folder-synchronization--repair-works)
  - [Background Delete Cleanup & Root Reconciliation](#background-delete-cleanup--root-reconciliation)
  - [Manual Folder Repair (Admin Variant)](#manual-folder-repair-admin-variant)
- [Prerequisites & System Requirements](#prerequisites--system-requirements)
- [Usage & Execution](#usage--execution)
  - [Interactive Mode](#interactive-mode)
  - [Auto-Mount Mode](#auto-mount-mode)
  - [Admin Mode](#admin-mode)
- [First-Time Setup Guide](#first-time-setup-guide)
- [Configuration & Performance Tuning](#configuration--performance-tuning)
  - [Global Settings (`settings_multi.json`)](#global-settings-settings_multijson)
  - [Transfer & Cache Performance Options](#transfer--cache-performance-options)
- [Packaging as Standalone Executables (`.exe`)](#packaging-as-standalone-executables-exe)
- [Runtime Files & Directory Structure](#runtime-files--directory-structure)
- [Troubleshooting & Diagnostics](#troubleshooting--diagnostics)

---

## Overview & Architecture

Google Cloud Storage is an object store without native filesystem directory concepts, whereas Windows applications and File Explorer require standard hierarchical directory structures. This tool bridges that gap by coordinating three core technologies:

1. **`rclone`**: Interfaces with GCS using OAuth2 authentication and mounts buckets as virtual drives via WinFsp with a full VFS (Virtual File System) read/write cache.
2. **`WinFsp` (Windows File System Proxy)**: Provides the Windows kernel-level filesystem driver allowing user-mode rclone processes to expose drive letters (e.g., `X:`, `Z:`).
3. **Google Cloud CLI (`gcloud`)**: Used for querying Cloud Console folder metadata and managing bucket folder records that standard rclone commands cannot directly manipulate.

```
┌──────────────────────────────────────────────────────────────────┐
│                    WPF Desktop Application                       │
│             (gcs_mount.ps1 / gcs_mount_admin.ps1)                │
└───────────────┬───────────────────────────────┬──────────────────┘
                │                               │
       ┌────────▼────────┐             ┌────────▼────────┐
       │   rclone.exe    │             │   gcloud.cmd    │
       │ (VFS Mount & RC)│             │ (Folder Cleanup │
       └────────┬────────┘             │  & Reconcile)   │
                │                      └────────┬────────┘
       ┌────────▼────────┐                      │
       │     WinFsp      │                      │
       │ (Virtual Drive) │                      │
       └────────┬────────┘                      │
                │                               │
                └───────────────┬───────────────┘
                                │
                     ┌──────────▼──────────┐
                     │ Google Cloud Storage│
                     │    (GCS Bucket)     │
                     └─────────────────────┘
```

---

## Key Features

- **Multi-Drive Profile Management**: Configure and save multiple bucket mount profiles, each with its own bucket name, Google Cloud project ID, assigned drive letter, and auto-mount setting.
- **Streamlined Google Cloud Authentication**:
  - Direct browser-based OAuth authentication flow.
  - Automatic session token validation and persistence across app restarts (users only sign in once).
  - Built-in "Zombie Killer" process cleaner that terminates stuck rclone authentication processes holding port `53682`.
- **Pre-Mount Validation Gatekeeper**: Verifies bucket accessibility and user permissions before attempting to mount, preventing dead or hanging drive mappings.
- **Smart Project ID Interception**: Prompts the user for a project ID when fetching buckets, preventing GCS API rejection errors.
- **Automated Startup Integration**: Automatically generates or removes a Windows Startup shortcut (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\GCSMultiMount.lnk`) based on whether any profiles have auto-mount enabled.
- **System Tray Minimization**: Minimizes to the Windows system tray with context menu controls ("Open Configuration", "Exit Application") to stay out of the way during daily work.
- **Granular Performance Tuning**: Full UI controls for adjusting parallel transfers, metadata checkers, memory buffer size, VFS read-ahead, multi-threading, and chunk sizes.
- **Robust Folder Lifecycle Management**:
  - Live `FileSystemWatcher` and rclone log monitoring for local delete operations.
  - Automatic cleanup of empty Cloud Console folder records.
  - Periodic background root-folder reconciliation.

---

## Script Comparison

| Feature / Aspect | `gcs_mount.ps1` (Standard) | `gcs_mount_admin.ps1` (Admin) |
| :--- | :--- | :--- |
| **Target Audience** | General end users, everyday workstations | System administrators, power users, support staff |
| **Primary Use Case** | Daily mounting, browsing, and auto-mounting GCS buckets | Troubleshooting, bucket maintenance, and folder repair |
| **UI Layout** | Clean sidebar with `Connect Drive`, `Disconnect Drive`, and `Settings` | Includes an extra **`Refresh Folder`** button (`#3B82F6`) in the sidebar |
| **Folder Visibility Repair** | Fully automated background cleanup only | Automated background cleanup **plus** interactive manual scanning and repair modal |
| **VFS Cache Invalidation** | Automatic on mount/unmount | On-demand via `Refresh-MountDirectoryCache` (using rclone Remote Control API) |
| **Marker Generation** | Automatic upon standard file/folder operations | Manual recursive batch generation for selected Cloud Console folders |
| **Recommended EXE Name** | `GCS_Manager.exe` | `GCS_Manager_Admin.exe` |

---

## How Folder Synchronization & Repair Works

### The Empty Folder Challenge in GCS
Google Cloud Storage buckets (especially with Hierarchical Namespace enabled) manage folders differently than Windows:
- **Cloud Console Folders**: Folders created via the web console often exist purely as Cloud Console folder metadata records without any underlying file objects.
- **rclone Requirement**: `rclone` requires either a real file inside a folder or a zero-byte directory marker object (e.g., `folder/`) to present the folder in Windows File Explorer.
- **Deleted Folder Lingering**: When a user deletes a folder from Windows File Explorer, Windows/rclone removes the local cached representation, but the GCS Cloud Console folder record may remain visible on the web.

### Background Delete Cleanup & Root Reconciliation
Both scripts implement automated background synchronization:
1. **Delete Watcher (`Start-ConsoleFolderDeleteWatcher`)**:
   - A `FileSystemWatcher` monitors the mounted drive for folder delete events.
   - A log watcher monitors the per-drive rclone log (`rclone_<drive>.log`) for rclone VFS deletion events (`Removing directory` / `vfs cache: removed cache file`).
   - When a deletion is detected, it spawns a background worker (`console_folder_cleanup_worker.ps1`) to run `gcloud storage rm` and `gcloud storage folders delete` on the empty folder records and recursively prune empty parent folders.
2. **Root Folder Reconciler (`console_folder_root_reconcile_scheduler.ps1`)**:
   - Runs every 15 seconds in the background.
   - Compares the top-level folders visible in Windows File Explorer against top-level folders reported by `gcloud storage ls gs://<bucket>/`.
   - If a root folder is present in the Cloud Console but absent from the mounted drive, it verifies whether cloud objects exist; if the folder is empty, it prunes the Console record.

### Manual Folder Repair (Admin Variant)
In `gcs_mount_admin.ps1`, the **Refresh Folder** workflow handles the reverse scenario (where folders exist in the Cloud Console but are missing from Windows File Explorer):
1. Flushes the rclone directory cache using the Remote Control API (`vfs/forget` and `vfs/refresh`).
2. Prompts the admin to select a parent folder on the mounted drive via a folder picker.
3. Scans GCS using `gcloud storage ls` and compares it against local subdirectories.
4. If missing folders are found, presents a selection dialog with checkboxes for each missing folder.
5. For selected folders, calls `Repair-GcsFolderMarkers`, which uses `rclone mkdir` with compatibility flags (`--gcs-bucket-policy-only --gcs-directory-markers --gcs-object-acl=`) to create zero-byte directory markers.
6. Refreshes the rclone directory cache so the newly marked folders immediately appear in Windows File Explorer.

---

## Prerequisites & System Requirements

1. **Operating System**: Windows 10 / Windows 11 / Windows Server with **Windows PowerShell 5.1**.
2. **WinFsp**: Required for mounting drives in Windows. [Download WinFsp](https://winfsp.dev/).
3. **rclone**: Version 1.58+ recommended. [Download rclone](https://rclone.org/).
4. **Google Cloud CLI (`gcloud`)**: Required for Console folder cleanup and scanning. [Install gcloud CLI](https://cloud.google.com/sdk/docs/install).
5. **Permissions**: Google account credentials with Storage Object Admin / Storage Folder Admin permissions on the target GCS buckets.

---

## Usage & Execution

### Interactive Mode
Run the standard user script:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount.ps1
```

### Auto-Mount Mode
Starts the application in background/hidden mode. It waits 20 seconds for network services to stabilize, mounts all profiles marked with `AutoMount: true`, and sits in the system tray:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount.ps1 -AutoMount
```

### Admin Mode
Run the administrative maintenance script:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount_admin.ps1
```

---

## First-Time Setup Guide

1. **Launch the Application**: Run `gcs_mount.ps1` (or the compiled `.exe`).
2. **Configure Global Settings**:
   - Click **Settings** in the bottom-left corner.
   - If `rclone.exe` or `WinFsp` are not in your system `PATH`, specify their folder paths.
   - Choose a **Cache Directory** on a drive with ample disk space (e.g., `C:\RcloneCache` or `D:\RcloneCache`).
   - Click **Save Settings**.
3. **Authenticate with Google Cloud**:
   - Click **Sign In to Google Cloud**.
   - A browser window will open. Select your Google account and grant the requested permissions.
   - Once complete, the status text will turn green and display `[OK] Signed in as: <email>`.
4. **Configure a Mount Profile**:
   - Enter your **Project ID** (e.g., `my-gcp-project-12345`).
   - Click **Fetch Buckets** to populate the dropdown, or type the bucket name manually.
   - Select an available **Drive Letter** (e.g., `Z:`).
   - (Optional) Check **Auto-mount this drive at Windows login**.
   - Click **Save and Mount**.
5. **Verify**: Open Windows File Explorer. Your selected drive letter will appear with the bucket name as the volume label.

---

## Configuration & Performance Tuning

### Global Settings (`settings_multi.json`)
Settings and profiles are stored in `%APPDATA%\GCSMountApp\settings_multi.json`:

```json
{
  "Global": {
    "RclonePath": "",
    "WinFspPath": "",
    "CacheDir": "C:\\RcloneCache",
    "CacheMaxSize": "20",
    "CacheMaxAge": "1",
    "TransferCount": "8",
    "CheckerCount": "16",
    "BufferSizeMb": "64",
    "ReadAheadMb": "256",
    "MultiThreadStreams": "4",
    "ChunkSizeMb": "64"
  },
  "Mounts": [
    {
      "Id": "d3b07384-d113-496e-82d2-8b6529367de8",
      "BucketName": "my-sample-bucket",
      "ProjectId": "my-gcp-project",
      "DriveLetter": "Z:",
      "AutoMount": true
    }
  ]
}
```

### Transfer & Cache Performance Options

| Setting | Default | Recommended Range | Description |
| :--- | :--- | :--- | :--- |
| **Cache Directory** | `C:\RcloneCache` | Fast SSD | Local disk folder where rclone stores cached files during reads and writes. |
| **Max Cache Storage Size (GB)** | `20` | `10` – `500`+ | Maximum disk space used by the VFS cache before older cached items are evicted. |
| **Cache TTL (Hours)** | `1` | `1` – `24` | Time-To-Live for inactive cached files before deletion from local disk. |
| **Parallel Transfers** | `8` | `4` – `32` | Number of simultaneous file transfers rclone can perform concurrently (`--transfers`). |
| **Metadata Checkers** | `16` | `8` – `64` | Number of parallel threads used for directory scans and metadata checks (`--checkers`). |
| **Buffer per Open File (MB)** | `64` | `16` – `256` | RAM buffer allocated per open file stream (`--buffer-size`). Improves streaming speed. |
| **VFS Read Ahead (MB)** | `256` | `64` – `1024` | Sequential read-ahead buffer for VFS cache (`--vfs-read-ahead`). Speeds up large sequential reads. |
| **Multi-thread Streams** | `4` | `2` – `16` | Number of parallel TCP streams used for downloading large files (`--multi-thread-streams`). |
| **Read Chunk Size (MB)** | `64` | `16` – `128` | Chunk size used for chunked VFS and multi-thread reads (`--vfs-read-chunk-size`). |

---

## Packaging as Standalone Executables (`.exe`)

You can compile the scripts into standalone `.exe` binaries using `ps2exe` / `Invoke-ps2exe`:

### Standard Tool (`GCS_Manager.exe`)
```powershell
Invoke-ps2exe `
    -inputFile .\gcs_mount.ps1 `
    -outputFile .\dist\GCS_Manager.exe `
    -noConsole `
    -STA `
    -title 'GCS Bucket Mounting Tool' `
    -description 'GCS Bucket Mounting Tool' `
    -product 'GCS Bucket Mounting Tool' `
    -version '2.0.0.0'
```

### Admin / Maintenance Tool (`GCS_Manager_Admin.exe`)
```powershell
Invoke-ps2exe `
    -inputFile .\gcs_mount_admin.ps1 `
    -outputFile .\dist\GCS_Manager_Admin.exe `
    -noConsole `
    -STA `
    -title 'GCS Bucket Mounting Tool Admin' `
    -description 'GCS Bucket Mounting Tool Admin' `
    -product 'GCS Bucket Mounting Tool' `
    -version '2.0.0.0'
```

---

## Runtime Files & Directory Structure

All application configuration and runtime artifacts reside under `%APPDATA%\GCSMountApp`:

```text
%APPDATA%\GCSMountApp\
├── settings_multi.json                       # Saved global settings and mount configurations
├── rclone.log                               # Main application log and folder cleanup audit log
├── rclone_<DRIVE>.log                       # Per-drive rclone mount logs (e.g., rclone_Z.log)
├── auth_debug.log                           # Authentication debug log (created during sign-in)
├── console_folder_cleanup_worker.ps1        # Auto-generated helper script for folder delete operations
└── console_folder_root_reconcile_scheduler.ps1 # Auto-generated background scheduler for root folder reconciliation
```

---

## Troubleshooting & Diagnostics

- **Browser does not open during authentication**:
  - The tool includes an automatic "Zombie Killer" to terminate stuck `rclone config` processes holding port `53682`.
  - If issues persist, check `%APPDATA%\GCSMountApp\auth_debug.log` or manually verify no other service is binding port `53682`.
- **Drive does not mount or letters are missing**:
  - Verify that **WinFsp** is installed and running.
  - Verify that the target drive letter is not mapped as a network share (`net use`) or virtual drive (`subst`).
- **Fetch Buckets fails**:
  - Ensure you have entered a valid Google Cloud **Project ID**.
  - Verify your Google Cloud account has `storage.buckets.list` permissions in that project.
- **Empty folders created in Google Cloud Console do not appear in File Explorer**:
  - Use `gcs_mount_admin.ps1`, click **Refresh Folder**, select the parent folder, and apply the repair markers.
- **Recently deleted empty folder still shows in Cloud Console**:
  - The background reconciliation runs every 15 seconds. Wait a few moments, then refresh the Google Cloud Console web page.
  - Check `%APPDATA%\GCSMountApp\rclone.log` to view folder cleanup activity.
- **High Disk or Memory Usage**:
  - Open **Settings** and reduce `Max Cache Storage Size (GB)`, `Buffer per Open File (MB)`, or `Read Chunk Size (MB)`.

