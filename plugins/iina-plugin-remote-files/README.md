# Remote files

A standalone IINA plugin for a saved list of WebDAV, FTP, and FTPS servers. It is not part of the player binary. Playback uses the normal player, so Immersive 3D and Play on Glasses apply.

## Install

The macOS Release workflow uploads `iina-plugin-remote-files-1.0.0.iinaplgz`.

1. Download that artifact.
2. **Settings → Plugins → Install Local Package…** and choose the file.
3. Allow network access and file-system access. Network access is any host, because the address is typed later. File-system access is how the plugin runs `/usr/bin/curl` to list FTP and how it asks mpv to open an `ftp://` URL and add a subtitle. The password is not a reason for that permission.

**Get Plugins…** installs a GitHub repository whose root contains `Info.json`. This plugin lives in `plugins/iina-plugin-remote-files`, so use the package file.

The plugin needs `iina.http.request` for `PROPFIND`. `iina.http.get` and `post` cannot send that method.

## Servers

**Plugins → Remote Files**, or the Remote sidebar tab.

- **WebDAV.** `https://webdav.febbox.com` for FebBox (create the WebDAV account in the FebBox console, and add the effective path if one is shown). Nextcloud is `https://host/remote.php/dav/files/USERNAME/`.
- **FTP.** A host, or `ftp://host/path`.
- **FTPS.** Explicit TLS on port 21 unless the address uses port 990 or starts with `ftps://`, which is listed as implicit FTPS. **Allow insecure TLS for FTP** turns on curl `-k` and mpv `tls-verify=no`. WebDAV still checks the certificate. The checkbox is hidden for WebDAV.

The server list stores the name, protocol, address, and username. The password goes to the Keychain (`io.iina.remote-files - remote-files`, account equal to the server id) through `iina.utils.keychainWrite`. If that fails, the sidebar says so. The password stays in memory until IINA quits and is not written into the server list. Leaving the password blank while editing keeps the saved one. An address pasted as `user:password@host` has that password removed before the address is saved; it is stored with the other passwords. Removing a server removes it from the list; the Keychain item is left in place. A failed save leaves the form as it was.

An `http://` WebDAV address shows a warning because the password is then unencrypted on the network. FTP is unencrypted by nature.

## Playback and subtitles

Folders and videos are shown. Other files are hidden, including subtitles.

A subtitle in the same folder is loaded when its name matches the video: `Movie.srt`, `Movie.en.ass`, `Movie.vtt`, or `Movie.ssa`. `Showdown.srt` is not loaded for `Show.mkv`. The match is passed to mpv `sub-add` after the file has loaded, so opening the video does not clear it. The first match is selected. The rest are added and not selected.

WebDAV play opens the file URL with no user and no password, and sets mpv `http-header-fields` to `Authorization: Basic …`. The header stays while that host is playing and is restored when another host starts. The debug log hides the header value.

FTP play calls mpv `loadfile` with `ftp://user:password@host/path`. Explicit FTPS uses that same `ftp://` URL and sets mpv `stream-lavf-o` to `tls=1` for the ffmpeg FTP client. Implicit FTPS uses `ftps://`. The user and password are percent-encoded. `iina.core.open` would encode the `@` on macOS 13 and point the URL at the wrong host, so it is not used for FTP. The command log drops `user:password@`. The URL mpv is playing still contains the password, so history can too. Play the file from the sidebar again later; history will not refresh the password.

FTP listings write the password into a curl config in the plugin temp directory and write the listing to a second temp file. Both are deleted when curl finishes. The curl command line is the host and the path, not the password. A username or password that contains a line break is refused, because that would break the config file.

This was not run against FebBox, Nextcloud, or an FTP server. No password was sent. The listing and subtitle-name checks were run locally. FTPS playback through mpv was not tried. More protocols are not implemented; this plugin is the place to add them later.
