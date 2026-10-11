// Saved servers for WebDAV, FTP, FTPS, SMB, SFTP, Jellyfin, Plex, Emby, and DLNA.
// Passwords stay in the Keychain. Listing and playback rules live in library.js.

var lib = require("./library.js");
var base64Encode = lib.base64Encode;
var parseListing = lib.parseListing;
var directoryURL = lib.directoryURL;
var parseFTPAddress = lib.parseFTPAddress;
var playbackScheme = lib.playbackScheme;
var encodePath = lib.encodePath;
var curlUserLine = lib.curlUserLine;
var parseFTPList = lib.parseFTPList;
var lastSegment = lib.lastSegment;
var credentialsFromAddress = lib.credentialsFromAddress;
var validWebDAV = lib.validWebDAV;
var subtitleFor = lib.subtitleFor;
var ftpPlaybackURL = lib.ftpPlaybackURL;
var stripUserinfo = lib.stripUserinfo;
var sameMedia = lib.sameMedia;


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
var pendingPlay = null;
var currentListing = "";
var currentDisplay = "";
var playbackQueue = [];
var queueHref = "";
var activeItem = null;
var haveFile = false;
var replacing = false;
var smbMounted = "";
var sessions = {};
var resumeTicks = 0;
var resumeTimer = null;

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

function loadJSON(key, fallback) {
  var raw = preferences.get(key);
  if (!raw) return fallback;
  try {
    var parsed = JSON.parse(String(raw));
    if (fallback && Object.prototype.toString.call(fallback) === "[object Array]") {
      return Object.prototype.toString.call(parsed) === "[object Array]" ? parsed : fallback;
    }
    if (parsed && typeof parsed === "object") return parsed;
  } catch (error) {}
  return fallback;
}

function storeJSON(key, value) {
  preferences.set(key, JSON.stringify(value));
  preferences.sync();
}

function loadServers() {
  return loadJSON("servers", []);
}

function storeServers(list) {
  storeJSON("servers", list);
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
  var match = stripUserinfo(url).match(/^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i);
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
  publish("servers", {
    servers: publicServers(),
    warning: warning || "",
    saved: !!saved,
    hasOSKey: readPassword("opensubtitles").length > 0
  });
}

function formError(text) {
  publish("form-error", { text: text || "" });
}

function findEntry(href) {
  for (var i = 0; i < currentEntries.length; i++) {
    if (currentEntries[i].href === href) return currentEntries[i];
  }
  return null;
}

function decorate(entries) {
  var mode = preferences.get("sort") || "name";
  var favs = loadJSON("favourites", []);
  var saved = loadJSON("resume", {});
  var serverId = currentServer && currentServer.id;
  return lib.sortEntries(entries, mode).filter(function (entry) {
    return entry.kind !== "subtitle";
  }).map(function (entry) {
    var row = saved[lib.resumeKey(serverId, entry.href)] || {};
    var position = row.position || entry.resume || 0;
    var duration = row.duration || entry.duration || 0;
    return {
      name: entry.name,
      href: entry.href,
      folder: !!entry.folder,
      kind: entry.kind,
      size: entry.size || 0,
      date: entry.date || 0,
      image: entry.image || "",
      progress: lib.resumeFraction(position, duration),
      favourite: lib.isFavourite(favs, serverId, entry.href)
    };
  });
}

function publishListing(spec) {
  if (spec.url != null) currentListing = spec.url;
  if (spec.display != null) currentDisplay = spec.display;
  publish("listing", {
    title: spec.title || "",
    url: spec.url || "",
    display: spec.display || spec.url || "",
    entries: spec.loading ? [] : decorate(spec.entries || []),
    error: spec.error || "",
    loading: !!spec.loading,
    sort: preferences.get("sort") || "name",
    autoplay: preferences.get("autoplay") !== "0"
  });
  if (!spec.loading && pendingPlay) {
    var item = pendingPlay;
    pendingPlay = null;
    play(item.href, item.name);
  }
}

function httpText(method, url, headers, body) {
  if (!http.request) return Promise.reject({ statusCode: 0, reason: "This IINA build cannot send this request." });
  var pending;
  try {
    pending = http.request(method, url, { headers: headers || {}, body: body || "", timeout: 45 });
  } catch (error) {
    return Promise.reject({ statusCode: 0, reason: "The request could not be sent." });
  }
  if (!pending || !pending.then) return Promise.reject({ statusCode: 0, reason: "This IINA build cannot send this request." });
  return pending.then(function (response) { return response || {}; });
}

function readJSON(response) {
  try { return JSON.parse(response.text || "{}"); } catch (error) { return {}; }
}

function mediaHeader(server) {
  var session = sessions[server.id] || {};
  if (server.protocol === "plex") return { "X-Plex-Token": session.token || "", Accept: "application/json" };
  return { "X-Emby-Token": session.token || "", Accept: "application/json" };
}

function writeScript(name, contents) {
  try { file.write(name, contents); } catch (error) { return ""; }
  return utils.resolvePath(name) || "";
}

