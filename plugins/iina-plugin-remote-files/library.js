// Pure helpers for the remote-files plugin. No IINA object and no network.
var VIDEO_EXTENSIONS = {
  mkv: 1, mp4: 1, m4v: 1, mov: 1, avi: 1, wmv: 1, flv: 1, webm: 1,
  ts: 1, m2ts: 1, mts: 1, mpg: 1, mpeg: 1, vob: 1, ogv: 1, ogm: 1,
  "3gp": 1, "3g2": 1, asf: 1, rm: 1, rmvb: 1, divx: 1, f4v: 1, m2v: 1, qt: 1, mxf: 1
};
var SUBTITLE_EXTENSIONS = { srt: 1, ass: 1, ssa: 1, vtt: 1 };

function utf8Bytes(text) {
  var encoded = encodeURIComponent(text);
  var bytes = [];
  for (var i = 0; i < encoded.length; i++) {
    if (encoded.charAt(i) === "%") {
      bytes.push(parseInt(encoded.substr(i + 1, 2), 16));
      i += 2;
    } else {
      bytes.push(encoded.charCodeAt(i));
    }
  }
  return bytes;
}

function base64Encode(text) {
  var table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  var bytes = utf8Bytes(text);
  var out = "";
  for (var i = 0; i < bytes.length; i += 3) {
    var a = bytes[i];
    var b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    var c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    var triple = (a << 16) | (b << 8) | c;
    out += table.charAt((triple >> 18) & 63);
    out += table.charAt((triple >> 12) & 63);
    out += i + 1 < bytes.length ? table.charAt((triple >> 6) & 63) : "=";
    out += i + 2 < bytes.length ? table.charAt(triple & 63) : "=";
  }
  return out;
}

