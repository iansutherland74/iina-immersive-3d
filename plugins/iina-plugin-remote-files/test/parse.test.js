const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const api = require("../library.js");

function assert(cond, message) {
  if (!cond) throw new Error(message);
}

const unix = [
  "drwxr-xr-x  2 user group     4096 Oct 11 12:00 Movies",
  "-rw-r--r--  1 user group  1234567 Oct 11  2024 Show Title.mkv",
  "-rw-r--r--  1 user group      200 Oct 11 12:00 Show Title.en.srt",
  "-rw-r--r--  1 user group      200 Oct 11 12:00 Showdown.srt",
  "-rw-r--r--  1 user group       20 Oct 11 12:00 notes.txt",
  "drwxr-xr-x  2 user group     4096 Oct 11 12:00 .."
].join("\n");
const ftp = api.parseFTPList(unix);
assert(ftp.length === 4, "unix kept folder, video, and both subtitles, got " + ftp.map((e) => e.name).join(","));
assert(ftp[0].folder && ftp[0].name === "Movies", "folder first");
assert(ftp.some((e) => e.kind === "video" && e.name === "Show Title.mkv"), "video");
assert(ftp.some((e) => e.kind === "subtitle" && e.name === "Show Title.en.srt"), "sidecar");
assert(ftp.some((e) => e.name === "Showdown.srt"), "other subtitle stays available");
assert(!ftp.some((e) => e.name === "notes.txt" || e.name === ".."), "notes and dot entries hidden");
const shown = ftp.filter((e) => e.kind !== "subtitle");
assert(shown.length === 2, "browser hides subtitle rows");

const dos = "10-11-26  12:00PM       <DIR>          Season 1\r\n10-11-26  12:00PM             1000 Episode.mp4\r\n";
const windows = api.parseFTPList(dos);
assert(windows.length === 2 && windows[0].name === "Season 1" && windows[1].kind === "video", "iis listing");

assert(api.subtitleFor("Show Title.mkv", "Show Title.srt"), "exact subtitle");
assert(api.subtitleFor("Show Title.mkv", "Show Title.en.ass"), "language suffix");
assert(api.subtitleFor("Show Title.mkv", "Show Title.vtt"), "vtt");
assert(!api.subtitleFor("Show Title.mkv", "Showdown.srt"), "different stem");
assert(!api.subtitleFor("Show Title.mkv", "Show Title.mkv"), "video is not a subtitle");

const playback = api.ftpPlaybackURL("ftp", "alice", "p@ss word", "nas.local:21", "/Movies/Show Title.mkv");
assert(playback === "ftp://alice:p%40ss%20word@nas.local:21/Movies/Show%20Title.mkv", playback);
assert(!playback.includes("p@ss"), "password encoded");
assert(api.stripUserinfo(playback) === "ftp://nas.local:21/Movies/Show%20Title.mkv", "strip userinfo");

const explicit = api.parseFTPAddress("ftps", "nas.local/video");
assert(explicit && explicit.host === "nas.local" && explicit.implicit === false, "explicit ftps");
const implicit = api.parseFTPAddress("ftps", "ftps://nas.local:990/files");
assert(implicit && implicit.implicit === true && implicit.path === "/files", "implicit ftps " + JSON.stringify(implicit));
assert(api.validWebDAV("https://webdav.febbox.com") && !api.validWebDAV("ftp://nas"), "webdav url");

const line = api.curlUserLine("alice", "quo\"te");
assert(line === "user = \"alice:quo\\\"te\"\n", line);
assert(!api.curlUserLine("alice", "secret").includes("\nsecret"), "one line");

const xml = `<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/files/alice/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/files/alice/Movie.mkv</d:href><d:propstat><d:prop><d:getcontenttype>video/x-matroska</d:getcontenttype></d:prop></d:propstat></d:response>
  <d:response><d:href>/files/alice/Movie.srt</d:href><d:propstat><d:prop><d:getcontenttype>text/plain</d:getcontenttype></d:prop></d:propstat></d:response>
  <d:response><d:href>https://user:secret@cloud.example/files/alice/Other.mp4</d:href><d:propstat><d:prop><d:getcontenttype>video/mp4</d:getcontenttype></d:prop></d:propstat></d:response>
</d:multistatus>`;
const web = api.parseListing(xml, "https://cloud.example/files/alice/");
assert(web.length === 3, "webdav entries " + web.length);
assert(web.every((e) => !String(e.href).includes("secret")), "webdav password stripped");
assert(api.subtitleFor("Movie.mkv", web.find((e) => e.kind === "subtitle").name), "webdav subtitle matches video");