function runExec(bin, args) {
  try {
    var pending = utils.exec(bin, args, null, null, null);
    if (!pending || !pending.then) return Promise.reject(new Error("exec"));
    return pending;
  } catch (error) {
    return Promise.reject(error);
  }
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
    publishListing({ title: server.name, url: url, display: url, entries: [], error: "Enter the password for this server." });
    return;
  }
  if (!http.request) {
    publishListing({ title: server.name, url: url, display: url, entries: [], error: "This IINA build cannot send PROPFIND." });
    return;
  }
  var target = directoryURL(url);
  activeHost = hostOf(target);
  publishListing({ title: server.name, url: target, display: target, entries: [], loading: true });
  var pending;
  try {
    pending = http.request("PROPFIND", target, {
      headers: {
        Authorization: "Basic " + base64Encode(server.username + ":" + password),
        Depth: "1",
        "Content-Type": "application/xml; charset=utf-8"
      },
      body: "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
        "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>",
      timeout: 45
    });
  } catch (error) {
    publishListing({ title: server.name, url: target, display: target, entries: [], error: "Could not send PROPFIND." });
    return;
  }
  if (!pending || !pending.then) {
    publishListing({ title: server.name, url: target, display: target, entries: [], error: "This IINA build cannot send PROPFIND." });
    return;
  }
  pending.then(function (response) {
    if (token !== listToken || currentServer !== server) return;
    currentEntries = parseListing(response.text || "", target);
    publishListing({
      title: server.name,
      url: target,
      display: target,
      entries: currentEntries,
      error: visibleEntries(currentEntries).length ? "" : "No folders or videos here."
    });
  }).catch(function (error) {
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publishListing({ title: server.name, url: target, display: target, entries: [], error: explainHTTP(error) });
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
    publishListing({ title: server.name, url: "", display: "", entries: [], error: "Enter a host, or an ftp:// address." });
    return;
  }
  if (!server.username || !password) {
    publishListing({ title: server.name, url: address.path, display: address.host, entries: [], error: "Enter the username and password." });
    return;
  }
  var path = dirPath || address.path || "/";
  if (path.charAt(0) !== "/") path = "/" + path;
  path = directoryURL(path);
  var listingScheme = playbackScheme(server.protocol, address.implicit);
  var listURL = listingScheme + "://" + address.host + encodePath(path);
  var display = address.host + path;
  activeHost = hostOf(listURL);
  publishListing({ title: server.name, url: path, display: display, entries: [], loading: true });
  var stamp = Date.now().toString(36) + "-" + token;
  var configName = "@tmp/curl-auth-" + stamp;
  var outputName = "@tmp/curl-list-" + stamp;
  var configPath = utils.resolvePath(configName);
  var outputPath = utils.resolvePath(outputName);
  if (/[\r\n]/.test(String(server.username) + String(password))) {
    publishListing({ title: server.name, url: path, display: display, entries: [], error: "The username or password contains a line break." });
    return;
  }
  if (!configPath || !outputPath) {
    publishListing({ title: server.name, url: path, display: display, entries: [], error: "The plugin temp folder is not available." });
    return;
  }
  var authLine = curlUserLine(server.username, password);
  try {
    file.write(configName, authLine);
  } catch (error) {
    publishListing({ title: server.name, url: path, display: display, entries: [], error: "The password file could not be written." });
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
    publishListing({ title: server.name, url: path, display: display, entries: [], error: "curl could not be started. The file-system permission is required." });
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
      publishListing({ title: server.name, url: path, display: display, entries: [], error: detail });
      return;
    }
    currentEntries = parseFTPList(body).map(function (entry) {
      entry.href = joinFTP(path, entry.name, entry.folder);
      return entry;
    });
    publishListing({
      title: server.name,
      url: path,
      display: display,
      entries: currentEntries,
      error: visibleEntries(currentEntries).length ? "" : "No folders or videos here."
    });
  }).catch(function () {
    removeLocal(configName);
    removeLocal(outputName);
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publishListing({ title: server.name, url: path, display: display, entries: [], error: "curl could not be started." });
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
  var protocol = currentServer.protocol;
  if (protocol === "webdav") listWebDAV(currentServer, href || currentServer.url);
  else if (protocol === "ftp" || protocol === "ftps") listFTP(currentServer, href);
  else if (protocol === "sftp") listSFTP(currentServer, href);
  else if (protocol === "smb") listSMB(currentServer, href);
  else if (protocol === "jellyfin" || protocol === "emby") listJellyfin(currentServer, href || "");
  else if (protocol === "plex") listPlex(currentServer, href || "");
  else if (protocol === "dlna") listDLNA(currentServer, href || "0");
}

function serviceRoot(server) {
  return String(server.url || "").replace(/\/+$/, "");
}

function listSFTP(server, dirPath) {
  var token = ++listToken;
  var password = readPassword(server.id);
  var address = lib.parseSFTPAddress(server.url);
  if (!address) {
    publishListing({ title: server.name, url: "", entries: [], error: "Enter a host, or an sftp:// address." });
    return;
  }
  if (!server.username || !password) {
    publishListing({ title: server.name, url: address.path, display: address.host, entries: [], error: "Enter the username and password." });
    return;
  }
  var path = dirPath || address.path || "/";
  if (path.charAt(0) !== "/") path = "/" + path;
  path = directoryURL(path);
  var display = address.host + (address.port ? ":" + address.port : "") + path;
  publishListing({ title: server.name, url: path, display: display, entries: [], loading: true });
  var stamp = Date.now().toString(36) + "-" + token;
  var askName = "@tmp/sftp-ask-" + stamp;
  var batchName = "@tmp/sftp-batch-" + stamp;
  var wrapName = "@tmp/sftp-run-" + stamp;
  var homePath = utils.resolvePath("@tmp/sftp-home");
  var askPath = writeScript(askName, lib.askpassScript(password));
  var batchPath = writeScript(batchName, lib.sftpBatch(path));
  var wrapPath = writeScript(wrapName, lib.sftpWrapper());
  if (!askPath || !batchPath || !wrapPath || !homePath) {
    publishListing({ title: server.name, url: path, display: display, entries: [], error: "The plugin temp folder is not available." });
    return;
  }
  runExec(wrapPath, [homePath, askPath, batchPath, server.username + "@" + address.host, address.port || ""]).then(function (result) {
    removeLocal(askName);
    removeLocal(batchName);
    removeLocal(wrapName);
    if (token !== listToken || currentServer !== server) return;
    if (!result || result.status !== 0) {
      currentEntries = [];
      publishListing({ title: server.name, url: path, display: display, entries: [], error: publicStderr(result && result.stderr, password) });
      return;
    }
    currentEntries = parseFTPList(result.stdout || "").map(function (entry) {
      entry.href = joinFTP(path, entry.name, entry.folder);
      return entry;
    });
    publishListing({
      title: server.name,
      url: path,
      display: display,
      entries: currentEntries,
      error: visibleEntries(currentEntries).length ? "" : "No folders or videos here."
    });
  }).catch(function () {
    removeLocal(askName);
    removeLocal(batchName);
    removeLocal(wrapName);
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publishListing({ title: server.name, url: path, display: display, entries: [], error: "sftp could not be started." });
  });
}

function unmountSMB() {
  if (!smbMounted) return Promise.resolve();
  var mounted = smbMounted;
  smbMounted = "";
  return runExec("/sbin/umount", [mounted]).catch(function () { return null; });
}

function listSMB(server, dirPath) {
  var token = ++listToken;
  var password = readPassword(server.id);
  var address = lib.parseSMBAddress(server.url);
  if (!address || !address.share) {
    publishListing({ title: server.name, entries: [], error: "Enter the host and the share, such as smb://nas/Media." });
    return;
  }
  if (!server.username || !password) {
    publishListing({ title: server.name, entries: [], error: "Enter the username and password." });
    return;
  }
  var rel = dirPath || address.path || "/";
  if (rel.charAt(0) !== "/") rel = "/" + rel;
  rel = directoryURL(rel);
  var display = address.host + "/" + address.share + rel;
  publishListing({ title: server.name, url: rel, display: display, entries: [], loading: true });
  var mountPath = utils.resolvePath("@tmp/smb-mnt");
  var scriptName = "@tmp/smb-mount-" + token;
  var scriptPath = writeScript(scriptName, lib.smbMountScript(server.username, password, address.host, address.share));
  if (!mountPath || !scriptPath) {
    publishListing({ title: server.name, url: rel, display: display, entries: [], error: "The plugin temp folder is not available." });
    return;
  }
  unmountSMB().then(function () {
    return runExec("/bin/mkdir", ["-p", mountPath]);
  }).then(function () {
    return runExec(scriptPath, [mountPath]);
  }).then(function (result) {
    removeLocal(scriptName);
    if (token !== listToken || currentServer !== server) return null;
    if (!result || result.status !== 0) {
      publishListing({ title: server.name, url: rel, display: display, entries: [], error: publicStderr(result && result.stderr, password) });
      return null;
    }
    smbMounted = mountPath;
    var localDir = mountPath + (rel === "/" ? "" : rel.replace(/\/$/, ""));
    return runExec("/bin/ls", ["-l", localDir]).then(function (listed) {
      if (token !== listToken || currentServer !== server) return;
      currentEntries = parseFTPList(listed && listed.stdout || "").map(function (entry) {
        entry.href = joinFTP(rel, entry.name, entry.folder);
        entry.local = localDir.replace(/\/$/, "") + "/" + entry.name;
        return entry;
      });
      publishListing({
        title: server.name,
        url: rel,
        display: display,
        entries: currentEntries,
        error: visibleEntries(currentEntries).length ? "" : "No folders or videos here."
      });
    });
  }).catch(function () {
    removeLocal(scriptName);
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publishListing({ title: server.name, url: rel, display: display, entries: [], error: "The share could not be mounted." });
  });
}

function jellyfinAuth(server, password) {
  var root = serviceRoot(server);
  var header = "MediaBrowser Client=\"IINA\", Device=\"Mac\", DeviceId=\"iina-remote-files\", Version=\"1.1.0\"";
  return httpText("POST", root + "/Users/AuthenticateByName", {
    "Content-Type": "application/json",
    Accept: "application/json",
    Authorization: header,
    "X-Emby-Authorization": header
  }, JSON.stringify({ Username: server.username, Pw: password })).then(function (response) {
    var payload = readJSON(response);
    if (!payload.AccessToken || !payload.User || !payload.User.Id) {
      throw { statusCode: response.statusCode || 401, reason: "The server did not return a token." };
    }
    sessions[server.id] = { token: payload.AccessToken, userId: payload.User.Id };
    return sessions[server.id];
  });
}

function plexHeaders(token) {
  var headers = {
    Accept: "application/json",
    "X-Plex-Client-Identifier": "iina-remote-files",
    "X-Plex-Product": "IINA",
    "X-Plex-Version": "1.1.0",
    "X-Plex-Device": "Mac",
    "X-Plex-Device-Name": "IINA"
  };
  if (token) headers["X-Plex-Token"] = token;
  return headers;
}

function plexAuth(server, password) {
  if (!server.username && password) {
    sessions[server.id] = { token: password };
    return Promise.resolve(sessions[server.id]);
  }
  if (!server.username || !password) return Promise.reject({ reason: "Enter a Plex token, or a plex.tv username and password." });
  var headers = plexHeaders("");
  headers.Authorization = "Basic " + base64Encode(server.username + ":" + password);
  return httpText("POST", "https://plex.tv/users/sign_in.json", headers, "").then(function (response) {
    var payload = readJSON(response);
    var token = payload.user && payload.user.authToken;
    if (!token) throw { statusCode: response.statusCode || 401, reason: "Plex did not return a token. Paste an X-Plex-Token instead." };
    sessions[server.id] = { token: token };
    return sessions[server.id];
  });
}

function ensureSession(server) {
  if (sessions[server.id] && (sessions[server.id].token || sessions[server.id].control)) return Promise.resolve(sessions[server.id]);
  if (server.protocol === "dlna") return Promise.resolve({});
  var password = readPassword(server.id);
  if (server.protocol === "plex") return plexAuth(server, password);
  if (!password) return Promise.reject({ reason: "Enter the password for this server." });
  return jellyfinAuth(server, password);
}

function withImages(server, entries) {
  var session = sessions[server.id] || {};
  return entries.map(function (entry) {
    if (server.protocol === "plex" && entry.thumb) entry.image = lib.plexImage(serviceRoot(server), entry.thumb, session.token);
    else if (entry.hasImage) entry.image = lib.jellyfinImage(serviceRoot(server), entry.itemId, session.token);
    return entry;
  });
}

function listJellyfin(server, parentId) {
  var token = ++listToken;
  var root = serviceRoot(server);
  publishListing({ title: server.name, url: parentId || "", display: root, entries: [], loading: true });
  ensureSession(server).then(function (session) {
    var path = parentId
      ? "/Users/" + encodeURIComponent(session.userId) + "/Items?ParentId=" + encodeURIComponent(parentId) + "&Limit=200&Fields=DateCreated,MediaSources,PremiereDate&EnableImageTypes=Primary"
      : "/Users/" + encodeURIComponent(session.userId) + "/Views";
    return httpText("GET", root + path, mediaHeader(server), "");
  }).then(function (response) {
    if (!response || token !== listToken || currentServer !== server) return;
    currentEntries = withImages(server, lib.jellyfinEntries(readJSON(response)));
    publishListing({
      title: server.name,
      url: parentId || "",
      display: root,
      entries: currentEntries,
      error: visibleEntries(currentEntries).length ? "" : "No folders or videos here. A folder shows the first 200 items."
    });
  }).catch(function (error) {
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publishListing({ title: server.name, url: parentId || "", entries: [], error: explainHTTP(error) });
  });
}

function listPlex(server, href) {
  var token = ++listToken;
  var root = serviceRoot(server);
  var path = href || "/library/sections";
  publishListing({ title: server.name, url: path, display: root + path, entries: [], loading: true });
  ensureSession(server).then(function () {
    return httpText("GET", root + path, plexHeaders(sessions[server.id].token), "");
  }).then(function (response) {
    if (!response || token !== listToken || currentServer !== server) return;
    currentEntries = withImages(server, lib.plexEntries(readJSON(response)));
    publishListing({
      title: server.name,
      url: path,
      display: root + path,
      entries: currentEntries,
      error: visibleEntries(currentEntries).length ? "" : "No folders or videos here."
    });
  }).catch(function (error) {
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publishListing({ title: server.name, url: path, entries: [], error: explainHTTP(error) });
  });
}

function listDLNA(server, objectId) {
  var token = ++listToken;
  var id = objectId || "0";
  publishListing({ title: server.name, url: id, display: server.name, entries: [], loading: true });
  var start = sessions[server.id] && sessions[server.id].control
    ? Promise.resolve(sessions[server.id])
    : httpText("GET", server.url, { Accept: "text/xml" }, "").then(function (response) {
      var device = lib.parseDevice(response.text || "");
      if (!device.control) throw { reason: "That description has no content directory." };
      sessions[server.id] = { control: lib.resolveControl(server.url, device.control), name: device.name || server.name };
      return sessions[server.id];
    });
  start.then(function (session) {
    return httpText("POST", session.control, {
      "Content-Type": "text/xml; charset=utf-8",
      SOAPAction: "\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\""
    }, lib.dlnaBrowseBody(id));
  }).then(function (response) {
    if (!response || token !== listToken || currentServer !== server) return;
    currentEntries = lib.parseDIDL(lib.didlFromSoap(response.text || ""));
    publishListing({
      title: (sessions[server.id] && sessions[server.id].name) || server.name,
      url: id,
      display: server.url,
      entries: currentEntries,
      error: visibleEntries(currentEntries).length ? "" : "No folders or videos here. A folder shows the first 200 items."
    });
  }).catch(function (error) {
    if (token !== listToken || currentServer !== server) return;
    currentEntries = [];
    publishListing({ title: server.name, url: id, entries: [], error: explainHTTP(error) });
  });
}

function subtitleURLs(videoName, username, password, server) {
  return currentEntries.filter(function (entry) {
    return entry.kind === "subtitle" && subtitleFor(videoName, entry.name);
  }).map(function (entry) {
    if (server.protocol === "smb" && entry.local) return { url: entry.local, name: entry.name };
    if (server.protocol === "sftp") {
      var sftp = lib.parseSFTPAddress(server.url);
      if (!sftp) return null;
      return { url: ftpPlaybackURL("sftp", username, password, sftp.host + (sftp.port ? ":" + sftp.port : ""), entry.href), name: entry.name };
    }
    if (server.protocol === "ftp" || server.protocol === "ftps") {
      var ftp = parseFTPAddress(server.protocol, server.url);
      if (!ftp) return null;
      return { url: ftpPlaybackURL(playbackScheme(server.protocol, ftp.implicit), username, password, ftp.host, entry.href), name: entry.name };
    }
    if (/^https?:\/\//i.test(entry.href || "")) return { url: entry.href, name: entry.name };
    return null;
  }).filter(function (entry) { return entry; });
}

function applyRawHeader(value) {
  if (!appliedHeader) {
    savedHeader = mpv.getString("http-header-fields");
    appliedHeader = true;
  }
  mpv.set("http-header-fields", value);
}

function play(href, name) {
  if (!currentServer) return;
  var server = currentServer;
  var entry = findEntry(href) || { href: href, name: name || lastSegment(href) };
  var videoName = name || entry.name || lastSegment(href);
  var password = readPassword(server.id);
  if (server.protocol !== "dlna" && !password) {
    publish("status", { text: "Enter the password for this server." });
    return;
  }
  if (haveFile) replacing = true;
  var playback = "";
  if (server.protocol === "webdav") {
    playback = stripUserinfo(href);
    activeHost = hostOf(playback);
    restoreTLS();
    restoreStream();
    applyHeader(server.username, password);
    core.open(playback);
  } else if (server.protocol === "ftp" || server.protocol === "ftps") {
    var address = parseFTPAddress(server.protocol, server.url);
    if (!address) return;
    playback = ftpPlaybackURL(playbackScheme(server.protocol, address.implicit), server.username, password, address.host, href);
    activeHost = hostOf(playback);
    restoreHeader();
    if (server.insecureTLS) applyTLS(true);
    else restoreTLS();
    if (server.protocol === "ftps" && !address.implicit) applyStreamTLS(true);
    else restoreStream();
    mpv.command("loadfile", [playback, "replace"]);
  } else if (server.protocol === "sftp") {
    var sftp = lib.parseSFTPAddress(server.url);
    if (!sftp) return;
    playback = ftpPlaybackURL("sftp", server.username, password, sftp.host + (sftp.port ? ":" + sftp.port : ""), href);
    activeHost = hostOf(playback);
    restoreHeader();
    restoreTLS();
    restoreStream();
    mpv.command("loadfile", [playback, "replace"]);
  } else if (server.protocol === "smb") {
    if (!entry.local) {
      publish("status", { text: "Open the share again, then play the file." });
      replacing = false;
      return;
    }
    playback = entry.local;
    activeHost = "local";
    restoreHeader();
    restoreTLS();
    restoreStream();
    core.open(playback);
  } else if (server.protocol === "jellyfin" || server.protocol === "emby") {
    var session = sessions[server.id] || {};
    if (!session.token) {
      publish("status", { text: "Connect to the server again." });
      replacing = false;
      return;
    }
    playback = lib.jellyfinStream(serviceRoot(server), entry.itemId || href, entry.mediaSourceId);
    activeHost = hostOf(playback);
    restoreTLS();
    restoreStream();
    applyRawHeader("X-Emby-Token: " + session.token);
    core.open(playback);
  } else if (server.protocol === "plex") {
    var plexSession = sessions[server.id] || {};
    if (!entry.part) {
      publish("status", { text: "That item has no file." });
      replacing = false;
      return;
    }
    playback = lib.plexStream(serviceRoot(server), entry.part);
    activeHost = hostOf(playback);
    restoreTLS();
    restoreStream();
    applyRawHeader("X-Plex-Token: " + (plexSession.token || password));
    core.open(playback);
  } else if (server.protocol === "dlna") {
    if (!/^https?:\/\//i.test(href)) {
      publish("status", { text: "That item has no http address." });
      replacing = false;
      return;
    }
    playback = href;
    activeHost = hostOf(playback);
    restoreHeader();
    restoreTLS();
    restoreStream();
    core.open(playback);
  } else {
    replacing = false;
    return;
  }
  playbackQueue = currentEntries.filter(function (item) { return item.kind === "video"; });
  queueHref = href;
  activeItem = {
    serverId: server.id,
    href: href,
    parent: currentListing,
    name: videoName,
    protocol: server.protocol,
    serverResume: entry.resume || 0,
    duration: entry.duration || 0,
    didSeek: false,
    itemId: entry.itemId || "",
    ratingKey: entry.ratingKey || "",
    mediaSourceId: entry.mediaSourceId || ""
  };
  pendingSubtitles = { video: playback, urls: subtitleURLs(videoName, server.username, password, server), name: videoName };
  publish("status", { text: "Playing " + videoName });
}

function playFolder() {
  var videos = lib.sortEntries(currentEntries.filter(function (entry) { return entry.kind === "video"; }), "name");
  if (!videos.length) {
    publish("status", { text: "This folder has no videos." });
    return;
  }
  play(videos[0].href, videos[0].name);
}

function knownProtocols(protocol) {
  return protocol === "webdav" || protocol === "ftp" || protocol === "ftps" || protocol === "smb" || protocol === "sftp" || protocol === "jellyfin" || protocol === "plex" || protocol === "emby" || protocol === "dlna";
}

function saveServer(data) {
  var protocol = knownProtocols(data.protocol) ? data.protocol : "webdav";
  var pasted = credentialsFromAddress(data.url);
  var url = pasted.url;
  var username = String(data.username || "").trim() || pasted.username;
  var password = String(data.password || "") || pasted.password;
  var name = String(data.name || "").trim() || url || "Server";
  if (protocol !== "plex" && protocol !== "dlna" && !username) {
    formError("Enter a username.");
    return;
  }
  if (protocol === "webdav" && !validWebDAV(url)) {
    formError("A WebDAV address starts with https:// or http://.");
    return;
  }
  if ((protocol === "ftp" || protocol === "ftps") && !parseFTPAddress(protocol, url)) {
    formError("Enter a host, or an ftp:// address.");
    return;
  }
  if (protocol === "smb") {
    var smb = lib.parseSMBAddress(url);
    if (!smb || !smb.share) {
      formError("Enter the host and the share, such as smb://nas/Media.");
      return;
    }
  }
  if (protocol === "sftp" && !lib.parseSFTPAddress(url)) {
    formError("Enter a host, or an sftp:// address.");
    return;
  }
  if ((protocol === "jellyfin" || protocol === "emby" || protocol === "plex" || protocol === "dlna") && !lib.validHTTP(url)) {
    formError("The address starts with https:// or http://.");
    return;
  }
  var servers = loadServers();
  var id = String(data.id || "");
  var existing = null;
  for (var i = 0; i < servers.length; i++) if (servers[i].id === id) existing = servers[i];
  if (!existing) {
    id = "rf-" + Date.now().toString(36);
    existing = { id: id };
    servers.push(existing);
  }
  existing.name = name;
  existing.protocol = protocol;
  existing.url = url;
  existing.username = username;
  existing.insecureTLS = (protocol === "ftp" || protocol === "ftps") && !!data.insecureTLS;
  var warning = "";
  if (/^http:\/\//i.test(url) && protocol !== "ftp" && protocol !== "ftps" && protocol !== "smb" && protocol !== "sftp") {
    warning = "This address is not HTTPS. The password crosses the network without encryption.";
  }
  if (password) {
    if (utils.keychainWrite(KEYCHAIN_SERVICE, id, password) === true) {
      delete sessionPasswords[id];
    } else {
      sessionPasswords[id] = password;
      warning = "The password could not be saved in the Keychain. It stays in memory until IINA quits, and it is not written into the server list.";
    }
  }
  storeServers(servers);
  showServers(warning, true);
}

function connect(id, href) {
  var servers = loadServers();
  var server = null;
  for (var i = 0; i < servers.length; i++) if (servers[i].id === id) server = servers[i];
  if (!server) {
    showServers("That server is no longer saved.");
    return;
  }
  currentServer = server;
  list(href || null);
}

function savedRows(mode) {
  var servers = {};
  loadServers().forEach(function (server) { servers[server.id] = server; });
  return loadJSON(mode, []).map(function (row) {
    var server = servers[row.serverId];
    return {
      name: row.name,
      href: row.href,
      parent: row.parent || "",
      serverId: row.serverId,
      server: server ? server.name : "Removed server"
    };
  });
}

function discover() {
  publish("status", { text: "Looking for servers…" });
  var stamp = Date.now().toString(36);
  var browseName = "@tmp/discover-" + stamp + ".sh";
  var ssdpName = "@tmp/ssdp-" + stamp + ".pl";
  var lookupName = "@tmp/lookup-" + stamp + ".sh";
  var browsePath = writeScript(browseName, lib.discoverBrowseScript());
  var ssdpPath = writeScript(ssdpName, lib.ssdpScript());
  var rows = [];
  var jobs = [];
  if (browsePath) jobs.push(runExec(browsePath, []).then(function (result) {
    lib.parseDNSSD(result && result.stdout || "").forEach(function (row) { rows.push(row); });
  }).catch(function () {}));
  if (ssdpPath) jobs.push(runExec("/usr/bin/perl", [ssdpPath]).then(function (result) {
    lib.parseSSDP(result && result.stdout || "").forEach(function (row) {
      rows.push({ name: row.name, kind: "dlna", url: row.location, service: "ssdp" });
    });
  }).catch(function () {}));
  Promise.all(jobs).then(function () {
    removeLocal(browseName);
    removeLocal(ssdpName);
    var lookupPath = writeScript(lookupName, lib.lookupScript());
    var chain = Promise.resolve();
    rows.filter(function (row) { return row.service && row.service !== "ssdp" && !row.url; }).slice(0, 8).forEach(function (row) {
      chain = chain.then(function () {
        if (!lookupPath) return null;
        return runExec(lookupPath, [row.name, row.service]).then(function (result) {
          var found = lib.parseDNSSDLookup(result && result.stdout || "");
          if (found) row.url = lib.discoveredURL(row.kind, found.host, found.port);
        }).catch(function () {});
      });
    });
    return chain;
  }).then(function () {
    removeLocal(lookupName);
    publish("discovered", {
      rows: rows.map(function (row) {
        return { name: row.name, kind: row.kind, url: row.url || "" };
      })
    });
    publish("status", { text: rows.length ? "Found " + rows.length + " services. Choose one, then save it." : "No services answered. You can still type an address." });
  }).catch(function () {
    publish("status", { text: "Discovery could not be started." });
  });
}

function rememberPosition(stopped) {
  if (!activeItem) return;
  var position = 0;
  var duration = 0;
  try {
    position = mpv.getNumber("time-pos");
    duration = mpv.getNumber("duration");
  } catch (error) {
    return;
  }
  if (!(position >= 0)) return;
  var map = loadJSON("resume", {});
  map[lib.resumeKey(activeItem.serverId, activeItem.href)] = {
    position: position,
    duration: duration || activeItem.duration || 0,
    at: Date.now()
  };
  storeJSON("resume", map);
  resumeTicks += 1;
  if (stopped || resumeTicks % 3 === 0) reportProgress(position, !!stopped);
}

function reportProgress(position, stopped) {
  if (!activeItem || !currentServer || currentServer.id !== activeItem.serverId) return;
  var session = sessions[currentServer.id];
  if (!session || !session.token) return;
  var root = serviceRoot(currentServer);
  if ((currentServer.protocol === "jellyfin" || currentServer.protocol === "emby") && activeItem.itemId) {
    var headers = mediaHeader(currentServer);
    headers["Content-Type"] = "application/json";
    httpText("POST", root + (stopped ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress"), headers, JSON.stringify({
      ItemId: activeItem.itemId,
      MediaSourceId: activeItem.mediaSourceId,
      PositionTicks: Math.round(position * 10000000),
      IsPaused: false
    })).catch(function () {});
  } else if (currentServer.protocol === "plex" && activeItem.ratingKey) {
    var path = "/:/progress?key=" + encodeURIComponent(activeItem.ratingKey) +
      "&identifier=com.plexapp.plugins.library&time=" + Math.round(position * 1000) +
      "&state=" + (stopped ? "stopped" : "playing");
    httpText("GET", root + path, plexHeaders(session.token), "").catch(function () {});
  }
}

function recordHistory() {
  if (!activeItem) return;
  storeJSON("history", lib.pushHistory(loadJSON("history", []), {
    serverId: activeItem.serverId,
    href: activeItem.href,
    parent: activeItem.parent || "",
    name: activeItem.name,
    protocol: activeItem.protocol,
    at: Date.now()
  }, 40));
}

function searchOpenSubtitles(videoName) {
  var key = readPassword("opensubtitles");
  if (!key) {
    publish("status", { text: "No matching subtitle next to the video. Save an OpenSubtitles API key to search." });
    return;
  }
  var headers = {
    "Api-Key": key,
    "User-Agent": "IINA Immersive 3D v1.1.0",
    Accept: "application/json"
  };
  httpText("GET", "https://api.opensubtitles.com/api/v1/subtitles?query=" + encodeURIComponent(videoName), headers, "").then(function (response) {
    var choice = lib.opensubtitleChoice(readJSON(response), videoName);
    if (!choice) {
      publish("status", { text: "OpenSubtitles had no match." });
      return;
    }
    var downloadHeaders = {
      "Api-Key": key,
      "User-Agent": "IINA Immersive 3D v1.1.0",
      Accept: "application/json",
      "Content-Type": "application/json"
    };
    httpText("POST", "https://api.opensubtitles.com/api/v1/download", downloadHeaders, JSON.stringify({ file_id: choice.fileId })).then(function (downloaded) {
      var link = readJSON(downloaded).link;
      if (!link) {
        publish("status", { text: "OpenSubtitles did not return a file." });
        return;
      }
      var ext = ((choice.name || "").match(/\.([A-Za-z0-9]+)$/) || [])[1] || "srt";
      var dest = "@tmp/opensubtitle." + String(ext).toLowerCase();
      var saving = http.download ? http.download(link, dest, {}) : null;
      if (!saving || !saving.then) {
        publish("status", { text: "This IINA build cannot save the subtitle." });
        return;
      }
      saving.then(function () {
        var local = utils.resolvePath(dest);
        if (!local) return;
        mpv.command("sub-add", [local, "select", choice.name, "und"]);
        publish("status", { text: "Loaded a subtitle from OpenSubtitles." });
      }).catch(function () {
        publish("status", { text: "The OpenSubtitles file could not be saved." });
      });
    }).catch(function (error) {
      publish("status", { text: explainHTTP(error) });
    });
  }).catch(function (error) {
    publish("status", { text: explainHTTP(error) });
  });
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
    delete sessions[id];
    if (currentServer && currentServer.id === id) currentServer = null;
    showServers("");
  });
  sidebar.onMessage("connect", function (data) { connect(data && data.id); });
  sidebar.onMessage("servers", function () { showServers(""); });
  sidebar.onMessage("open", function (data) { list(data && data.href); });
  sidebar.onMessage("play", function (data) {
    if (data && data.href) play(data.href, data.name);
  });
  sidebar.onMessage("play-folder", playFolder);
  sidebar.onMessage("sort", function (data) {
    var mode = data && (data.mode === "date" || data.mode === "size") ? data.mode : "name";
    preferences.set("sort", mode);
    preferences.sync();
    if (currentServer) publishListing({ title: currentServer.name, url: currentListing, display: currentDisplay, entries: currentEntries });
  });
  sidebar.onMessage("autoplay", function (data) {
    preferences.set("autoplay", data && data.on ? "1" : "0");
    preferences.sync();
  });
  sidebar.onMessage("favourite", function (data) {
    if (!currentServer || !data || !data.href) return;
    var item = {
      serverId: currentServer.id,
      href: data.href,
      parent: currentListing,
      name: data.name || data.href,
      protocol: currentServer.protocol
    };
    storeJSON("favourites", lib.toggleFavourite(loadJSON("favourites", []), item));
    publishListing({ title: currentServer.name, url: currentListing, display: currentDisplay, entries: currentEntries });
  });
  sidebar.onMessage("history", function () { publish("saved-items", { mode: "history", rows: savedRows("history") }); });
  sidebar.onMessage("favourites", function () { publish("saved-items", { mode: "favourites", rows: savedRows("favourites") }); });
  sidebar.onMessage("play-saved", function (data) {
    if (!data || !data.serverId || !data.href) return;
    pendingPlay = { href: data.href, name: data.name };
    connect(data.serverId, data.parent || null);
  });
  sidebar.onMessage("discover", discover);
  sidebar.onMessage("save-os-key", function (data) {
    var key = String(data && data.key || "");
    if (!key) return;
    if (utils.keychainWrite(KEYCHAIN_SERVICE, "opensubtitles", key) === true) {
      delete sessionPasswords.opensubtitles;
      showServers("OpenSubtitles key saved in the Keychain.", true);
    } else {
      sessionPasswords.opensubtitles = key;
      showServers("The OpenSubtitles key could not be saved in the Keychain. It stays in memory until IINA quits.", true);
    }
  });
  if (!resumeTimer) {
    resumeTimer = setInterval(function () {
      if (haveFile) rememberPosition(false);
    }, 5000);
  }
  try {
    mpv.addHook("on_unload", 50, function () {
      rememberPosition(true);
      if (replacing) {
        replacing = false;
        return;
      }
      var eof = false;
      try { eof = mpv.getFlag("eof-reached"); } catch (error) {}
      haveFile = false;
      if (!eof || preferences.get("autoplay") === "0") return;
      var next = lib.nextInFolder(playbackQueue, queueHref);
      if (!next) return;
      setTimeout(function () { play(next.href, next.name); }, 400);
    });
  } catch (error) {}
}

