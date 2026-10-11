// Saved WebDAV, FTP, and FTPS servers. Passwords stay in the Keychain.
// WebDAV playback uses an Authorization header. FTP playback uses an ftp URL
// because that is how mpv accepts the password, and the command log strips userinfo.

// BEGIN PURE
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
  return String(url).replace(/^(https?|ftps?):\/\/([^/@]+)@/i, "$1://");
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
      size: isFinite(length) ? length : 0
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
      size: parsed.size || 0
    });
  });
  return sortEntries(entries);
}

function parseFTPLine(line) {
  if (!line) return null;
  var unix = line.match(/^([dl\-]).*\s(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})\s+(.+)$/);
  if (unix) {
    var name = unix[2];
    var arrow = name.indexOf(" -> ");
    if (arrow !== -1) name = name.slice(0, arrow);
    return { folder: unix[1] === "d", name: name.trim(), size: 0 };
  }
  var dos = line.match(/^\d{2}-\d{2}-\d{2}\s+\d{1,2}:\d{2}\s*(?:AM|PM)?\s+(<DIR>|\d+)\s+(.+)$/i);
  if (dos) {
    return { folder: dos[1].toUpperCase() === "<DIR>", name: dos[2].trim(), size: parseInt(dos[1], 10) || 0 };
  }
  var iso = line.match(/^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+(<DIR>|\d+)\s+(.+)$/i);
  if (iso) {
    return { folder: iso[1].toUpperCase() === "<DIR>", name: iso[2].trim(), size: parseInt(iso[1], 10) || 0 };
  }
  return null;
}

