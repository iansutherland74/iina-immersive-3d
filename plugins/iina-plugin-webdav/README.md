# WebDAV browser

A standalone IINA plugin. It is not part of the player binary. It lists a WebDAV folder with `PROPFIND` and plays a video through the normal player, so Immersive 3D and Play on Glasses apply the same way they do for any other URL.

## Install

The macOS Release workflow uploads `iina-plugin-webdav-1.0.0.iinaplgz`.

1. Download that artifact from the workflow run.
2. In IINA, open **Settings → Plugins**.
3. Choose **Install Local Package…** and pick the `.iinaplgz` file.
4. Allow the network permission. The plugin has to reach whatever host you type, so its domain list is `*`.

**Get Plugins…** installs a GitHub repository whose root contains `Info.json`, or a repository whose latest release contains an `.iinaplgz`. This plugin lives in `plugins/iina-plugin-webdav` inside the player repository, so that GitHub install does not see it. Use the package file.

Playback needs an IINA build that provides `iina.http.request`. The helpers `get` and `post` cannot send `PROPFIND`. That method is in this fork.

## Connect

Open a video window, then **Plugins → WebDAV Browser**, or the **WebDAV** sidebar tab.

- **FebBox.** Server address `https://webdav.febbox.com`. Create the WebDAV account in the FebBox console first. If that page shows an effective path, add it to the end of the address.
- **Nextcloud.** `https://host/remote.php/dav/files/USERNAME/` and an app password.
- **NAS.** The WebDAV root the vendor documents, including the port. `http://` is accepted for a machine on the local network. The sidebar says so, because the password is then unencrypted on that network.

The username and the server address are plugin preferences. The password is written to the macOS Keychain (service `io.iina.webdav - webdav`, account equal to the username) through `iina.utils.keychainWrite`. If that write fails, the sidebar says the password could not be saved. It is kept in memory until IINA quits and it is not written into the preference file.

## What a click does

Folders open with another `PROPFIND` of depth 1. Files that are not videos are left out. A video is an ordinary extension (`mkv`, `mp4`, `m4v`, `mov`, and the other names in `main.js`) or a `video/*` content type.

Play sends the file's `https` or `http` URL to `iina.core.open` with no user and no password in the address. Before that, the plugin sets mpv `http-header-fields` to `Authorization: Basic …`. The header stays while that server is playing, including a reconnect, and is put back when the next file is on a different host. The first request of that next network file can still carry the header if mpv has already started it before the plugin sees the change.

The plugin does not log the password or the media URL.

This was not run against FebBox, Nextcloud, or a NAS. The folder parser was checked locally against sample WebDAV XML. No password was sent anywhere.