function decodeXML(text) {
  return String(text)
    .replace(/&#(\d+);/g, function (_, n) { return String.fromCharCode(parseInt(n, 10)); })
    .replace(/&#x([0-9a-f]+);/gi, function (_, n) { return String.fromCharCode(parseInt(n, 16)); })
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function safeDecode(text) {
  try { return decodeURIComponent(text); } catch (error) { return text; }
}

function extensionOf(name) {
  var dot = String(name).lastIndexOf(".");
  if (dot < 1 || dot === name.length - 1) return "";
  return name.slice(dot + 1).toLowerCase();
}

function stemOf(name) {
  var ext = extensionOf(name);
  return ext ? name.slice(0, name.length - ext.length - 1) : name;
}

function isVideo(name, contentType) {
  if (VIDEO_EXTENSIONS[extensionOf(name)]) return true;
  return /^video\//i.test(contentType || "");
}

function isSubtitle(name) {
  return !!SUBTITLE_EXTENSIONS[extensionOf(name)];
}

function subtitleFor(videoName, fileName) {
  if (!isSubtitle(fileName)) return false;
  var videoStem = stemOf(videoName).toLowerCase();
  var fileStem = stemOf(fileName).toLowerCase();
  if (!videoStem) return false;
  return fileStem === videoStem || fileStem.indexOf(videoStem + ".") === 0;
}

function tagText(block, name) {
  var re = new RegExp("<[^>]*:?" + name + "\\b[^>]*>([\\s\\S]*?)</[^>]*:?" + name + ">", "i");
  var match = block.match(re);
  return match ? decodeXML(match[1]).trim() : "";
}

function lastSegment(href) {
  var path = String(href).split("?")[0].split("#")[0].replace(/\/+$/, "");
  var parts = path.split("/");
  return safeDecode(parts[parts.length - 1] || "");
}

function stripUserinfo(url) {
  return String(url).replace(/^([a-z][a-z0-9+.-]*:\/\/)([^/@]+)@/i, "$1");
}

function originOf(url) {
  var match = String(url).match(/^(https?:\/\/[^/?#]+)/i);
  return match ? match[1] : "";
}

function resolveHref(base, href) {
  var raw = decodeXML(String(href || "")).trim();
  if (/^https?:\/\//i.test(raw)) return stripUserinfo(raw);
  var origin = originOf(base);
  if (!origin) return raw;
  if (raw.charAt(0) === "/") return origin + raw;
  var root = /\/$/.test(base) ? base : base.replace(/\/[^/]*$/, "/");
  return root + raw;
}

function resourceKey(url) {
  var bare = stripUserinfo(String(url)).split("?")[0].split("#")[0];
  try { bare = decodeURIComponent(bare); } catch (error) {}
  return bare.replace(/\/+$/, "");
}

function directoryURL(url) {
  var bare = stripUserinfo(String(url)).split("?")[0].split("#")[0];
  return /\/$/.test(bare) ? bare : bare + "/";
}

function kindFor(name, folder, contentType) {
  if (folder) return "folder";
  if (isSubtitle(name)) return "subtitle";
  if (isVideo(name, contentType)) return "video";
  return "other";
}

function parseListing(xml, requestedURL) {
  var re = /<[^>]*:?response\b[^>]*>([\s\S]*?)<\/[^>]*:?response>/gi;
  var selfKey = resourceKey(requestedURL);
  var entries = [];
  var match;
  while ((match = re.exec(String(xml || "")))) {
    var block = match[1];
    var href = tagText(block, "href");
    if (!href) continue;
    var absolute = resolveHref(requestedURL, href);
    if (resourceKey(absolute) === selfKey) continue;
    var folder = /<[^>]*:?collection\b/i.test(block);
    var contentType = tagText(block, "getcontenttype");
    var name = tagText(block, "displayname");
    if (!name || name.indexOf("/") !== -1) name = lastSegment(absolute);
    if (!name || name === "." || name === "..") continue;
    var kind = kindFor(name, folder, contentType);
    if (kind === "other") continue;
    var length = parseInt(tagText(block, "getcontentlength"), 10);
    entries.push({
      name: name,
      href: folder ? directoryURL(absolute) : absolute.replace(/\/+$/, ""),
      folder: folder,
      kind: kind,
      size: isFinite(length) ? length : 0,
      date: parseHTTPDate(tagText(block, "getlastmodified"))
    });
  }
  return sortEntries(entries);
}

function parseFTPList(text) {
  var entries = [];
  String(text || "").split(/\r?\n/).forEach(function (line) {
    var parsed = parseFTPLine(line.trim());
    if (!parsed || parsed.name === "." || parsed.name === "..") return;
    var kind = kindFor(parsed.name, parsed.folder, "");
    if (kind === "other") return;
    entries.push({
      name: parsed.name,
      folder: parsed.folder,
      kind: kind,
      size: parsed.size || 0,
      date: parsed.date || 0
    });
  });
  return sortEntries(entries);
}

function parseFTPLine(line) {
  if (!line || /^sftp>/.test(line) || /^total\s+\d+/.test(line)) return null;
  var unix = line.match(/^([dl\-l])\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s+(.+)$/);
  if (unix) {
    var name = unix[6];
    var arrow = name.indexOf(" -> ");
    if (arrow !== -1) name = name.slice(0, arrow);
    return {
      folder: unix[1] === "d",
      name: name.trim(),
      size: parseInt(unix[2], 10) || 0,
      date: ftpDate(unix[3], unix[4], unix[5])
    };
  }
  var dos = line.match(/^(\d{2}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})\s*(AM|PM)?\s+(<DIR>|\d+)\s+(.+)$/i);
  if (dos) {
    return {
      folder: dos[4].toUpperCase() === "<DIR>",
      name: dos[5].trim(),
      size: parseInt(dos[4], 10) || 0,
      date: dosDate(dos[1], dos[2], dos[3])
    };
  }
  var iso = line.match(/^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(<DIR>|\d+)\s+(.+)$/i);
  if (iso) {
    return {
      folder: iso[3].toUpperCase() === "<DIR>",
      name: iso[4].trim(),
      size: parseInt(iso[3], 10) || 0,
      date: isoDate(iso[1], iso[2])
    };
  }
  return null;
}

function sortEntries(entries, mode) {
  var list = (entries || []).slice();
  var key = mode === "date" || mode === "size" ? mode : "name";
  list.sort(function (a, b) {
    if (!!a.folder !== !!b.folder) return a.folder ? -1 : 1;
    if (key === "size" && (b.size || 0) !== (a.size || 0)) return (b.size || 0) - (a.size || 0);
    if (key === "date" && (b.date || 0) !== (a.date || 0)) return (b.date || 0) - (a.date || 0);
    return naturalCompare(a.name, b.name);
  });
  return list;
}

function curlUserLine(username, password) {
  var value = String(username) + ":" + String(password);
  value = value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
  return "user = \"" + value + "\"\n";
}

function encodePath(path) {
  return String(path).split("/").map(function (part) {
    return encodeURIComponent(safeDecode(part));
  }).join("/");
}

function ftpPlaybackURL(scheme, username, password, host, path) {
  var auth = encodeURIComponent(username) + ":" + encodeURIComponent(password);
  var full = encodePath(path);
  if (full.charAt(0) !== "/") full = "/" + full;
  return scheme + "://" + auth + "@" + host + full;
}

function parseFTPAddress(protocol, raw) {
  var text = String(raw || "").trim().replace(/\/+$/, "");
  if (!text) return null;
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) {
    text = (protocol === "ftps" ? "ftps://" : "ftp://") + text;
  }
  text = stripUserinfo(text);
  var match = text.match(/^ftps?:\/\/([^/?#]+)(\/.*)?$/i);
  if (!match) return null;
  var host = match[1];
  var port = (host.match(/:(\d+)$/) || [])[1] || "";
  var implicit = protocol === "ftps" && (port === "990" || /^ftps:\/\//i.test(String(raw || "")));
  return { host: host, path: match[2] || "/", implicit: implicit };
}

function playbackScheme(protocol, implicit) {
  if (protocol === "ftps" && implicit) return "ftps";
  return protocol === "webdav" ? "https" : "ftp";
}

function credentialsFromAddress(raw) {
  var text = String(raw || "").trim();
  var scheme = "";
  var rest = text;
  var schemeMatch = text.match(/^((?:https?|ftps?|smb|sftp):\/\/)([\s\S]*)$/i);
  if (schemeMatch) {
    scheme = schemeMatch[1];
    rest = schemeMatch[2];
  }
  var slash = rest.indexOf("/");
  var authority = slash === -1 ? rest : rest.slice(0, slash);
  var tail = slash === -1 ? "" : rest.slice(slash);
  var at = authority.lastIndexOf("@");
  if (at < 1) return { url: text, username: "", password: "" };
  var userinfo = authority.slice(0, at);
  var colon = userinfo.indexOf(":");
  var username = colon === -1 ? userinfo : userinfo.slice(0, colon);
  var password = colon === -1 ? "" : userinfo.slice(colon + 1);
  return {
    url: scheme + authority.slice(at + 1) + tail,
    username: safeDecode(username),
    password: safeDecode(password)
  };
}

function sameMedia(a, b) {
  return resourceKey(a).toLowerCase() === resourceKey(b).toLowerCase();
}

function validWebDAV(url) {
  return /^https?:\/\/[^/\s]+/i.test(String(url || "").trim());
}

function validHTTP(url) {
  return /^https?:\/\/[^/\s]+/i.test(String(url || "").trim());
}

function parseHTTPDate(text) {
  var value = Date.parse(String(text || ""));
  return isFinite(value) ? value : 0;
}

var FTP_MONTHS = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5, Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 };

function ftpDate(month, day, clock, nowMs) {
  var monthIndex = FTP_MONTHS[month];
  if (monthIndex == null) return 0;
  var now = new Date(nowMs || Date.now());
  var year = now.getUTCFullYear();
  var hour = 0;
  var minute = 0;
  if (/^\d{4}$/.test(clock)) year = parseInt(clock, 10);
  else {
    var parts = String(clock).split(":");
    hour = parseInt(parts[0], 10) || 0;
    minute = parseInt(parts[1], 10) || 0;
  }
  var stamp = Date.UTC(year, monthIndex, parseInt(day, 10), hour, minute);
  if (!/^\d{4}$/.test(String(clock)) && stamp > now.getTime() + 86400000) {
    stamp = Date.UTC(year - 1, monthIndex, parseInt(day, 10), hour, minute);
  }
  return stamp;
}

function dosDate(mdy, hm, ampm) {
  var date = String(mdy).split("-");
  var time = String(hm).split(":");
  var year = 2000 + (parseInt(date[2], 10) || 0);
  var hour = parseInt(time[0], 10) || 0;
  var minute = parseInt(time[1], 10) || 0;
  if (ampm && /pm/i.test(ampm) && hour < 12) hour += 12;
  if (ampm && /am/i.test(ampm) && hour === 12) hour = 0;
  return Date.UTC(year, (parseInt(date[0], 10) || 1) - 1, parseInt(date[1], 10) || 1, hour, minute);
}

function isoDate(day, hm) {
  var date = String(day).split("-");
  var time = String(hm).split(":");
  return Date.UTC(parseInt(date[0], 10) || 0, (parseInt(date[1], 10) || 1) - 1, parseInt(date[2], 10) || 1, parseInt(time[0], 10) || 0, parseInt(time[1], 10) || 0);
}

function naturalCompare(a, b) {
  var re = /(\d+)|(\D+)/g;
  var left = String(a || "").toLowerCase().match(re) || [];
  var right = String(b || "").toLowerCase().match(re) || [];
  var count = Math.max(left.length, right.length);
  for (var i = 0; i < count; i++) {
    var x = left[i] || "";
    var y = right[i] || "";
    if (/^\d+$/.test(x) && /^\d+$/.test(y)) {
      var delta = parseInt(x, 10) - parseInt(y, 10);
      if (delta) return delta;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

function filterEntries(entries, query) {
  var needle = String(query || "").trim().toLowerCase();
  if (!needle) return (entries || []).slice();
  return (entries || []).filter(function (entry) {
    return String(entry.name || "").toLowerCase().indexOf(needle) !== -1;
  });
}

function nextInFolder(entries, href) {
  var videos = sortEntries(entries, "name").filter(function (entry) { return entry.kind === "video"; });
  for (var i = 0; i < videos.length; i++) {
    if (videos[i].href === href) return videos[i + 1] || null;
  }
  return null;
}

function resumeKey(serverId, href) {
  return String(serverId || "") + "\n" + stripUserinfo(String(href || ""));
}

function resumeDecision(position, duration) {
  var seconds = Number(position);
  var length = Number(duration);
  if (!(seconds >= 5)) return 0;
  if (length > 0 && (seconds >= length - 30 || seconds / length >= 0.95)) return 0;
  return seconds;
}

function resumeFraction(position, duration) {
  var seconds = Number(position);
  var length = Number(duration);
  if (!(seconds > 0) || !(length > 0)) return 0;
  var fraction = seconds / length;
  if (fraction < 0) return 0;
  if (fraction > 1) return 1;
  return fraction;
}

function pushHistory(list, item, limit) {
  var next = [item].concat((list || []).filter(function (row) {
    return !(row && row.serverId === item.serverId && row.href === item.href);
  }));
  return next.slice(0, limit || 40);
}

function isFavourite(list, serverId, href) {
  return (list || []).some(function (row) {
    return row && row.serverId === serverId && row.href === href;
  });
}

function toggleFavourite(list, item) {
  if (isFavourite(list, item.serverId, item.href)) {
    return (list || []).filter(function (row) {
      return !(row && row.serverId === item.serverId && row.href === item.href);
    });
  }
  return [item].concat(list || []);
}

function shellSingleQuote(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'";
}

function shellPreamble() {
  return "#!/bin/sh\nexport PATH=/usr/bin:/bin:/usr/sbin:/sbin\n";
}

function smbMountScript(username, password, host, share) {
  var url = "//" + encodeURIComponent(username) + ":" + encodeURIComponent(password) + "@" + host + "/" + encodeURIComponent(share);
  return shellPreamble() + "exec /sbin/mount_smbfs -N " + shellSingleQuote(url) + " \"$1\"\n";
}

function askpassScript(password) {
  return "#!/bin/sh\nprintf '%s\\n' " + shellSingleQuote(password) + "\n";
}

function sftpBatch(path) {
  var dir = String(path || "/");
  if (dir.charAt(0) !== "/") dir = "/" + dir;
  return "ls -l " + shellSingleQuote(dir) + "\n";
}

function sftpWrapper() {
  return [
    "#!/bin/sh",
    "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "home=\"$1\"",
    "ask=\"$2\"",
    "batch=\"$3\"",
    "target=\"$4\"",
    "port=\"$5\"",
    "export HOME=\"$home\"",
    "export SSH_ASKPASS=\"$ask\"",
    "export SSH_ASKPASS_REQUIRE=force",
    "export DISPLAY=:0",
    "mkdir -p \"$home/.ssh\"",
    "printf '%s\\n' 'Host *' '  StrictHostKeyChecking accept-new' \"  UserKnownHostsFile $home/.ssh/known_hosts\" '  PreferredAuthentications password' '  PubkeyAuthentication no' > \"$home/.ssh/config\"",
    "if [ -n \"$port\" ]; then",
    "  exec /usr/bin/sftp -P \"$port\" -F \"$home/.ssh/config\" -b \"$batch\" \"$target\"",
    "fi",
    "exec /usr/bin/sftp -F \"$home/.ssh/config\" -b \"$batch\" \"$target\"",
    ""
  ].join("\n");
}

function discoverBrowseScript() {
  return [
    "#!/bin/sh",
    "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "pids=",
    "for type in _plexmediasvr._tcp _jellyfin._tcp _emby._tcp _smb._tcp _sftp-ssh._tcp; do",
    "  /usr/bin/dns-sd -B \"$type\" local. &",
    "  pids=\"$pids $!\"",
    "done",
    "sleep 4",
    "kill $pids 2>/dev/null",
    "wait 2>/dev/null",
    "exit 0",
    ""
  ].join("\n");
}

function lookupScript() {
  return shellPreamble() + "/usr/bin/dns-sd -L \"$1\" \"$2\" local. &\npid=$!\nsleep 2\nkill $pid 2>/dev/null\nwait 2>/dev/null\nexit 0\n";
}

function ssdpScript() {
  return [
    "use Socket;",
    "socket(S, PF_INET, SOCK_DGRAM, getprotobyname('udp')) or die $!;",
    "setsockopt(S, SOL_SOCKET, SO_REUSEADDR, pack('l', 1));",
    "bind(S, sockaddr_in(0, INADDR_ANY)) or die $!;",
    "my $msg = \"M-SEARCH * HTTP/1.1\\r\\nHOST: 239.255.255.250:1900\\r\\nMAN: \\\"ssdp:discover\\\"\\r\\nMX: 2\\r\\nST: urn:schemas-upnp-org:device:MediaServer:1\\r\\n\\r\\n\";",
    "send(S, $msg, 0, sockaddr_in(1900, inet_aton('239.255.255.250'))) or die $!;",
    "my $deadline = time() + 3;",
    "while (time() < $deadline) {",
    "  my $rin = '';",
    "  vec($rin, fileno(S), 1) = 1;",
    "  my $left = $deadline - time();",
    "  last if $left <= 0;",
    "  my $n = select($rin, undef, undef, $left);",
    "  last if !$n;",
    "  my $buf = '';",
    "  recv(S, $buf, 4096, 0);",
    "  print $buf, \"\\n\\n\";",
    "}",
    "exit 0;",
    ""
  ].join("\n");
}

function parseSMBAddress(raw) {
  var text = stripUserinfo(String(raw || "").trim());
  text = text.replace(/^smb:\/\//i, "").replace(/^\/\//, "").replace(/\/+$/, "");
  if (!text || text.indexOf("@") !== -1) return null;
  var parts = text.split("/").filter(function (part) { return part.length > 0; });
  if (!parts.length || !parts[0]) return null;
  return {
    host: parts[0],
    share: parts[1] || "",
    path: parts.length > 2 ? "/" + parts.slice(2).join("/") : "/"
  };
}

function parseSFTPAddress(raw) {
  var text = String(raw || "").trim().replace(/\/+$/, "");
  if (!text) return null;
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) text = "sftp://" + text;
  text = stripUserinfo(text);
  var match = text.match(/^sftp:\/\/([^/?#]+)(\/.*)?$/i);
  if (!match) return null;
  var hostport = match[1];
  var host = hostport;
  var port = "";
  var colon = hostport.lastIndexOf(":");
  if (colon > 0 && /^\d+$/.test(hostport.slice(colon + 1))) {
    host = hostport.slice(0, colon);
    port = hostport.slice(colon + 1);
  }
  if (!host) return null;
  return { host: host, port: port, path: match[2] || "/" };
}

function ticksToSeconds(ticks) {
  var value = Number(ticks);
  if (!isFinite(value) || value <= 0) return 0;
  return value / 10000000;
}

function jellyfinEntries(payload) {
  var items = (payload && payload.Items) || [];
  var folderTypes = { Series: 1, Season: 1, Folder: 1, CollectionFolder: 1, BoxSet: 1, Playlist: 1, ManualPlaylistsFolder: 1, UserView: 1, Collection: 1 };
  var videoTypes = { Movie: 1, Episode: 1, Video: 1 };
  var entries = [];
  items.forEach(function (item) {
    if (!item) return;
    var type = String(item.Type || "");
    var folder = !!folderTypes[type] || item.IsFolder === true;
    if (videoTypes[type]) folder = false;
    if (!folder && !videoTypes[type]) return;
    var source = (item.MediaSources && item.MediaSources[0]) || {};
    var date = Date.parse(item.PremiereDate || item.DateCreated || "");
    entries.push({
      name: item.Name || "Item",
      href: String(item.Id || ""),
      folder: folder,
      kind: folder ? "folder" : "video",
      size: source.Size || 0,
      date: isFinite(date) ? date : 0,
      itemId: String(item.Id || ""),
      mediaSourceId: String(source.Id || item.Id || ""),
      hasImage: !!(item.ImageTags && item.ImageTags.Primary),
      resume: ticksToSeconds(item.UserData && item.UserData.PlaybackPositionTicks),
      duration: ticksToSeconds(item.RunTimeTicks)
    });
  });
  return sortEntries(entries);
}

function jellyfinImage(base, itemId, token) {
  if (!itemId) return "";
  var url = String(base || "").replace(/\/+$/, "") + "/Items/" + encodeURIComponent(itemId) + "/Images/Primary?maxHeight=240";
  if (token) url += "&api_key=" + encodeURIComponent(token);
  return url;
}

function jellyfinStream(base, itemId, mediaSourceId) {
  if (!itemId) return "";
  var url = String(base || "").replace(/\/+$/, "") + "/Videos/" + encodeURIComponent(itemId) + "/stream?Static=true";
  if (mediaSourceId) url += "&MediaSourceId=" + encodeURIComponent(mediaSourceId);
  return url;
}

function plexEntries(payload) {
  var box = (payload && payload.MediaContainer) || {};
  var entries = [];
  (box.Directory || []).forEach(function (dir) {
    if (!dir || dir.key == null) return;
    var href = String(dir.key);
    if (/^\d+$/.test(href)) href = "/library/sections/" + href + "/all";
    else if (href.charAt(0) !== "/") href = "/" + href;
    entries.push({
      name: dir.title || "Library",
      href: href,
      folder: true,
      kind: "folder",
      size: 0,
      date: dir.updatedAt ? dir.updatedAt * 1000 : 0
    });
  });
  (box.Metadata || []).forEach(function (item) {
    var type = String(item.type || "");
    var folder = type === "show" || type === "season" || type === "artist" || type === "album";
    var video = type === "movie" || type === "episode" || type === "clip";
    if (!folder && !video) return;
    var piece = item.Media && item.Media[0] && item.Media[0].Part && item.Media[0].Part[0];
    var date = item.addedAt ? item.addedAt * 1000 : parseHTTPDate(item.originallyAvailableAt);
    entries.push({
      name: item.title || "Item",
      href: folder ? "/library/metadata/" + item.ratingKey + "/children" : "plex:" + item.ratingKey,
      folder: folder,
      kind: folder ? "folder" : "video",
      size: piece && piece.size || 0,
      date: isFinite(date) ? date : 0,
      part: piece && piece.key || "",
      ratingKey: String(item.ratingKey || ""),
      thumb: item.thumb || item.parentThumb || item.grandparentThumb || "",
      resume: (item.viewOffset || 0) / 1000,
      duration: (item.duration || 0) / 1000
    });
  });
  return sortEntries(entries);
}

function plexImage(base, thumb, token) {
  if (!thumb) return "";
  var root = String(base || "").replace(/\/+$/, "");
  var path = thumb.charAt(0) === "/" ? thumb : "/" + thumb;
  var url = root + path;
  if (token) url += (url.indexOf("?") === -1 ? "?" : "&") + "X-Plex-Token=" + encodeURIComponent(token);
  return url;
}

function plexStream(base, partKey) {
  if (!partKey) return "";
  var root = String(base || "").replace(/\/+$/, "");
  return root + (partKey.charAt(0) === "/" ? partKey : "/" + partKey);
}

function xmlEscape(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function dlnaBrowseBody(objectId) {
  return "<?xml version=\"1.0\"?>" +
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
    "<s:Body><u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\">" +
    "<ObjectID>" + xmlEscape(objectId || "0") + "</ObjectID>" +
    "<BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter>" +
    "<StartingIndex>0</StartingIndex><RequestedCount>200</RequestedCount><SortCriteria></SortCriteria>" +
    "</u:Browse></s:Body></s:Envelope>";
}

function didlFromSoap(xml) {
  return tagText(xml, "Result").replace(/^<!\[CDATA\[/, "").replace(/\]\]>$/, "");
}

function parseDevice(xml) {
  var name = tagText(xml, "friendlyName");
  var control = "";
  String(xml || "").split(/<service\b/i).slice(1).forEach(function (block) {
    if (control || !/ContentDirectory/i.test(block)) return;
    var match = block.match(/<controlURL>\s*([^<]+)\s*<\/controlURL>/i);
    if (match) control = decodeXML(match[1].trim());
  });
  return { name: name, control: control };
}

function resolveControl(base, control) {
  var raw = String(control || "").trim();
  if (/^https?:\/\//i.test(raw)) return raw;
  if (raw.charAt(0) === "/") return originOf(base) + raw;
  return directoryURL(base) + raw.replace(/^\/+/, "");
}

function parseDIDL(xml) {
  var entries = [];
  var re = /<(?:[\w-]+:)?(item|container)\b([^>]*)>([\s\S]*?)<\/(?:[\w-]+:)?\1>/gi;
  var match;
  var text = String(xml || "");
  while ((match = re.exec(text))) {
    var folder = match[1].toLowerCase() === "container";
    var body = match[3];
    var idMatch = match[2].match(/\bid="([^"]*)"/i);
    var name = tagText(body, "title");
    var res = tagText(body, "res");
    var protocol = (body.match(/<[^>]*:?res\b[^>]*protocolInfo="([^"]*)"/i) || [])[1] || "";
    var size = parseInt((body.match(/<[^>]*:?res\b[^>]*size="(\d+)"/i) || [])[1] || "0", 10);
    var video = /video/i.test(protocol) || isVideo(name, "") || isVideo(lastSegment(res), "");
    var kind = folder ? "folder" : (video ? "video" : (isSubtitle(name) ? "subtitle" : "other"));
    if (kind === "other") continue;
    entries.push({
      name: name || lastSegment(res) || "Item",
      href: folder ? decodeXML(idMatch ? idMatch[1] : "") : res,
      folder: folder,
      kind: kind,
      size: isFinite(size) ? size : 0,
      date: parseHTTPDate(tagText(body, "date"))
    });
  }
  return sortEntries(entries);
}

function parseSSDP(text) {
  var found = [];
  var seen = {};
  String(text || "").split(/\n\s*\n/).forEach(function (block) {
    var location = ((block.match(/^LOCATION:\s*(\S+)/im) || [])[1] || "").trim();
    if (!location || seen[location]) return;
    seen[location] = 1;
    var server = ((block.match(/^SERVER:\s*(.+)$/im) || [])[1] || "").trim();
    found.push({ location: location, name: server || location, kind: "dlna" });
  });
  return found;
}

function parseDNSSD(text) {
  var found = [];
  var seen = {};
  String(text || "").split(/\n/).forEach(function (line) {
    var match = line.match(/\bAdd\b\s+\d+\s+\d+\s+\S+\s+(_[A-Za-z0-9-]+\._tcp)\.?\s+(.+\S)\s*$/);
    if (!match) return;
    var type = match[1].toLowerCase();
    var name = match[2].trim();
    var key = type + "\n" + name;
    if (seen[key]) return;
    seen[key] = 1;
    var kind = "http";
    if (type.indexOf("plex") !== -1) kind = "plex";
    else if (type.indexOf("jellyfin") !== -1) kind = "jellyfin";
    else if (type.indexOf("emby") !== -1) kind = "emby";
    else if (type.indexOf("smb") !== -1) kind = "smb";
    else if (type.indexOf("sftp") !== -1) kind = "sftp";
    found.push({ name: name, kind: kind, service: type });
  });
  return found;
}

function parseDNSSDLookup(text) {
  var match = String(text || "").match(/can be reached at\s+(\S+?):(\d+)/i);
  if (!match) return null;
  return { host: match[1].replace(/\.$/, ""), port: match[2] };
}

function discoveredURL(kind, host, port) {
  var target = String(host || "");
  if (!target) return "";
  if (port) target += ":" + port;
  if (kind === "plex" || kind === "jellyfin" || kind === "emby" || kind === "dlna") return "http://" + target;
  if (kind === "smb") return "smb://" + host;
  if (kind === "sftp") return target;
  return "http://" + target;
}

function opensubtitleChoice(payload, videoName) {
  var rows = (payload && payload.data) || [];
  var stem = stemOf(videoName || "").toLowerCase();
  var best = null;
  for (var i = 0; i < rows.length; i++) {
    var files = (rows[i].attributes && rows[i].attributes.files) || [];
    for (var j = 0; j < files.length; j++) {
      var file = files[j];
      if (!file || !file.file_id) continue;
      var candidate = { fileId: file.file_id, name: file.file_name || "subtitle.srt" };
      if (!best) best = candidate;
      if (stem && String(candidate.name).toLowerCase().indexOf(stem) !== -1) return candidate;
    }
  }
  return best;
}

module.exports = {
  base64Encode: base64Encode,
  parseListing: parseListing,
  parseFTPList: parseFTPList,
  parseFTPLine: parseFTPLine,
  subtitleFor: subtitleFor,
  ftpPlaybackURL: ftpPlaybackURL,
  parseFTPAddress: parseFTPAddress,
  curlUserLine: curlUserLine,
  stripUserinfo: stripUserinfo,
  validWebDAV: validWebDAV,
  validHTTP: validHTTP,
  credentialsFromAddress: credentialsFromAddress,
  playbackScheme: playbackScheme,
  sameMedia: sameMedia,
  sortEntries: sortEntries,
  filterEntries: filterEntries,
  nextInFolder: nextInFolder,
  resumeKey: resumeKey,
  resumeDecision: resumeDecision,
  resumeFraction: resumeFraction,
  pushHistory: pushHistory,
  isFavourite: isFavourite,
  toggleFavourite: toggleFavourite,
  smbMountScript: smbMountScript,
  askpassScript: askpassScript,
  sftpBatch: sftpBatch,
  sftpWrapper: sftpWrapper,
  discoverBrowseScript: discoverBrowseScript,
  lookupScript: lookupScript,
  ssdpScript: ssdpScript,
  parseSMBAddress: parseSMBAddress,
  parseSFTPAddress: parseSFTPAddress,
  jellyfinEntries: jellyfinEntries,
  jellyfinImage: jellyfinImage,
  jellyfinStream: jellyfinStream,
  plexEntries: plexEntries,
  plexImage: plexImage,
  plexStream: plexStream,
  dlnaBrowseBody: dlnaBrowseBody,
  didlFromSoap: didlFromSoap,
  parseDevice: parseDevice,
  resolveControl: resolveControl,
  parseDIDL: parseDIDL,
  parseSSDP: parseSSDP,
  parseDNSSD: parseDNSSD,
  parseDNSSDLookup: parseDNSSDLookup,
  discoveredURL: discoveredURL,
  opensubtitleChoice: opensubtitleChoice,
  directoryURL: directoryURL,
  encodePath: encodePath,
  lastSegment: lastSegment,
  originOf: originOf,
  shellSingleQuote: shellSingleQuote
};