function sortEntries(entries) {
  entries.sort(function (a, b) {
    if (a.folder !== b.folder) return a.folder ? -1 : 1;
    var left = a.name.toLowerCase();
    var right = b.name.toLowerCase();
    return left < right ? -1 : left > right ? 1 : 0;
  });
  return entries;
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
  var schemeMatch = text.match(/^((?:https?|ftps?):\/\/)([\s\S]*)$/i);
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
// END PURE

var core = iina.core;
var event = iina.event;
var menu = iina.menu;
var sidebar = iina.sidebar;
var http = iina.http;
var preferences = iina.preferences;
var utils = iina.utils;
var mpv = iina.mpv;
var file = iina.file;

var KEYCHAIN_SERVICE = "remote-files";
var attached = false;
var sessionPasswords = {};
var appliedHeader = false;
var savedHeader = null;
var appliedTLS = false;
var savedTLS = null;
var appliedStream = false;
var savedStream = null;
var activeHost = "";
var currentEntries = [];
var currentServer = null;
var listToken = 0;
var pendingSubtitles = null;

function scrub(value) {
  if (typeof value === "string") return value.replace(/`/g, "'").replace(/\$\{/g, "$ {");
  if (Object.prototype.toString.call(value) === "[object Array]") return value.map(scrub);
  if (value && typeof value === "object") {
    var copy = {};
    for (var key in value) copy[key] = scrub(value[key]);
    return copy;
  }
  return value;
}

function publish(name, data) {
  sidebar.postMessage(name, scrub(data));
}

function loadServers() {
  var raw = preferences.get("servers");
  if (!raw) return [];
  try {
    var parsed = JSON.parse(String(raw));
    return Object.prototype.toString.call(parsed) === "[object Array]" ? parsed : [];
  } catch (error) {
    return [];
  }
}

function storeServers(list) {
  preferences.set("servers", JSON.stringify(list));
  preferences.sync();
}

function readPassword(id) {
  if (sessionPasswords[id]) return sessionPasswords[id];
  var stored = utils.keychainRead(KEYCHAIN_SERVICE, id);
  return stored && stored !== false ? String(stored) : "";
}

function publicServers() {
  return loadServers().map(function (server) {
    return {
      id: server.id,
      name: server.name,
      protocol: server.protocol,
      url: server.url,
      username: server.username,
      insecureTLS: !!server.insecureTLS,
      hasPassword: readPassword(server.id).length > 0
    };
  });
}

function hostOf(url) {
  var match = stripUserinfo(url).match(/^(?:https?|ftps?):\/\/([^/?#]+)/i);
  if (!match) return "";
  return match[1].replace(/:\d+$/, "").toLowerCase();
}

function restoreHeader() {
  if (!appliedHeader) return;
  mpv.set("http-header-fields", savedHeader || "");
  appliedHeader = false;
  savedHeader = null;
}

function restoreTLS() {
  if (!appliedTLS) return;
  mpv.set("tls-verify", savedTLS || "yes");
  appliedTLS = false;
  savedTLS = null;
}

function restoreStream() {
  if (!appliedStream) return;
  mpv.set("stream-lavf-o", savedStream || "");
  appliedStream = false;
  savedStream = null;
}

function applyStreamTLS(explicit) {
  if (!explicit) return;
  if (!appliedStream) {
    savedStream = mpv.getString("stream-lavf-o");
    appliedStream = true;
  }
  mpv.set("stream-lavf-o", "tls=1");
}

function applyHeader(username, password) {
  if (!appliedHeader) {
    savedHeader = mpv.getString("http-header-fields");
    appliedHeader = true;
  }
  mpv.set("http-header-fields", "Authorization: Basic " + base64Encode(username + ":" + password));
}

function applyTLS(insecure) {
  if (!insecure) return;
  if (!appliedTLS) {
    savedTLS = mpv.getString("tls-verify");
    appliedTLS = true;
  }
  mpv.set("tls-verify", "no");
}

function visibleEntries(entries) {
  return entries.filter(function (entry) { return entry.kind !== "subtitle"; });
}

function showServers(warning, saved) {
  currentServer = null;
  publish("servers", { servers: publicServers(), warning: warning || "", saved: !!saved });
}

function formError(text) {
  publish("form-error", { text: text || "" });
}

function explainHTTP(error) {
  var code = error && error.statusCode;
  if (code === 401 || code === 403) return "The server refused the username or password.";
  if (code === 404) return "That folder was not found.";
  if (!code) return (error && error.reason) || "The server could not be reached.";
  return "The server returned " + code + ".";
}

function listWebDAV(server, url) {
  var token = ++listToken;
  var password = readPassword(server.id);
  if (!password) {
    publish("listing", { title: server.name, url: url, display: url, entries: [], error: "Enter the password for this server." });
    return;
  }
  if (!http.request) {
    publish("listing", { title: server.name, url: url, display: url, entries: [], error: "This IINA build cannot send PROPFIND." });
    return;
  }
  var target = directoryURL(url);
  activeHost = hostOf(target);
  publish("listing", { title: server.name, url: target, display: target, entries: [], error: "", loading: true });
  var pending;
  try {
    pending = http.request("PROPFIND", target, {
      headers: {
        Authorization: "Basic " + base64Encode(server.username + ":" + password),
        Depth: "1",
        "Content-Type": "application/xml; charset=utf-8"
      },
      body: "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
        "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/><d:getcontentlength/></d:prop></d:propfind>",
      timeout: 45
    });
  } catch (error) {
    publish("listing", { title: server.name, url: target, display: target, entries: [], error: "Could not send PROPFIND." });
    return;
  }
  if (!pending || !pending.then) {
    publish("listing", { title: server.name, url: target, display: target, entries: [], error: "This IINA build cannot send PROPFIND." });
    return;
  }
  pending.then(function (response) {
    if (token !== listToken || currentServer !== server) return;
    currentEntries = parseListing(response.text || "", target);
    var shown = visibleEntries(currentEntries);
    publish("listing", {
      title: server.name,
      url: target,
      display: target,
      entries: shown,
      error: shown.length ? "" : "No folders or videos here."
    });
  }).catch(function (error) {
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publish("listing", { title: server.name, url: target, display: target, entries: [], error: explainHTTP(error) });
  });
}

function joinFTP(dir, name, folder) {
  var base = dir.charAt(dir.length - 1) === "/" ? dir : dir + "/";
  var next = base + name;
  return folder ? directoryURL(next) : next.replace(/\/+$/, "");
}

function removeLocal(name) {
  try { file.delete(name); } catch (error) {}
}

function listFTP(server, dirPath) {
  var token = ++listToken;
  var password = readPassword(server.id);
  var address = parseFTPAddress(server.protocol, server.url);
  if (!address) {
    publish("listing", { title: server.name, url: "", display: "", entries: [], error: "Enter a host, or an ftp:// address." });
    return;
  }
  if (!server.username || !password) {
    publish("listing", { title: server.name, url: address.path, display: address.host, entries: [], error: "Enter the username and password." });
    return;
  }
  var path = dirPath || address.path || "/";
  if (path.charAt(0) !== "/") path = "/" + path;
  path = directoryURL(path);
  var listingScheme = playbackScheme(server.protocol, address.implicit);
  var listURL = listingScheme + "://" + address.host + encodePath(path);
  var display = address.host + path;
  activeHost = hostOf(listURL);
  publish("listing", { title: server.name, url: path, display: display, entries: [], error: "", loading: true });
  var stamp = Date.now().toString(36) + "-" + token;
  var configName = "@tmp/curl-auth-" + stamp;
  var outputName = "@tmp/curl-list-" + stamp;
  var configPath = utils.resolvePath(configName);
  var outputPath = utils.resolvePath(outputName);
  if (/[\r\n]/.test(String(server.username) + String(password))) {
    publish("listing", { title: server.name, url: path, display: display, entries: [], error: "The username or password contains a line break." });
    return;
  }
  if (!configPath || !outputPath) {
    publish("listing", { title: server.name, url: path, display: display, entries: [], error: "The plugin temp folder is not available." });
    return;
  }
  var authLine = curlUserLine(server.username, password);
  try {
    file.write(configName, authLine);
  } catch (error) {
    publish("listing", { title: server.name, url: path, display: display, entries: [], error: "The password file could not be written." });
    return;
  }
  var args = ["-sS", "--fail", "--globoff", "--ftp-method", "nocwd", "--config", configPath, "-o", outputPath];
  if (server.protocol === "ftps" && !address.implicit) args.push("--ssl-reqd");
  if (server.insecureTLS) args.push("-k");
  args.push(listURL);
  var pending = utils.exec("/usr/bin/curl", args, null, null, null);
  if (!pending || !pending.then) {
    removeLocal(configName);
    removeLocal(outputName);
    publish("listing", { title: server.name, url: path, display: display, entries: [], error: "curl could not be started. The file-system permission is required." });
    return;
  }
  pending.then(function (result) {
    var body = "";
    if (result && result.status === 0) {
      try { body = file.read(outputName, {}) || ""; } catch (error) { body = ""; }
    }
    removeLocal(configName);
    removeLocal(outputName);
    if (token !== listToken || currentServer !== server) return;
    if (!result || result.status !== 0) {
      var denied = result && result.status === 67;
      var detail = denied ? "The server refused the username or password." : publicStderr(result && result.stderr, password);
      currentEntries = [];
      publish("listing", { title: server.name, url: path, display: display, entries: [], error: detail });
      return;
    }
    currentEntries = parseFTPList(body).map(function (entry) {
      entry.href = joinFTP(path, entry.name, entry.folder);
      return entry;
    });
    var shown = visibleEntries(currentEntries);
    publish("listing", {
      title: server.name,
      url: path,
      display: display,
      entries: shown,
      error: shown.length ? "" : "No folders or videos here."
    });
  }).catch(function () {
    removeLocal(configName);
    removeLocal(outputName);
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publish("listing", { title: server.name, url: path, display: display, entries: [], error: "curl could not be started." });
  });
}

function publicStderr(stderr, password) {
  var text = String(stderr || "");
  if (password) text = text.split(password).join("");
  text = text.replace(/\s+/g, " ").trim();
  if (text.length > 180) text = text.slice(0, 180);
  return text || "The server could not be listed.";
}

function list(href) {
  if (!currentServer) {
    showServers("");
    return;
  }
  if (currentServer.protocol === "webdav") listWebDAV(currentServer, href || currentServer.url);
  else listFTP(currentServer, href);
}

function subtitleURLs(videoName, username, password, server) {
  var address = server.protocol === "webdav" ? null : parseFTPAddress(server.protocol, server.url);
  var scheme = address ? playbackScheme(server.protocol, address.implicit) : "";
  return currentEntries.filter(function (entry) {
    return entry.kind === "subtitle" && subtitleFor(videoName, entry.name);
  }).map(function (entry) {
    var url = entry.href;
    if (address) url = ftpPlaybackURL(scheme, username, password, address.host, entry.href);
    return { url: url, name: entry.name };
  });
}

function play(href, name) {
  if (!currentServer) return;
  var password = readPassword(currentServer.id);
  if (!password) {
    publish("status", { text: "Enter the password for this server." });
    return;
  }
  var videoName = name || lastSegment(href);
  var playback = "";
  if (currentServer.protocol === "webdav") {
    playback = stripUserinfo(href);
    activeHost = hostOf(playback);
    restoreTLS();
    restoreStream();
    applyHeader(currentServer.username, password);
    core.open(playback);
  } else {
    var address = parseFTPAddress(currentServer.protocol, currentServer.url);
    if (!address) return;
    var scheme = playbackScheme(currentServer.protocol, address.implicit);
    playback = ftpPlaybackURL(scheme, currentServer.username, password, address.host, href);
    activeHost = hostOf(playback);
    restoreHeader();
    if (currentServer.insecureTLS) applyTLS(true);
    else restoreTLS();
    if (currentServer.protocol === "ftps" && !address.implicit) applyStreamTLS(true);
    else restoreStream();
    mpv.command("loadfile", [playback, "replace"]);
  }
  pendingSubtitles = {
    video: playback,
    urls: subtitleURLs(videoName, currentServer.username, password, currentServer)
  };
  publish("status", { text: "Playing " + videoName });
}

function saveServer(data) {
  var protocol = data.protocol === "ftp" || data.protocol === "ftps" ? data.protocol : "webdav";
  var pasted = credentialsFromAddress(data.url);
  var url = pasted.url;
  var username = String(data.username || "").trim() || pasted.username;
  var password = String(data.password || "") || pasted.password;
  var name = String(data.name || "").trim() || url || "Server";
  if (!username) {
    formError("Enter a username.");
    return;
  }
  if (protocol === "webdav" && !validWebDAV(url)) {
    formError("A WebDAV address starts with https:// or http://.");
    return;
  }
  if (protocol !== "webdav" && !parseFTPAddress(protocol, url)) {
    formError("Enter a host, or an ftp:// address.");
    return;
  }
  var list = loadServers();
  var id = String(data.id || "");
  var existing = null;
  for (var i = 0; i < list.length; i++) if (list[i].id === id) existing = list[i];
  if (!existing) {
    id = "rf-" + Date.now().toString(36);
    existing = { id: id };
    list.push(existing);
  }
  existing.name = name;
  existing.protocol = protocol;
  existing.url = url;
  existing.username = username;
  existing.insecureTLS = protocol !== "webdav" && !!data.insecureTLS;
  var warning = "";
  if (protocol === "webdav" && /^http:\/\//i.test(url)) {
    warning = "This WebDAV address is not HTTPS. The password crosses the network without encryption.";
  }
  if (password) {
    if (utils.keychainWrite(KEYCHAIN_SERVICE, id, password) === true) {
      delete sessionPasswords[id];
    } else {
      sessionPasswords[id] = password;
      warning = "The password could not be saved in the Keychain. It stays in memory until IINA quits, and it is not written into the server list.";
    }
  }
  storeServers(list);
  showServers(warning, true);
}

function connect(id) {
  var list = loadServers();
  var server = null;
  for (var i = 0; i < list.length; i++) if (list[i].id === id) server = list[i];
  if (!server) {
    showServers("That server is no longer saved.");
    return;
  }
  currentServer = server;
  if (server.protocol === "webdav") listWebDAV(server, server.url);
  else listFTP(server, null);
}

function attach() {
  if (attached) return;
  try {
    sidebar.loadFile("sidebar.html");
  } catch (error) {
    return;
  }
  attached = true;
  sidebar.onMessage("ready", function () { showServers(""); });
  sidebar.onMessage("save-server", saveServer);
  sidebar.onMessage("delete-server", function (data) {
    var id = data && data.id;
    storeServers(loadServers().filter(function (server) { return server.id !== id; }));
    delete sessionPasswords[id];
    if (currentServer && currentServer.id === id) currentServer = null;
    showServers("");
  });
  sidebar.onMessage("connect", function (data) { connect(data && data.id); });
  sidebar.onMessage("servers", function () { showServers(""); });
  sidebar.onMessage("open", function (data) { list(data && data.href); });
  sidebar.onMessage("play", function (data) {
    if (data && data.href) play(data.href, data.name);
  });
}

menu.addItem(menu.item("Remote Files", function () {
  attach();
  sidebar.show();
}, {}));
menu.forceUpdate();

event.on("iina.window-loaded", attach);

event.on("iina.file-started", function () {
  var path = mpv.getString("path") || "";
  if (!path) return;
  var same = activeHost && hostOf(path) === activeHost;
  if (!same) {
    restoreHeader();
    restoreTLS();
    restoreStream();
    pendingSubtitles = null;
  }
});

event.on("iina.file-loaded", function () {
  var pending = pendingSubtitles;
  pendingSubtitles = null;
  if (!pending || !pending.urls || !pending.urls.length) return;
  var path = mpv.getString("path") || "";
  if (!sameMedia(path, pending.video)) return;
  pending.urls.forEach(function (entry, index) {
    mpv.command("sub-add", [entry.url, index === 0 ? "select" : "auto", entry.name, "und"]);
  });
  var count = pending.urls.length;
  publish("status", { text: "Loaded " + count + " subtitle" + (count === 1 ? "" : "s") });
});
