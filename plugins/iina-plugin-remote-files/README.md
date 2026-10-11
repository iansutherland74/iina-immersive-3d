# Remote files

A standalone IINA plugin. It is not part of the player binary. One sidebar holds WebDAV, FTP, FTPS, SMB, SFTP, Jellyfin, Emby, Plex, and DLNA. Playback uses the normal player, so Immersive 3D and Play on Glasses apply.

## Install

The macOS Release workflow uploads `iina-plugin-remote-files-1.1.0.iinaplgz`.

1. Download that artifact.
2. **Settings → Plugins → Install Local Package…** and choose the file.
3. Allow network access and file-system access. Network access is any host, because the address is typed later. File-system access is how the plugin runs `/usr/bin/curl`, `/usr/bin/sftp`, `/sbin/mount_smbfs`, `/usr/bin/dns-sd`, and `/usr/bin/perl`, and how it asks mpv to open an `ftp://` or `sftp://` URL and add a subtitle. The password is not a reason for that permission.

**Get Plugins…** installs a GitHub repository whose root contains `Info.json`. This plugin lives in `plugins/iina-plugin-remote-files`, so use the package file.

The plugin needs `iina.http.request` for `PROPFIND`, Jellyfin, Emby, Plex, and DLNA. `iina.http.get` and `post` cannot send those methods. IINA's `utils.exec` starts each helper with an environment that only sets `LC_ALL`. The helper scripts set `PATH` themselves.

## Servers

**Plugins → Remote Files**, or the Remote sidebar tab.

- **WebDAV.** `https://webdav.febbox.com` for FebBox (create the WebDAV account in the FebBox console, and add the effective path if one is shown). Nextcloud is `https://host/remote.php/dav/files/USERNAME/`.
- **FTP.** A host, or `ftp://host/path`.
- **FTPS.** Explicit TLS on port 21 unless the address uses port 990 or starts with `ftps://`, which is listed as implicit FTPS. **Allow insecure TLS for FTP** turns on curl `-k` and mpv `tls-verify=no`. The checkbox is hidden for every other protocol. WebDAV, Jellyfin, Emby, Plex, and DLNA still check the certificate.
- **SMB.** `smb://host/Share` or `smb://host/Share/folder`. The share name is required. A discovered host is only `smb://host`; type the share before saving. Guest access is not offered.
- **SFTP.** A host, `host:port/path`, or `sftp://host/path`. Password authentication only. Public-key login is turned off in the temporary SSH config.
- **Jellyfin and Emby.** The server root, such as `http://host:8096` or `https://host:8920`. Emby uses the same `AuthenticateByName` and `X-Emby-Token` calls. If your Emby install lives under `/emby`, put that in the address.
- **Plex.** The server root, such as `http://host:32400`. Leave the username blank and put an `X-Plex-Token` in the password field, or enter a plex.tv username and password. The sign-in call is `POST https://plex.tv/users/sign_in.json`.
- **DLNA.** The device description URL, usually the `LOCATION` from discovery (`http://host:8200/desc.xml`). Username and password are optional and are not sent.

The server list stores the name, protocol, address, and username. The password goes to the Keychain (`remote-files`, account equal to the server id) through `iina.utils.keychainWrite`. If that fails, the sidebar says so. The password stays in memory until IINA quits and is not written into the server list. Leaving the password blank while editing keeps the saved one. An address pasted as `user:password@host` has that password removed before the address is saved; it is stored with the other passwords. Removing a server removes it from the list; the Keychain item is left in place. A failed save leaves the form as it was.

An `http://` address for WebDAV, Jellyfin, Emby, Plex, or DLNA shows a warning because the password or token is then unencrypted on the network. FTP is unencrypted by nature. SMB and SFTP are not marked with that warning.

## Discovery

**Discover** runs two helpers for a few seconds.

- `/usr/bin/dns-sd -B` browses `_plexmediasvr._tcp`, `_jellyfin._tcp`, `_emby._tcp`, `_smb._tcp`, and `_sftp-ssh._tcp` on `local.` for 4 seconds. Up to 8 answers are resolved with `dns-sd -L` for 2 seconds each.
- `/usr/bin/perl` sends an SSDP `M-SEARCH` for `urn:schemas-upnp-org:device:MediaServer:1` to `239.255.255.250:1900` and waits 3 seconds. A reply's `LOCATION` is a DLNA description URL.

Choosing a row fills the form. It does not save the server and it does not know the password or the SMB share name. WebDAV and FTP are not discovered. Nothing is contacted outside the local network by this button, except that a later Plex sign-in uses plex.tv.

## Browsing, search, and sort

Folders and videos are shown. Subtitle files stay in the listing data and are hidden in the sidebar. Other files are dropped.

The search box filters the current folder by name. It does not ask the server to search the library. Sort is **Name**, **Date**, or **Size**. Name order is natural, so Episode 2 comes before Episode 10. Date and size put the newest or largest first, then fall back to that name order. Folders stay above files. The choice is remembered.

Jellyfin, Emby, and DLNA request 200 children of the open folder. There is no next page. Plex shows what `/library/sections` and `/library/metadata/…/children` return; this plugin does not add a page size. SMB and SFTP listings are parsed as UNIX `ls -l` (English month names). A server whose `ls` is not that shape can come back empty. A symlink is listed as a file, using the link name, so a video symlink can be played and a directory symlink is not opened as a folder.

