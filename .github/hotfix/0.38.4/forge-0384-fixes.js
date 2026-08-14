(() => {
  const ACTIVE = new Set(["queued", "claimed", "running", "cancel_requested"]);
  const storage = () => window.__forgeStorage || window.localStorage;
  const context = () => {
    try { return window.__forgeProductContext?.() || {}; }
    catch { return {}; }
  };
  const authHeaders = (extra = {}) => {
    const token = storage()?.getItem?.("forge-admin-token") || "";
    return token ? { ...extra, Authorization: `Bearer ${token}` } : extra;
  };
  async function api(path, options = {}) {
    const response = await fetch(path, {
      ...options,
      cache: "no-store",
      headers: authHeaders({ ...(options.body ? { "Content-Type": "application/json" } : {}), ...(options.headers || {}) })
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
    return payload;
  }
  function toast(message, error = false) {
    const region = document.getElementById("toastRegion");
    if (!region) return;
    const node = document.createElement("div");
    node.className = `toast ${error ? "error" : ""}`;
    node.textContent = message;
    region.append(node);
    setTimeout(() => node.remove(), 4500);
  }
  async function waitUntilProjectIdle(projectId, timeoutMs = 9000) {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
      const payload = await api("/api/bootstrap");
      const active = (payload.jobs || []).some((job) => job.projectId === projectId && ACTIVE.has(job.status));
      if (!active) return true;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    return false;
  }
  async function deleteProject(projectId, projectName) {
    if (!projectId) return;
    if (!confirm(`¿Eliminar ${projectName || "este proyecto"}? Se borrará el snapshot local y su actividad.`)) return;
    const button = document.getElementById("forgeDeleteProjectButton");
    if (button) button.disabled = true;
    try {
      await api(`/api/projects/${encodeURIComponent(projectId)}/cancel-active`, { method: "POST", body: "{}" }).catch(() => undefined);
      const idle = await waitUntilProjectIdle(projectId);
      if (!idle) throw new Error("Forge todavía está cerrando una ejecución. Volvé a intentar en unos segundos.");
      await api(`/api/projects/${encodeURIComponent(projectId)}`, { method: "DELETE" });
      storage()?.removeItem?.("forge-project");
      storage()?.setItem?.("forge-screen", "projects");
      location.reload();
    } catch (error) {
      if (button) button.disabled = false;
      toast(error?.message || "No se pudo eliminar el proyecto.", true);
    }
  }
  function ensureActions() {
    const actions = document.querySelector(".forge-workflow-actions");
    if (!actions) return;
    if (!document.getElementById("forgeActivityButton")) {
      const activity = document.createElement("button");
      activity.id = "forgeActivityButton";
      activity.type = "button";
      activity.dataset.workspaceAction = "terminal";
      activity.textContent = "Actividad";
      actions.prepend(activity);
    }
    if (!document.getElementById("forgeDeleteProjectButton")) {
      const remove = document.createElement("button");
      remove.id = "forgeDeleteProjectButton";
      remove.type = "button";
      remove.textContent = "Eliminar";
      remove.style.color = "#8a3b36";
      remove.addEventListener("click", () => {
        const project = context()?.project;
        void deleteProject(project?.id, project?.name);
      });
      actions.append(remove);
    }
  }
  function removeMisleadingHiddenState() {
    document.querySelector('[data-forge-view="activity"]')?.classList.remove("forge-desktop-hidden");
  }
  function refresh() {
    ensureActions();
    removeMisleadingHiddenState();
  }
  window.addEventListener("forge:context-changed", () => setTimeout(refresh, 0));
  window.addEventListener("forge:product-changed", () => setTimeout(refresh, 0));
  document.addEventListener("DOMContentLoaded", () => setTimeout(refresh, 0), { once: true });
  setTimeout(refresh, 50);
})();
