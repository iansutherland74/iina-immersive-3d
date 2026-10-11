const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.join(__dirname, "..", "main.js"), "utf8");
const start = source.indexOf("// BEGIN PURE");
const end = source.indexOf("// END PURE");
if (start < 0 || end < start) throw new Error("markers missing");
const api = new Function(source.slice(start, end) + `
return { parseListing, parseFTPList, subtitleFor, ftpPlaybackURL, parseFTPAddress, curlUserLine, stripUserinfo, base64Encode, validWebDAV, credentialsFromAddress, playbackScheme, sameMedia };
`)();

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
console.log("remote-files checks passed");
