const byteLength = (value) => new TextEncoder().encode(value).length;

export function captureMessage(url, title, note) {
  const parsed = new URL(url);
  if (!["http:", "https:"].includes(parsed.protocol) || !parsed.hostname || parsed.username || parsed.password) {
    throw new Error("unsupported-page");
  }
  if (byteLength(url) > 16384 || byteLength(title) > 4096 || byteLength(note) > 16384) {
    throw new Error("too-large");
  }
  return { command: "capd.capture-link.v1", url, title, note };
}

export async function startCapturePopup({ browser, document }) {
  const form = document.getElementById("capture-form");
  const source = document.getElementById("source");
  const title = document.getElementById("title");
  const note = document.getElementById("note");
  const save = document.getElementById("save");
  const status = document.getElementById("status");
  let ready = false;
  let saving = false;
  let saved = false;
  let url;

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!ready || saving || saved) return;
    let message;
    try {
      message = captureMessage(url, title.value, note.value);
    } catch {
      status.textContent = "The title or note is too long. Shorten it and save again.";
      return;
    }
    saving = true;
    save.disabled = true;
    title.disabled = true;
    note.disabled = true;
    status.textContent = "Saving…";
    try {
      const response = await browser.runtime.sendNativeMessage("dev.jxd.capd.iphone.prototype", message);
      if (response?.status !== "saved") throw new Error("save-failed");
      saved = true;
      save.textContent = "Saved";
      status.textContent = "Saved to this device. Open capd to deliver it to your connected library.";
    } catch {
      status.textContent = "Couldn’t confirm the save. Check capd before trying again.";
    } finally {
      saving = false;
      save.disabled = saved;
      title.disabled = saved;
      note.disabled = saved;
    }
  });

  try {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    url = tab?.url;
    captureMessage(url, "", "");
    source.value = url;
    title.value = byteLength(tab.title ?? "") <= 4096 ? (tab.title ?? "") : "";
    status.textContent = "";
    ready = true;
    save.disabled = false;
  } catch {
    status.textContent = "Open an HTTP or HTTPS page, then choose Save to capd from Safari’s extension menu.";
  }
}