assert(api.base64Encode("user:pass") === Buffer.from("user:pass").toString("base64"), "basic");

const pasted = api.credentialsFromAddress("https://alice:s%40cret@cloud.example/files/alice/");
assert(pasted.url === "https://cloud.example/files/alice/", pasted.url);
assert(pasted.username === "alice" && pasted.password === "s@cret", "pasted secret decoded");
assert(!pasted.url.includes("s%40cret") && !pasted.url.includes("secret"), "password left the address");
const bare = api.credentialsFromAddress("alice:secret@nas.local/Movies");
assert(bare.url === "nas.local/Movies" && bare.password === "secret", "schemeless userinfo " + bare.url);
assert(api.credentialsFromAddress("https://webdav.febbox.com").password === "", "no userinfo");

assert(api.playbackScheme("ftp", false) === "ftp", "plain ftp");
assert(api.playbackScheme("ftps", false) === "ftp", "explicit ftps stays ftp");
assert(api.playbackScheme("ftps", true) === "ftps", "implicit ftps");

const played = api.ftpPlaybackURL("ftp", "alice", "secret", "nas.local", "/Movies/Show Title.mkv");
assert(api.sameMedia(played, "ftp://nas.local/Movies/Show%20Title.mkv"), "subtitle match ignores userinfo");
assert(!api.sameMedia(played, "ftp://nas.local/Movies/Other.mkv"), "different file");

const iso = "2026-10-11 12:00 <DIR> Season 1\n2026-10-11 12:00 1000 Episode.mp4\n";
const dated = api.parseFTPList(iso);
assert(dated.length === 2 && dated[0].folder && dated[1].kind === "video", "iso listing");
assert(api.parseFTPList(unix).find((e) => e.name === "Show Title.mkv").size === 1234567, "unix size");

const episodes = api.sortEntries([
  { name: "Episode 10.mkv", href: "10", kind: "video", folder: false },
  { name: "Episode 2.mkv", href: "2", kind: "video", folder: false },
  { name: "Episode 1.mkv", href: "1", kind: "video", folder: false }
], "name");
assert(episodes.map((e) => e.href).join(",") === "1,2,10", "natural episode order");
assert(api.nextInFolder(episodes, "2").href === "10", "next episode");
assert(api.nextInFolder(episodes, "10") === null, "end of folder");
const bySize = api.sortEntries([
  { name: "a.mkv", href: "a", kind: "video", folder: false, size: 10 },
  { name: "b.mkv", href: "b", kind: "video", folder: false, size: 50 }
], "size");
assert(bySize[0].href === "b", "size sort");
assert(api.filterEntries(episodes, "episode 2").map((e) => e.href).join(",") === "2", "search");

assert(api.resumeDecision(4, 1000) === 0, "short resume ignored");
assert(api.resumeDecision(80, 1000) === 80, "resume kept");
assert(api.resumeDecision(990, 1000) === 0, "near the end ignored");
const history = api.pushHistory([{ serverId: "a", href: "/old" }], { serverId: "a", href: "/new", name: "New" }, 40);
assert(history[0].href === "/new" && history.length === 2, "history");
const fav = api.toggleFavourite([], { serverId: "a", href: "/new", name: "New" });
assert(api.isFavourite(fav, "a", "/new") && api.toggleFavourite(fav, fav[0]).length === 0, "favourite");

