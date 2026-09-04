# GCS Bucket Mounting Tool

A Windows PowerShell WPF desktop application suite for mounting Google Cloud Storage (GCS) buckets as local Windows drive letters. It wraps `rclone`, WinFsp, and the Google Cloud CLI (`gcloud`) into an intuitive graphical interface that handles authentication, multi-bucket profile management, drive connection/disconnection, performance tuning, and automated folder lifecycle synchronization.

The repository provides both source PowerShell scripts and pre-packaged Windows executables:
- **`GCS_Mounting_Tool.exe`**: The standalone, pre-compiled Windows executable built from `gcs_mount.ps1`. Can be run directly without PowerShell execution policy configuration.
- **`gcs_mount.ps1`**: The standard user-facing PowerShell source script for everyday mounting, auto-mounting, and automated background folder cleanup.
- **`gcs_mount_admin.ps1`**: The administrative/maintenance PowerShell script that includes an interactive **Refresh Folder** utility to diagnose and repair folder visibility mismatches between Google Cloud Console and Windows File Explorer.
- **`network_drive.ico`**: The application icon embedded in packaged executables.

---

## Table of Contents

- [Overview & Architecture](#overview--architecture)
- [Key Features](#key-features)
- [Script & Executable Comparison](#script--executable-comparison)
- [Quick Start with `GCS_Mounting_Tool.exe`](#quick-start-with-gcs_mounting_toolexe)
- [How Folder Synchronization & Repair Works](#how-folder-synchronization--repair-works)
  - [Background Delete Cleanup & Root Reconciliation](#background-delete-cleanup--root-reconciliation)
  - [Manual Folder Repair (Admin Variant)](#manual-folder-repair-admin-variant)
- [Prerequisites & System Requirements](#prerequisites--system-requirements)
- [Usage & Execution](#usage--execution)
  - [Running the Packaged Executable (`GCS_Mounting_Tool.exe`)](#running-the-packaged-executable-gcs_mounting_toolexe)
  - [Running from PowerShell (`gcs_mount.ps1` / `gcs_mount_admin.ps1`)](#running-from-powershell-gcs_mountps1--gcs_mount_adminps1)
  - [Auto-Mount Mode (Background Startup)](#auto-mount-mode-background-startup)
- [First-Time Setup Guide](#first-time-setup-guide)
- [Packaging PowerShell Scripts to Standalone Executables (`.exe`)](#packaging-powershell-scripts-to-standalone-executables-exe)
  - [Step 1: Install `ps2exe`](#step-1-install-ps2exe)
  - [Step 2: Parameter Reference](#step-2-parameter-reference)
  - [Step 3: Build Commands](#step-3-build-commands)
- [Configuration & Performance Tuning](#configuration--performance-tuning)
  - [Global Settings (`settings_multi.json`)](#global-settings-settings_multijson)
  - [Transfer & Cache Performance Options](#transfer--cache-performance-options)
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
│        (GCS_Mounting_Tool.exe / gcs_mount.ps1 / admin)           │
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

- **Pre-Compiled Standalone Binary**: Includes `GCS_Mounting_Tool.exe` for immediate execution without needing PowerShell script execution permissions.
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

## Script & Executable Comparison

| Feature / Aspect | `GCS_Mounting_Tool.exe` / `gcs_mount.ps1` (Standard) | `gcs_mount_admin.ps1` (Admin / Maintenance) |
| :--- | :--- | :--- |
| **Target Audience** | General end users, everyday workstations | System administrators, power users, support staff |
| **Primary Use Case** | Daily mounting, browsing, and auto-mounting GCS buckets | Troubleshooting, bucket maintenance, and folder repair |
| **UI Layout** | Clean sidebar with `Connect Drive`, `Disconnect Drive`, and `Settings` | Includes an extra **`Refresh Folder`** button (`#3B82F6`) in the sidebar |
| **Folder Visibility Repair** | Fully automated background cleanup only | Automated background cleanup **plus** interactive manual scanning and repair modal |
| **VFS Cache Invalidation** | Automatic on mount/unmount | On-demand via `Refresh-MountDirectoryCache` (using rclone Remote Control API) |
| **Marker Generation** | Automatic upon standard file/folder operations | Manual recursive batch generation for selected Cloud Console folders |
| **Packaged Binary** | `GCS_Mounting_Tool.exe` | `GCS_Mounting_Tool_Admin.exe` |

---

## Quick Start with `GCS_Mounting_Tool.exe`

If you are using the pre-compiled `GCS_Mounting_Tool.exe`, you can start using it immediately without configuring PowerShell execution policies:

1. Double-click **`GCS_Mounting_Tool.exe`** in Windows File Explorer (or run `.\GCS_Mounting_Tool.exe` in terminal).
2. Follow the [First-Time Setup Guide](#first-time-setup-guide) to configure settings and authenticate.
3. The executable runs as a native windowed GUI application without a background console window and embeds the `network_drive.ico` icon.

---

## How Folder Synchronization & Repair Works

### The Empty Folder Challenge in GCS
Google Cloud Storage buckets (especially with Hierarchical Namespace enabled) manage folders differently than Windows:
- **Cloud Console Folders**: Folders created via the web console often exist purely as Cloud Console folder metadata records without any underlying file objects.
- **rclone Requirement**: `rclone` requires either a real file inside a folder or a zero-byte directory marker object (e.g., `folder/`) to present the folder in Windows File Explorer.
- **Deleted Folder Lingering**: When a user deletes a folder from Windows File Explorer, Windows/rclone removes the local cached representation, but the GCS Cloud Console folder record may remain visible on the web.

### Background Delete Cleanup & Root Reconciliation
Both scripts/binaries implement automated background synchronization:
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

1. **Operating System**: Windows 10 / Windows 11 / Windows Server with .NET Framework 4.5+ (and **Windows PowerShell 5.1** if running scripts).
2. **WinFsp**: Required for mounting drives in Windows. [Download WinFsp](https://winfsp.dev/).
3. **rclone**: Version 1.58+ recommended. [Download rclone](https://rclone.org/).
4. **Google Cloud CLI (`gcloud`)**: Required for Console folder cleanup and scanning. [Install gcloud CLI](https://cloud.google.com/sdk/docs/install).
5. **Permissions**: Google account credentials with Storage Object Admin / Storage Folder Admin permissions on the target GCS buckets.

---

## Usage & Execution

### Running the Packaged Executable (`GCS_Mounting_Tool.exe`)

- **Interactive GUI**:
  ```cmd
  GCS_Mounting_Tool.exe
  ```
- **Auto-Mount Mode (Starts hidden to system tray)**:
  ```cmd
  GCS_Mounting_Tool.exe -AutoMount
  ```

### Running from PowerShell (`gcs_mount.ps1` / `gcs_mount_admin.ps1`)

- **Standard User Script**:
  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount.ps1
  ```
- **Admin Maintenance Script**:
  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File .\gcs_mount_admin.ps1
  ```

### Auto-Mount Mode (Background Startup)

When `-AutoMount` is specified:
1. The app initializes silently and hides its main window.
2. It waits 20 seconds for Windows networking, network adapters, and security credentials to initialize.
3. Mounts all profiles where `AutoMount: true` is saved in `settings_multi.json`.
4. Resides in the Windows system tray. Users can double-click the tray icon to open the full UI.

The app automatically registers this parameter in your Windows Startup directory when auto-mount is enabled for any profile.

---

## First-Time Setup Guide

1. **Launch the Application**: Run `GCS_Mounting_Tool.exe` (or `gcs_mount.ps1`).
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

## Packaging PowerShell Scripts to Standalone Executables (`.exe`)

You can convert any `.ps1` script in this repository into a standalone Windows `.exe` executable using the `ps2exe` PowerShell module. This bundles the script into a native Windows executable that runs without opening a console window and embeds file metadata and icons.

### Step 1: Install `ps2exe`

Open Windows PowerShell and install `ps2exe` from the PowerShell Gallery (run once):

```powershell
Install-Module -Name ps2exe -Scope CurrentUser -Force
```

### Step 2: Parameter Reference

When compiling GUI PowerShell applications with `Invoke-ps2exe`, the following parameters are critical:

| Parameter | Value | Purpose |
| :--- | :--- | :--- |
| `-inputFile` | `.\gcs_mount.ps1` | The source PowerShell script to bundle. |
| `-outputFile` | `.\GCS_Mounting_Tool.exe` | The destination `.exe` binary path. |
| `-iconFile` | `.\network_drive.ico` | Embeds the application icon into the compiled `.exe`. |
| `-noConsole` | Switch | **Mandatory for WPF/GUI apps**. Suppresses the black Windows console/command prompt window on launch. |
| `-STA` | Switch | **Mandatory for WPF & WinForms**. Forces the executable to run in Single-Threaded Apartment mode required by UI components. |
| `-title` | String | Sets the application title in Windows file properties. |
| `-description` | String | Sets the file description in Windows file properties. |
| `-product` | String | Sets the product name in Windows file properties. |
| `-version` | String | Version number (e.g., `2.0.0.0`). |

### Step 3: Build Commands

#### 1. Compile Standard User Tool (`GCS_Mounting_Tool.exe`)

```powershell
Invoke-ps2exe `
    -inputFile .\gcs_mount.ps1 `
    -outputFile .\GCS_Mounting_Tool.exe `
    -iconFile .\network_drive.ico `
    -noConsole `
    -STA `
    -title 'GCS Bucket Mounting Tool' `
    -description 'Google Cloud Storage Drive Mount Tool' `
    -product 'GCS Bucket Mounting Tool' `
    -version '2.0.0.0'
```

#### 2. Compile Admin / Maintenance Tool (`GCS_Mounting_Tool_Admin.exe`)

```powershell
Invoke-ps2exe `
    -inputFile .\gcs_mount_admin.ps1 `
    -outputFile .\GCS_Mounting_Tool_Admin.exe `
    -iconFile .\network_drive.ico `
    -noConsole `
    -STA `
    -title 'GCS Bucket Mounting Tool Admin' `
    -description 'Google Cloud Storage Drive Mount Tool (Admin Maintenance)' `
    -product 'GCS Bucket Mounting Tool' `
    -version '2.0.0.0'
```

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
  - Use `gcs_mount_admin.ps1` (or `GCS_Mounting_Tool_Admin.exe`), click **Refresh Folder**, select the parent folder, and apply the repair markers.
- **Recently deleted empty folder still shows in Cloud Console**:
  - The background reconciliation runs every 15 seconds. Wait a few moments, then refresh the Google Cloud Console web page.
  - Check `%APPDATA%\GCSMountApp\rclone.log` to view folder cleanup activity.
- **High Disk or Memory Usage**:
  - Open **Settings** and reduce `Max Cache Storage Size (GB)`, `Buffer per Open File (MB)`, or `Read Chunk Size (MB)`.

