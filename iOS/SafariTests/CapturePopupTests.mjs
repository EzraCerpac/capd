import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { captureMessage, startCapturePopup } from "../SafariExtension/Resources/capture-popup.mjs";

function fixture({ tabs = [{ url: "https://example.invalid/article", title: "Page title" }], send } = {}) {
  const elements = new Map();
  for (const id of ["capture-form", "source", "title", "note", "save", "status"]) {
    elements.set(id, {
      value: "", disabled: id === "save", textContent: "", listeners: {},
      addEventListener(name, callback) { this.listeners[name] = callback; },
    });
  }
  const messages = [];
  const queries = [];
  return {
    elements, messages, queries,
    document: { getElementById: (id) => elements.get(id) },
    browser: {
      tabs: { async query(query) { queries.push(query); if (tabs instanceof Error) throw tabs; return tabs; } },
      runtime: {
        async sendNativeMessage(app, message) {
          messages.push({ app, message });
          return send ? send(message) : { status: "saved" };
        },
      },
    },
    submit() { return elements.get("capture-form").listeners.submit({ preventDefault() {} }); },
  };
}

test("opening previews only; explicit Save sends edited fields once", async () => {
  const f = fixture();
  await startCapturePopup(f);
  assert.deepEqual(f.queries, [{ active: true, currentWindow: true }]);
  assert.equal(f.messages.length, 0);
  assert.equal(f.elements.get("source").value, "https://example.invalid/article");
  f.elements.get("title").value = "<script>untrusted title</script>";
  f.elements.get("note").value = "Reviewed note";
  await Promise.all([f.submit(), f.submit()]);
  await f.submit();
  assert.equal(f.messages.length, 1);
  assert.deepEqual(f.messages[0], {
    app: "dev.jxd.capd.iphone.prototype",
    message: {
      command: "capd.capture-link.v1", url: "https://example.invalid/article",
      title: "<script>untrusted title</script>", note: "Reviewed note",
    },
  });
  assert.equal(f.elements.get("save").disabled, true);
  assert.match(f.elements.get("status").textContent, /Saved to this device/);
});

test("unsupported, missing, credentialed and denied pages never send", async () => {
  for (const tabs of [
    [], [{}], [{ url: "about:blank" }], [{ url: "file:///private/example" }],
    [{ url: "https://user:secret@example.invalid/" }], new Error("access denied"),
  ]) {
    const f = fixture({ tabs });
    await startCapturePopup(f);
    await f.submit();
    assert.equal(f.elements.get("save").disabled, true);
    assert.equal(f.messages.length, 0);
    assert.match(f.elements.get("status").textContent, /HTTP or HTTPS/);
  }
});

test("UTF8 limits fail before messaging and allow editing", async () => {
  const f = fixture();
  await startCapturePopup(f);
  f.elements.get("note").value = "🧭".repeat(4097);
  await f.submit();
  assert.equal(f.messages.length, 0);
  assert.equal(f.elements.get("save").disabled, false);
  f.elements.get("note").value = "Short note";
  await f.submit();
  assert.equal(f.messages.length, 1);
  assert.throws(() => captureMessage("javascript:alert(1)", "", ""));
});

test("native failure retains draft, hides details and never retries automatically", async () => {
  for (const send of [() => ({ status: "error", details: "private path" }), () => { throw new Error("secret"); }]) {
    const f = fixture({ send });
    await startCapturePopup(f);
    f.elements.get("note").value = "Keep my note";
    await f.submit();
    assert.equal(f.messages.length, 1);
    assert.equal(f.elements.get("note").value, "Keep my note");
    assert.equal(f.elements.get("save").disabled, false);
    assert.equal(f.elements.get("status").textContent, "Couldn’t confirm the save. Check capd before trying again.");
  }
});

test("manifest only grants activeTab and nativeMessaging; no persistent collection", async () => {
  const manifest = JSON.parse(await readFile(new URL("../SafariExtension/Resources/manifest.json", import.meta.url)));
  assert.deepEqual(manifest.permissions.toSorted(), ["activeTab", "nativeMessaging"]);
  for (const key of ["host_permissions", "optional_permissions", "content_scripts", "background", "externally_connectable"]) {
    assert.equal(manifest[key], undefined);
  }
  assert.match(manifest.content_security_policy.extension_pages, /connect-src 'none'/);
});
