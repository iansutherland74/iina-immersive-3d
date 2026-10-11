// WebDAV browser. The listing uses PROPFIND. The password is stored in the
// Keychain and is sent as an Authorization header. The media URL itself has
// no user or password, so playback history does not receive them.

// BEGIN PURE
var VIDEO_EXTENSIONS = {
  mkv: 1, mp4: 1, m4v: 1, mov: 1, avi: 1, wmv: 1, flv: 1, webm: 1,
  ts: 1, m2ts: 1, mts: 1, mpg: 1, mpeg: 1, vob: 1, ogv: 1, ogm: 1,
  "3gp": 1, "3g2": 1, asf: 1, rm: 1, rmvb: 1, divx: 1, f4v: 1,
  m2v: 1, qt: 1, mxf: 1
};

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
  try {
    return decodeURIComponent(text);
  } catch (error) {
    return text;
  }
}

function tagText(block, name) {
  var re = new RegExp("<[^>]*:?" + name + "\\b[^>]*>([\\s\\S]*?)</[^>]*:?" + name + ">", "i");
  var match = block.match(re);
  return match ? decodeXML(match[1]).trim() : "";
}

function lastSegment(href) {
  var path = String(href).split("?")[0].split("#")[0];
  path = path.replace(/\/+$/, "");
  var parts = path.split("/");
  return safeDecode(parts[parts.length - 1] || "");
}

function displayName(href, name) {
  if (!name || name.indexOf("/") !== -1) return lastSegment(href);
  return name;
}

function extensionOf(name) {
  var dot = name.lastIndexOf(".");
  if (dot < 1 || dot === name.length - 1) return "";
  return name.slice(dot + 1).toLowerCase();
}

function isVideo(name, contentType) {
  if (VIDEO_EXTENSIONS[extensionOf(name)]) return true;
  return /^video\//i.test(contentType || "");
}