## Playback

WebDAV play opens the file URL with no user and no password, and sets mpv `http-header-fields` to `Authorization: Basic …`. The header stays while that host is playing and is restored when another host starts. The debug log hides the header value.

FTP play calls mpv `loadfile` with `ftp://user:password@host/path`. Explicit FTPS uses that same `ftp://` URL and sets mpv `stream-lavf-o` to `tls=1` for the ffmpeg FTP client. Implicit FTPS uses `ftps://`. The user and password are percent-encoded. `iina.core.open` would encode the `@` on macOS 13 and point the URL at the wrong host, so it is not used for FTP or SFTP. The command log drops `user:password@`. The URL mpv is playing still contains the password, so history can too. Play the file from the sidebar again later; history will not refresh the password.

SFTP play is the same `loadfile` path with `sftp://user:password@host/path`. Listing is separate: `/usr/bin/sftp -b` runs a batch file, and the password is printed by an `SSH_ASKPASS` script with `SSH_ASKPASS_REQUIRE=force`. The password is in that script file, not in the `sftp` arguments. The script is deleted when `sftp` returns. The first connection to a host accepts the key (`StrictHostKeyChecking accept-new`) into `@tmp/sftp-home`. Later connections in that temp folder check the saved key. If the temp folder is cleared, the next connection accepts the key again. A host whose key changes while the temp folder still has the old key is refused.

SMB listing writes a short script that runs `/sbin/mount_smbfs -N` and mounts the share on `@tmp/smb-mnt`, then `/bin/ls -l` reads it. The password is percent-encoded inside the script. `mount_smbfs` still receives the URL as an argument, so `ps` can show it while the mount is starting. The script is deleted when that command returns. Playback opens the local mount path with `iina.core.open`, so the playing URL has no password. One share is mounted at a time. Opening another SMB server unmounts the previous one, which stops a file that was playing from it. Closing the player window runs `/sbin/umount`.

Jellyfin and Emby play `/Videos/{id}/stream?Static=true` and set `X-Emby-Token`. The token is not put in the stream URL. Plex plays the file part path from the metadata and sets `X-Plex-Token`. DLNA plays the `res` URL from the listing with `iina.core.open`. A DLNA URL that is not `http` or `https` is refused. A transcode URL that the server expires is not refreshed.

Posters for Jellyfin, Emby, and Plex are the image URL with the access token in the query (`api_key` or `X-Plex-Token`). The sidebar loads that URL, so the token is in the image request. The stream URL does not carry it.

## Resume, history, and favourites

Position is read from mpv about every 5 seconds and again when the file unloads. It is stored in the plugin preferences under `resume`, keyed by server id and path. A position under 5 seconds is ignored. A position within 30 seconds of the end, or at 95% or more, is ignored. Otherwise the next play seeks there after the file has loaded. The row shows that fraction as a bar.

Jellyfin and Emby also send `PlaybackPositionTicks` to `/Sessions/Playing/Progress` about every 15 seconds, and `/Sessions/Playing/Stopped` when the file unloads. Plex sends `/:/progress` with `time` in milliseconds. If this plugin has no local position, it uses the server's `UserData.PlaybackPositionTicks` or Plex `viewOffset`. WebDAV, FTP, SFTP, SMB, and DLNA are local only.

History keeps the last 40 plays, newest first, in plugin preferences. Favourites are a separate list. **History** and **Favourites** on the server page reopen that server's folder and play the row. A removed server stays in the list as "Removed server" and does not play.

## Subtitles

A subtitle in the same folder is loaded when its name matches the video: `Movie.srt`, `Movie.en.ass`, `Movie.vtt`, or `Movie.ssa`. `Showdown.srt` is not loaded for `Show.mkv`. The match is passed to mpv `sub-add` after the file has loaded, so opening the video does not clear it. The first match is selected. The rest are added and not selected. This works for WebDAV, FTP, FTPS, SFTP, SMB (the mounted file), and a DLNA item whose listing included the subtitle. Jellyfin, Emby, and Plex library rows do not include sidecar subtitle files, so this match does not run there.

If nothing matched, and an OpenSubtitles API key is saved, the plugin searches `https://api.opensubtitles.com/api/v1/subtitles?query=` with the video's file name. The key is sent as `Api-Key` and stored in the Keychain under the account `opensubtitles`. The download picks a file whose name contains the video stem, otherwise the first file in the response. It is saved under the plugin temp directory and added with `sub-add`. There is no file hash, no language picker, and no OpenSubtitles username. A key that the API refuses is shown as the HTTP error. Saving the key uses the same Keychain path as a server password.

## Folder play and the next episode

**Play folder** starts the first video in natural name order. When that file reaches the end, the next video in that same name order starts, unless **Next episode** is unchecked. Stopping in the middle, or starting a different file yourself, does not advance the queue. Date and size sort change the sidebar only. The queue stays in name order so Episode 2 follows Episode 1.

## What was not run

This was not installed in IINA. No WebDAV, FTP, FTPS, SMB, SFTP, Jellyfin, Emby, Plex, DLNA, or OpenSubtitles server was contacted. The Keychain was not written. `dns-sd` and the SSDP script were not run on a network. Subtitle auto-load, resume seek, poster loading, and both-eye playback were not tried. The listing parsers, address parsers, sort, search, resume thresholds, history, favourites, discovery text, and the shell scripts' syntax were checked locally with Node.
