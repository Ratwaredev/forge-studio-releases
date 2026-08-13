(() => {
  const CHECK_TIMEOUT_MS = 4_000;

  function tokenHeaders() {
    const token = localStorage.getItem("forge-admin-token") || "";
    return token ? { Authorization: `Bearer ${token}` } : {};
  }

  function showRuntimeError(message) {
    document.getElementById("viewportLoading")?.classList.add("hidden");
    document.getElementById("viewportEmpty")?.classList.remove("hidden");
    const hint = document.getElementById("viewportHint");
    if (hint) hint.textContent = message;
    const region = document.getElementById("toastRegion");
    if (!region) return;
    const toast = document.createElement("div");
    toast.className = "toast error";
    toast.textContent = message;
    region.append(toast);
    setTimeout(() => toast.remove(), 6500);
  }

  async function godotAvailable() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), CHECK_TIMEOUT_MS);
    try {
      const response = await fetch("/api/bootstrap", { cache: "no-store", headers: tokenHeaders(), signal: controller.signal });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      return (payload.agents || []).some((agent) => agent.status === "online" && Array.isArray(agent.capabilities) && agent.capabilities.includes("godot"));
    } finally {
      clearTimeout(timer);
    }
  }

  document.addEventListener("click", (event) => {
    const button = event.target instanceof Element ? event.target.closest("#workspaceRunButton") : null;
    if (!(button instanceof HTMLButtonElement)) return;
    if (button.dataset.forgeRuntimeGuardBypass === "1") return;
    if (button.classList.contains("stop") || /detener/i.test(button.textContent || "")) return;

    let context;
    try { context = window.__forgeProductContext?.(); } catch { context = null; }
    if (context?.version?.analysis?.kind !== "godot") return;

    event.preventDefault();
    event.stopImmediatePropagation();
    if (button.dataset.forgeRuntimeGuardChecking === "1") return;
    button.dataset.forgeRuntimeGuardChecking = "1";
    button.disabled = true;

    void godotAvailable().then((available) => {
      if (!available) {
        showRuntimeError("Godot no está disponible en esta instalación de Forge. Actualizá Forge o configurá un Godot local.");
        return;
      }
      button.dataset.forgeRuntimeGuardBypass = "1";
      button.disabled = false;
      button.click();
      delete button.dataset.forgeRuntimeGuardBypass;
    }).catch((error) => {
      const detail = error?.name === "AbortError" ? "el servicio local no respondió" : (error?.message || "error desconocido");
      showRuntimeError(`Forge no pudo comprobar Godot: ${detail}.`);
    }).finally(() => {
      delete button.dataset.forgeRuntimeGuardChecking;
      button.disabled = false;
    });
  }, true);
})();
