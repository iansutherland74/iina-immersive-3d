const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.join(__dirname, "..", "main.js"), "utf8");
const start = source.indexOf("// BEGIN PURE");
const end = source.indexOf("// END PURE");
if (start < 0 || end < start) {
  throw new Error("pure section markers missing");
}
const api = new Function(
  source.slice(start, end) +
    "\nreturn { parseListing, base64Encode, resolveHref, directoryURL, isVideo, validServer, basicHeader, resourceKey, stripUserinfo };"
)();

function assert(cond, message) {
  if (!cond) throw new Error(message);
}

assert(api.base64Encode("user:pass") === Buffer.from("user:pass").toString("base64"), "ascii basic");
assert(api.base64Encode("päss") === Buffer.from("päss", "utf8").toString("base64"), "utf8 basic");
assert(api.basicHeader("user", "päss").startsWith("Authorization: Basic "), "header name");
assert(!api.basicHeader("user", "secret").includes("secret"), "header is encoded");

assert(api.validServer("https://webdav.febbox.com"), "febbox");
assert(api.validServer("http://192.168.1.20:5005/dav"), "nas");
assert(!api.validServer("file:///tmp"), "file rejected");
assert(!api.validServer("webdav.febbox.com"), "scheme required");

const base = "https://cloud.example/remote.php/dav/files/alice/";
const xml = `<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/files/alice/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/Movies/</d:href>
    <d:propstat><d:prop>
      <d:displayname>Movies</d:displayname>
      <d:resourcetype><d:collection/></d:resourcetype>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/Movies/Show%20Title.mkv</d:href>
    <d:propstat><d:prop>
      <d:getcontenttype>video/x-matroska</d:getcontenttype>
      <d:getcontentlength>1000</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/note.txt</d:href>
    <d:propstat><d:prop><d:getcontenttype>text/plain</d:getcontenttype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>https://user:secret@cloud.example/remote.php/dav/files/alice/clip.mp4</d:href>
    <d:propstat><d:prop><d:getcontenttype>video/mp4</d:getcontenttype><d:getcontentlength>20</d:getcontentlength></d:prop></d:propstat>
  </d:response>
  <response>
    <href>/remote.php/dav/files/alice/noext</href>
    <propstat><prop><getcontenttype>video/mp4</getcontenttype></prop></propstat>
  </response>
</d:multistatus>`;

const entries = api.parseListing(xml, base);
assert(entries.length === 4, "kept folder, two videos, and a video content type, got " + entries.length);
assert(entries[0].folder && entries[0].name === "Movies", "folder first");
assert(entries.some((e) => e.name === "Show Title.mkv" && e.size === 1000), "decoded video");
assert(entries.every((e) => !String(e.href).includes("secret") && !String(e.href).includes("user:")), "password stripped");
assert(entries.some((e) => e.name === "clip.mp4" && e.href.startsWith("https://cloud.example/")), "userinfo removed");
assert(entries.some((e) => e.name === "noext"), "content type counts");
assert(!entries.some((e) => e.name === "note.txt"), "text hidden");
assert(api.resourceKey(api.directoryURL(base)) === api.resourceKey(base), "directory key");
assert(api.resolveHref(base, "/remote.php/dav/files/alice/Movies/").startsWith("https://cloud.example/"), "absolute path");

const feb = api.parseListing(
  `<D:multistatus xmlns:D="DAV:"><D:response><D:href>/Film.mkv</D:href><D:propstat><D:prop><D:getcontentlength>5</D:getcontentlength></D:prop></D:propstat></D:response></D:multistatus>`,
  "https://webdav.febbox.com/"
);
assert(feb.length === 1 && feb[0].href === "https://webdav.febbox.com/Film.mkv", "febbox href " + (feb[0] && feb[0].href));
assert(api.isVideo("a.MKV", "") && !api.isVideo("a.jpg", "image/jpeg"), "extension check");

console.log("webdav parser checks passed");
