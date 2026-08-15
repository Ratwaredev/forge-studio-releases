(() => {
  if (!window.forgeDesktop || window.__forgeUpdateUxLoaded) return;
  Object.defineProperty(window, "__forgeUpdateUxLoaded", { value: true });

  let current = null;
  let control = null;
  let delayedDownloadTimer = null;

  function hideLegacyUpdateControls() {
    document.querySelector(".update-card")?.classList.add("forge-desktop-hidden");
    document.getElementById("forgeUpdateControl")?.remove();
  }

  function ensureToast() {
    let node = document.getElementById("forgeUpdateToast");
    if (node) return node;
    node = document.createElement("section");
    node.id = "forgeUpdateToast";
    node.className = "hidden";
    node.setAttribute("aria-live", "polite");
    node.innerHTML = `
      <span class="forge-update-mark" aria-hidden="true"></span>
      <span class="forge-update-copy"><strong id="forgeUpdateTitle"></strong><small id="forgeUpdateNote"></small></span>
      <button id="forgeUpdateAction" class="forge-update-action" type="button"></button>
      <span class="forge-update-progress" aria-hidden="true"><i id="forgeUpdateProgress"></i></span>`;
    document.body.append(node);
    document.getElementById("forgeUpdateAction")?.addEventListener("click", () => void runAction());
    return node;
  }

  function setVisible(visible) { ensureToast().classList.toggle("hidden", !visible); }

  function render() {
    hideLegacyUpdateControls();
    const node = ensureToast();
    const state = String(current?.state || "idle");
    const version = current?.availableVersion || control?.policy?.latestVersion || "";
    const title = document.getElementById("forgeUpdateTitle");
    const note = document.getElementById("forgeUpdateNote");
    const action = document.getElementById("forgeUpdateAction");
    const progress = document.getElementById("forgeUpdateProgress");
    node.dataset.state = state;
    action.disabled = false;
    action.hidden = false;
    progress.style.width = "0%";

    if (["idle", "checking", "current", "development", "unavailable", "available"].includes(state)) {
      setVisible(false);
      return;
    }

    if (state === "downloading") {
      title.textContent = version ? `Actualizando Forge ${version}` : "Actualizando Forge";
      note.textContent = "Se instala solo cuando cierres Forge.";
      action.hidden = true;
      progress.style.width = `${Math.max(0, Math.min(100, Number(current?.progress) || 0))}%`;
      if (!delayedDownloadTimer) {
        delayedDownloadTimer = setTimeout(() => {
          delayedDownloadTimer = null;
          if (String(current?.state) === "downloading") setVisible(true);
        }, 1200);
      }
      return;
    }

    if (delayedDownloadTimer) { clearTimeout(delayedDownloadTimer); delayedDownloadTimer = null; }

    if (state === "downloaded") {
      title.textContent = version ? `Forge ${version} listo` : "Actualización lista";
      note.textContent = control?.mandatory ? "Reinicio requerido." : "Se instala solo al cerrar.";
      action.textContent = "Reiniciar";
      progress.style.width = "100%";
      setVisible(true);
      return;
    }

    if (state === "error") {
      title.textContent = "No se pudo actualizar";
      note.textContent = "Forge vuelve a intentar automáticamente.";
      action.textContent = "Reintentar";
      setVisible(true);
      return;
    }

    setVisible(false);
  }

  async function runAction() {
    const state = String(current?.state || "");
    const action = document.getElementById("forgeUpdateAction");
    try {
      action.disabled = true;
      if (state === "downloaded") {
        action.textContent = "Reiniciando…";
        await window.forgeDesktop.installUpdate();
        return;
      }
      if (state === "error") {
        action.textContent = "Buscando…";
        current = await window.forgeDesktop.checkForUpdates();
        render();
      }
    } catch (error) {
      current = { ...(current || {}), state: "error", message: error?.message || String(error) };
      render();
    }
  }

  async function start() {
    hideLegacyUpdateControls();
    ensureToast();
    try {
      const [status, policy] = await Promise.all([
        window.forgeDesktop.getStatus(),
        window.forgeDesktop.getUpdateControl?.().catch(() => null)
      ]);
      current = status?.update || null;
      control = policy || null;
    } catch {}
    render();
    window.forgeDesktop.onUpdateStatus?.((next) => { current = next || null; render(); });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => void start(), { once: true });
  else void start();
})();