const smb = api.parseSMBAddress("smb://alice:secret@nas/Media/Shows");
assert(smb && smb.host === "nas" && smb.share === "Media" && smb.path === "/Shows", JSON.stringify(smb));
const mount = api.smbMountScript("alice", "p@ss", "nas", "Media");
assert(mount.includes("p%40ss") && !mount.includes("p@ss"), "smb password encoded");
assert(!["/tmp/mount-helper", "/tmp/mnt"].join(" ").includes("p%40ss"), "logged mount args have no password");
const sftp = api.parseSFTPAddress("files.example:22/Shows");
assert(sftp && sftp.host === "files.example" && sftp.port === "22" && sftp.path === "/Shows", JSON.stringify(sftp));
assert(!api.sftpWrapper().includes("secret"), "sftp wrapper has no password");
assert(api.sftpWrapper().includes("export PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "sftp wrapper restores PATH");
assert(api.discoverBrowseScript().includes("export PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "discovery restores PATH");
const linked = api.parseFTPList("lrwxr-xr-x  1 user group 12 Oct 11 12:00 Movie.mkv -> /data/Movie.mkv");
assert(linked.length === 1 && linked[0].name === "Movie.mkv" && linked[0].kind === "video", "symlink video");
assert(api.askpassScript("secret").includes("secret"), "askpass holds the password");

const jelly = api.jellyfinEntries({
  Items: [
    { Name: "Shows", Id: "s1", Type: "CollectionFolder", ImageTags: { Primary: "x" } },
    { Name: "Pilot", Id: "e1", Type: "Episode", RunTimeTicks: 600000000, UserData: { PlaybackPositionTicks: 120000000 }, MediaSources: [{ Id: "m1", Size: 50 }], ImageTags: { Primary: "y" } }
  ]
});
assert(jelly.length === 2 && jelly[0].folder && jelly[1].resume === 12 && jelly[1].duration === 60, "jellyfin items");
const poster = api.jellyfinImage("http://jelly:8096", "e1", "token");
assert(poster.includes("api_key=token") && !api.jellyfinStream("http://jelly:8096", "e1", "m1").includes("token"), "poster has the token, stream does not");

const plex = api.plexEntries({
  MediaContainer: {
    Metadata: [
      { title: "Show", type: "show", ratingKey: 7, thumb: "/library/metadata/7/thumb" },
      { title: "Episode 1", type: "episode", ratingKey: 8, viewOffset: 15000, duration: 60000, Media: [{ Part: [{ key: "/library/parts/8/file.mkv", size: 9 }] }] }
    ]
  }
});
assert(plex[0].folder && plex[1].href === "plex:8" && plex[1].resume === 15, "plex items");
assert(api.plexStream("http://plex:32400", plex[1].part) === "http://plex:32400/library/parts/8/file.mkv", "plex stream");
assert(api.plexImage("http://plex:32400", "/library/metadata/7/thumb", "tok").includes("X-Plex-Token=tok"), "plex poster");

const device = api.parseDevice('<root><device><friendlyName>Living Room</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/ctl/ContentDir</controlURL></service></serviceList></device></root>');
assert(device.name === "Living Room" && api.resolveControl("http://tv:8200/desc.xml", device.control) === "http://tv:8200/ctl/ContentDir", "dlna device");
const didl = api.parseDIDL('<DIDL-Lite><container id="2"><dc:title>Movies</dc:title></container><item id="3"><dc:title>Movie.mkv</dc:title><res protocolInfo="http-get:*:video/mp4:*" size="42">http://tv:8200/movie.mkv</res></item><item id="4"><dc:title>Note.txt</dc:title><res>http://tv:8200/note.txt</res></item></DIDL-Lite>');
assert(didl.length === 2 && didl[1].href === "http://tv:8200/movie.mkv", "didl " + didl.map((e) => e.name).join(","));
const ssdp = api.parseSSDP("HTTP/1.1 200 OK\nLOCATION: http://tv:8200/desc.xml\nSERVER: Linux/UPnP\n\n");
assert(ssdp.length === 1 && ssdp[0].kind === "dlna", "ssdp");
const bonjour = api.parseDNSSD("15:55:01.123  Add        3  12 local.               _plexmediasvr._tcp.  Office Plex\n");
assert(bonjour.length === 1 && bonjour[0].kind === "plex" && bonjour[0].name === "Office Plex", "dns-sd");
assert(api.parseDNSSDLookup("can be reached at plex.local.:32400").port === "32400", "dns-sd lookup");
assert(api.discoveredURL("plex", "plex.local", "32400") === "http://plex.local:32400", "discovered url");
assert(api.opensubtitleChoice({ data: [{ attributes: { files: [{ file_id: 4, file_name: "Other.srt" }, { file_id: 9, file_name: "Show.en.srt" }] } }] }, "Show.mkv").fileId === 9, "opensubtitles stem");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "remote-files-"));
fs.writeFileSync(path.join(tmp, "ssdp.pl"), api.ssdpScript());
fs.writeFileSync(path.join(tmp, "browse.sh"), api.discoverBrowseScript());
fs.writeFileSync(path.join(tmp, "sftp.sh"), api.sftpWrapper());
execFileSync("perl", ["-c", path.join(tmp, "ssdp.pl")], { stdio: "pipe" });
execFileSync("sh", ["-n", path.join(tmp, "browse.sh")]);
execFileSync("sh", ["-n", path.join(tmp, "sftp.sh")]);
fs.rmSync(tmp, { recursive: true, force: true });
console.log("remote-files checks passed");