menu.addItem(menu.item("Remote Files", function () {
  attach();
  sidebar.show();
}, {}));
menu.forceUpdate();

event.on("iina.window-loaded", attach);
event.on("iina.window-will-close", function () { unmountSMB(); });

event.on("iina.file-started", function () {
  var path = mpv.getString("path") || "";
  if (!path) return;
  var same = activeHost === "local"
    ? (path.charAt(0) === "/" || /^file:\/\//i.test(path))
    : (activeHost && hostOf(path) === activeHost);
  if (!same) {
    restoreHeader();
    restoreTLS();
    restoreStream();
    pendingSubtitles = null;
  }
});

event.on("iina.file-loaded", function () {
  haveFile = true;
  replacing = false;
  var path = mpv.getString("path") || "";
  var pending = pendingSubtitles;
  pendingSubtitles = null;
  var matches = pending && (path === pending.video || sameMedia(path, pending.video));
  if (activeItem && (!pending || matches)) {
    recordHistory();
    var saved = loadJSON("resume", {})[lib.resumeKey(activeItem.serverId, activeItem.href)] || {};
    var position = lib.resumeDecision(saved.position, saved.duration);
    if (!position) position = lib.resumeDecision(activeItem.serverResume, activeItem.duration);
    if (position && !activeItem.didSeek) {
      activeItem.didSeek = true;
      mpv.command("seek", [String(Math.floor(position)), "absolute"]);
    }
  }
  if (!pending || (pending.video && path && !matches)) return;
  if (pending.urls && pending.urls.length) {
    pending.urls.forEach(function (entry, index) {
      mpv.command("sub-add", [entry.url, index === 0 ? "select" : "auto", entry.name, "und"]);
    });
    publish("status", { text: "Loaded " + pending.urls.length + " subtitle" + (pending.urls.length === 1 ? "" : "s") });
    return;
  }
  searchOpenSubtitles(pending.name || "");
});