function originOf(url) {
  var match = String(url).match(/^(https?:\/\/[^/?#]+)/i);
  return match ? match[1] : "";
}

function stripUserinfo(url) {
  return String(url).replace(/^(https?:\/\/)([^/@]+)@/i, "$1");
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
  try {
    bare = decodeURIComponent(bare);
  } catch (error) {}
  return bare.replace(/\/+$/, "");
}

function directoryURL(url) {
  var bare = stripUserinfo(String(url)).split("?")[0].split("#")[0];
  return /\/$/.test(bare) ? bare : bare + "/";
}

function parseListing(xml, requestedURL) {
  var text = String(xml || "");
  var re = /<[^>]*:?response\b[^>]*>([\s\S]*?)<\/[^>]*:?response>/gi;
  var selfKey = resourceKey(requestedURL);
  var entries = [];
  var match;
  while ((match = re.exec(text))) {
    var block = match[1];
    var href = tagText(block, "href");
    if (!href) continue;
    var absolute = resolveHref(requestedURL, href);
    if (resourceKey(absolute) === selfKey) continue;
    var collection = /<[^>]*:?collection\b/i.test(block);
    var contentType = tagText(block, "getcontenttype");
    var name = displayName(absolute, tagText(block, "displayname"));
    if (!name || name === "." || name === "..") continue;
    if (!collection && !isVideo(name, contentType)) continue;
    var length = parseInt(tagText(block, "getcontentlength"), 10);
    entries.push({
      name: name,
      href: collection ? directoryURL(absolute) : absolute.replace(/\/+$/, ""),
      folder: collection,
      size: isFinite(length) ? length : 0
    });
  }
  entries.sort(function (a, b) {
    if (a.folder !== b.folder) return a.folder ? -1 : 1;
    return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0;
  });
  return entries;
}

function basicHeader(username, password) {
  return "Authorization: Basic " + base64Encode(username + ":" + password);
}

function validServer(url) {
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

var KEYCHAIN_SERVICE = "webdav";
var attached = false;
var sessionPassword = "";
var appliedHeader = false;
var savedHeader = null;
var serverHost = "";

function preference(key) {
  var value = preferences.get(key);
  return value == null ? "" : String(value);
}

function readPassword(username) {
  if (!username) return "";
  if (sessionPassword) return sessionPassword;
  var stored = utils.keychainRead(KEYCHAIN_SERVICE, username);
  return stored && stored !== false ? String(stored) : "";
}

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

function settingsPayload(warning) {
  var username = preference("username");
  var serverURL = preference("serverURL");
  return {
    serverURL: serverURL,
    username: username,
    hasPassword: readPassword(username).length > 0,
    https: /^https:\/\//i.test(serverURL),
    warning: warning || ""
  };
}

function restoreAuthHeader() {
  if (!appliedHeader) return;
  mpv.set("http-header-fields", savedHeader || "");
  appliedHeader = false;
  savedHeader = null;
}

function applyAuthHeader(username, password) {
  if (!appliedHeader) {
    savedHeader = mpv.getString("http-header-fields");
    appliedHeader = true;
  }
  mpv.set("http-header-fields", basicHeader(username, password));
}

function hostOf(url) {
  var match = String(url || "").match(/^https?:\/\/([^/?#]+)/i);
  if (!match) return "";
  return match[1].replace(/:\d+$/, "").toLowerCase();
}

function propfind(url, username, password) {
  if (!http.request) {
    return Promise.reject({ statusCode: 0, reason: "This IINA build cannot send PROPFIND." });
  }
  return http.request("PROPFIND", directoryURL(url), {
    headers: {
      Authorization: "Basic " + base64Encode(username + ":" + password),
      Depth: "1",
      "Content-Type": "application/xml; charset=utf-8"
    },
    body: "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
      "<d:propfind xmlns:d=\"DAV:\">" +
      "<d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/><d:getcontentlength/></d:prop>" +
      "</d:propfind>",
    timeout: 45
  });
}

function explain(error) {
  var code = error && error.statusCode;
  if (code === 401 || code === 403) return "The server refused the username or password.";
  if (code === 404) return "That folder was not found.";
  if (!code) return (error && error.reason) || "The server could not be reached.";
  return "The server returned " + code + ".";
}

function list(url) {
  var username = preference("username");
  var password = readPassword(username);
  var serverURL = preference("serverURL").trim();
  if (!validServer(serverURL)) {
    publish("listing", { url: url || "", entries: [], error: "Enter a server address that starts with https:// or http://." });
    return;
  }
  if (!username || !password) {
    publish("listing", { url: url || serverURL, entries: [], error: "Enter the username and password, then connect." });
    return;
  }
  var target = directoryURL(url || serverURL);
  serverHost = hostOf(target);
  publish("listing", { url: target, entries: [], error: "", loading: true });
  var pending;
  try {
    pending = propfind(target, username, password);
  } catch (error) {
    publish("listing", { url: target, entries: [], error: "Could not send PROPFIND." });
    return;
  }
  if (!pending || !pending.then) {
    publish("listing", { url: target, entries: [], error: "This IINA build cannot send PROPFIND." });
    return;
  }
  pending.then(function (response) {
    var entries = parseListing(response.text || "", target);
    publish("listing", { url: target, entries: entries, error: entries.length ? "" : "No folders or videos here." });
  }).catch(function (error) {
    publish("listing", { url: target, entries: [], error: explain(error) });
  });
}

function play(href) {
  var username = preference("username");
  var password = readPassword(username);
  if (!username || !password) {
    publish("status", { text: "Enter the username and password first." });
    return;
  }
  var url = stripUserinfo(href);
  if (!/^https?:\/\//i.test(url)) {
    publish("status", { text: "That file has no http address." });
    return;
  }
  serverHost = hostOf(url);
  applyAuthHeader(username, password);
  core.open(url);
  publish("status", { text: "Playing " + lastSegment(url) });
}

function save(data) {
  var serverURL = String(data.serverURL || "").trim();
  var username = String(data.username || "").trim();
  var password = String(data.password || "");
  if (!validServer(serverURL)) {
    publish("settings", settingsPayload("Enter a server address that starts with https:// or http://."));
    return;
  }
  preferences.set("serverURL", serverURL);
  preferences.set("username", username);
  preferences.sync();
  var warning = /^https:\/\//i.test(serverURL) ? "" : "This address is not HTTPS. The password crosses the network without encryption.";
  if (password) {
    var wrote = utils.keychainWrite(KEYCHAIN_SERVICE, username, password);
    if (wrote === true) {
      sessionPassword = "";
    } else {
      sessionPassword = password;
      warning = "The password could not be saved in the Keychain. It stays in memory until IINA quits, and it is not written into plugin preferences.";
    }
  }
  publish("settings", settingsPayload(warning));
  list(directoryURL(serverURL));
}

function attach() {
  if (attached) return;
  attached = true;
  sidebar.loadFile("sidebar.html");
  sidebar.onMessage("ready", function () {
    publish("settings", settingsPayload(""));
    if (preference("username") && readPassword(preference("username"))) {
      list(preference("serverURL"));
    }
  });
  sidebar.onMessage("save", save);
  sidebar.onMessage("open", function (data) {
    list(data && data.href);
  });
  sidebar.onMessage("play", function (data) {
    if (data && data.href) play(data.href);
  });
}

menu.addItem(menu.item("WebDAV Browser", function () {
  attach();
  sidebar.show();
}, {}));
menu.forceUpdate();

event.on("iina.window-loaded", attach);

event.on("iina.file-started", function () {
  if (!appliedHeader) return;
  var path = mpv.getString("path") || "";
  if (serverHost && hostOf(path) === serverHost) return;
  restoreAuthHeader();
});
