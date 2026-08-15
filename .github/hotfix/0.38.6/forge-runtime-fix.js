(() => {
  if (window.__forge0386RuntimeFixLoaded) return;
  Object.defineProperty(window, "__forge0386RuntimeFixLoaded", { value: true });

  const style = document.createElement("style");
  style.dataset.forge0386RuntimeFix = "";
  style.textContent = `
    body.forge-034 #forge0386PreviewHealth {
      position:absolute; left:50%; bottom:14px; z-index:12; transform:translateX(-50%);
      width:min(620px,calc(100% - 28px)); min-height:34px; display:flex; align-items:center; gap:12px;
      padding:7px 9px 7px 11px; border:1px solid #d8cbb2; border-radius:7px;
      background:rgba(255,252,244,.97); color:#565049; box-shadow:0 8px 28px rgba(28,28,24,.10);
      font:550 10px/1.4 Inter,"Segoe UI",system-ui,sans-serif;
    }
    body.forge-034 #forge0386PreviewHealth.hidden { display:none !important; }
    body.forge-034 #forge0386PreviewHealth[data-tone="error"] { border-color:#dfc0bd; background:rgba(255,247,246,.98); color:#74413d; }
    body.forge-034 #forge0386PreviewHealthText { min-width:0; flex:1; }
    body.forge-034 #forge0386PreviewHealth button { flex:0 0 auto; height:24px; padding:0 8px; border:1px solid rgba(30,31,34,.16); border-radius:5px; background:#fff; color:#343531; font:650 9px/1 Inter,"Segoe UI",system-ui,sans-serif; cursor:pointer; }
  `;
  document.head.append(style);

  let generation = 0;
  let preview = null;
  let inspectTimer = null;

  function activityTab() {
    return document.querySelector('[data-forge034-view="terminal"]');
  }

  function openActivity() {
    const tab = activityTab();
    if (!tab) return false;
    tab.click();
    return true;
  }

  function renameActivity() {
    const tab = activityTab();
    if (!tab) return;
    tab.textContent = "Actividad";
    tab.title = "Salida y actividad de la última ejecución";
  }

  document.addEventListener("click", (event) => {
    const trigger = event.target?.closest?.('#forgeActivityButton,[data-workspace-action="terminal"]');
    if (!trigger || !document.body.classList.contains("forge-034")) return;
    if (!openActivity()) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);

  function ensureHealth() {
    const stage = document.getElementById("viewportStage");
    if (!stage) return null;
    let node = document.getElementById("forge0386PreviewHealth");
    if (node) return node;
    node = document.createElement("div");
    node.id = "forge0386PreviewHealth";
    node.className = "hidden";
    const copy = document.createElement("span");
    copy.id = "forge0386PreviewHealthText";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Abrir Actividad";
    button.addEventListener("click", openActivity);
    node.append(copy, button);
    stage.append(node);
    return node;
  }

  function setHealth(message = "", tone = "warning") {
    const node = ensureHealth();
    if (!node) return;
    const copy = document.getElementById("forge0386PreviewHealthText");
    if (copy) copy.textContent = message;
    node.dataset.tone = tone;
    node.classList.toggle("hidden", !message);
  }

  function clearHealth() {
    generation += 1;
    if (inspectTimer) clearTimeout(inspectTimer);
    inspectTimer = null;
    setHealth("");
  }

  function visibleEvidence(win, doc) {
    const body = doc.body;
    if (!body) return false;
    if (String(body.innerText || "").replace(/\s+/g, " ").trim()) return true;
    const obvious = body.querySelector("canvas,svg,img,video,iframe,input,textarea,button,select,a[href]");
    if (obvious) {
      const rect = obvious.getBoundingClientRect?.();
      if (!rect || (rect.width > 2 && rect.height > 2)) return true;
    }
    for (const element of [...body.querySelectorAll("*")].slice(0, 1500)) {
      const rect = element.getBoundingClientRect?.();
      if (!rect || rect.width < 8 || rect.height < 8) continue;
      const computed = win.getComputedStyle?.(element);
      if (!computed || computed.display === "none" || computed.visibility === "hidden" || Number(computed.opacity) === 0) continue;
      if (computed.backgroundImage !== "none" || !["rgba(0, 0, 0, 0)", "transparent"].includes(computed.backgroundColor)
        || parseFloat(computed.borderTopWidth || "0") > 0 || parseFloat(computed.borderRightWidth || "0") > 0
        || parseFloat(computed.borderBottomWidth || "0") > 0 || parseFloat(computed.borderLeftWidth || "0") > 0) return true;
    }
    return false;
  }

  function inspect(currentGeneration) {
    if (currentGeneration !== generation || !preview?.isConnected) return;
    const src = String(preview.dataset.previewUrl || preview.src || "");
    if (!src || src === "about:blank") return clearHealth();
    try {
      const url = new URL(src, location.href);
      if (url.origin !== location.origin || !url.pathname.startsWith("/preview/")) return clearHealth();
      const win = preview.contentWindow;
      const doc = preview.contentDocument;
      if (!win || !doc) return;
      const bodyText = String(doc.body?.innerText || "").trim();
      if (/^(Preview unavailable|Preview is not ready|Internal Server Error)/i.test(bodyText)) {
        setHealth(`El proxy de preview respondió con error: ${bodyText.slice(0, 180)}`, "error");
        return;
      }
      if (!visibleEvidence(win, doc)) setHealth("La app arrancó, pero el preview quedó vacío. Abrí Actividad para ver el error de runtime o del servidor.");
      else clearHealth();
    } catch {
      clearHealth();
    }
  }

  function onPreviewLoad() {
    const currentGeneration = ++generation;
    if (inspectTimer) clearTimeout(inspectTimer);
    inspectTimer = setTimeout(() => inspect(currentGeneration), 850);
  }

  function bindPreview() {
    const next = document.getElementById("projectPreview");
    if (!next || next === preview) return;
    if (preview) preview.removeEventListener("load", onPreviewLoad);
    preview = next;
    preview.addEventListener("load", onPreviewLoad);
    preview.addEventListener("error", () => setHealth("El preview no pudo cargar. Abrí Actividad para ver la salida de la ejecución.", "error"));
  }

  function refresh() {
    renameActivity();
    bindPreview();
    ensureHealth();
  }

  window.addEventListener("forge:context-changed", () => { clearHealth(); setTimeout(refresh, 0); });
  window.addEventListener("forge:product-changed", () => setTimeout(refresh, 0));
  document.addEventListener("DOMContentLoaded", () => setTimeout(refresh, 0), { once: true });
  setTimeout(refresh, 80);
  setTimeout(refresh, 350);

  window.Forge0386RuntimeFix = Object.freeze({ openActivity });
})();
