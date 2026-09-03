# Rclone Drive Sync

A bar widget for Omarchy Quattro that lists a configured [rclone](https://rclone.org/) remote, selectively downloads files, and synchronizes selected items with Google Drive. It does not create a FUSE mount: selected files are stored in `~/DriveSync`.

## Features

- Lists files and folders from an rclone remote in the Omarchy bar.
- Downloads selected files or folders to `~/DriveSync`.
- Removes only the local copy when an item is unselected.
- Runs selective two-way synchronization with `rclone bisync`.
- Shows download progress, speed, ETA, and queued downloads.

## Requirements

- Omarchy Quattro.
- `rclone` available on `PATH`.
- `bash`, `python3`, and `notify-send` (provided by a standard Omarchy install).
- A configured rclone remote. Google Drive setup is documented below.

Install rclone on Arch Linux:

```sh
sudo pacman -S rclone
rclone version
```

## Install

Install and enable the plugin with Omarchy. Replace `<repository-url>` with this plugin's public Git repository URL:

```sh
omarchy plugin add <repository-url> --enable
```

For example, after publishing the repository to GitHub:

```sh
omarchy plugin add https://github.com/<owner>/<repository>.git --enable
```

Omarchy clones the plugin, discovers it, enables it, and adds the bar widget. Confirm its state with:

```sh
omarchy plugin list --json
```

## Configure the widget

The plugin uses the `remoteName` configured in the bar entry. The default is `gdrive`. To use another remote, update the plugin entry in `~/.config/omarchy/shell.json` and reload the shell:

```json
{
  "id": "m4teo.rclone-drive",
  "remoteName": "gdrive",
  "pollIntervalSec": 60,
  "notificationsEnabled": true
}
```

Use an interval of at least 60 seconds to avoid Google Drive API rate limits. Saved plugin changes are normally reloaded automatically; otherwise run:

```sh
omarchy restart shell
```

## Google Drive connection

### Create an OAuth client

Google is retiring rclone's shared Google Drive `client_id` during 2026. Use your own OAuth client to avoid outages and shared API quotas.

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create or select a project.
2. Enable **Google Drive API**.
3. Under **Google Auth platform**, complete consent-screen setup if requested. When the app is in testing mode, add your Google account under **Audience → Test users**.
4. Under **Google Auth platform → Clients**, create an OAuth client of type **Desktop app**.
5. Keep the generated Client ID and Client secret private.

See rclone's official [Google Drive client ID guide](https://rclone.org/drive/#making-your-own-client-id) for current screenshots and details.

### Configure rclone

Create or edit a remote:

```sh
rclone config
```

Create a new remote (`n`) named `gdrive`, or edit the existing `gdrive` remote (`e`). Use these answers:

| Prompt | Answer |
| --- | --- |
| Storage | `drive` |
| `client_id` | Your OAuth Client ID |
| `client_secret` | Your OAuth Client secret |
| `scope` | `1` (`drive`) |
| `service_account_file` | Press Enter |
| Edit advanced config? | `n` |
| Replace existing token? | `y` |
| Use web browser to authenticate? | `y` |
| Configure as a Shared Drive? | `n`, unless you use a Google Workspace Shared Drive |

Complete authorization in the browser, save the remote, and verify it:

```sh
rclone lsf gdrive:
echo $?
```

The command should list files and exit with `0`.

> Never publish your Client secret, OAuth token, refresh token, or `~/.config/rclone/rclone.conf`.

## Usage

- Left-click the bar icon to open the panel.
- Select an item to download it to `~/DriveSync`.
- Click the trash icon to remove its local copy while preserving the Drive file.
- Click **Sync** to run `rclone bisync` for selected items.
- Right-click the bar icon, or press **R** in the panel, to refresh the list.

Plugin state, filters, and logs are stored in `~/.config/m4teo-rclone-drive/`.

## Update

Update the installed Git-managed plugin with Omarchy:

```sh
omarchy plugin update m4teo.rclone-drive
```

Add `--yes` to skip the confirmation prompt:

```sh
omarchy plugin update m4teo.rclone-drive --yes
```

## Remove

Remove the plugin through Omarchy:

```sh
omarchy plugin remove m4teo.rclone-drive
```

Add `--yes` to skip confirmation:

```sh
omarchy plugin remove m4teo.rclone-drive --yes
```

Optionally remove local plugin state after uninstalling:

```sh
rm -rf ~/.config/m4teo-rclone-drive
```

This does not delete Google Drive files or the configured rclone remote.

## License

This project is licensed under the [MIT License](LICENSE).
