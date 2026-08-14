(() => {
  const ACTIVE = new Set(["queued", "claimed", "running", "cancel_requested"]);
  let importBypass = false;
  let busy = false;
  const storage = () => window.__forgeStorage || window.localStorage;
  const context = () => { try { return window.__forgeProductContext?.() || {}; } catch { return {}; } };
  function authHeaders(extra = {}) {
    const token = storage()?.getItem?.("forge-admin-token") || "";
    return token ? { ...extra, Authorization: `Bearer ${token}` } : extra;
  }
  async function api(path, options = {}) {
    const response = await fetch(path, { ...options, cache: "no-store", headers: authHeaders({ ...(options.body && typeof options.body === "string" ? { "Content-Type": "application/json" } : {}), ...(options.headers || {}) }) });
    const payload = response.status === 204 ? null : await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload?.error || `HTTP ${response.status}`);
    return payload;
  }
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  function notify(text, error = false) {
    try { if (typeof window.toast === "function") window.toast(text, error ? "error" : undefined); } catch {}
    const status = document.getElementById("forgeRunStatus");
    if (status) { status.textContent = text; status.className = `forge-run-status ${error ? "error" : ""}`.trim(); }
  }
  async function activeJobs(projectId) {
    const payload = await api("/api/bootstrap");
    return (payload.jobs || []).filter((job) => job.projectId === projectId && ACTIVE.has(job.status));
  }
  async function drain(projectId) {
    let jobs = await activeJobs(projectId);
    if (!jobs.length) return;
    notify("Cerrando ejecución activa…");
    await api(`/api/projects/${encodeURIComponent(projectId)}/cancel-active`, { method: "POST", body: "{}" }).catch(() => undefined);
    const deadline = Date.now() + 12000;
    while (Date.now() < deadline) {
      await sleep(250);
      jobs = await activeJobs(projectId);
      if (!jobs.length) return;
    }
    for (const job of jobs) await api(`/api/jobs/${encodeURIComponent(job.id)}/cancel`, { method: "POST", body: "{}" }).catch(() => undefined);
    const hardDeadline = Date.now() + 6000;
    while (Date.now() < hardDeadline) {
      await sleep(300);
      jobs = await activeJobs(projectId);
      if (!jobs.length) return;
    }
    throw new Error("No se pudo cerrar una ejecución colgada. Reiniciá Forge y repetí la operación.");
  }
  function updating(form) {
    if (form?.id !== "importForm") return false;
    return /ACTUALIZAR SNAPSHOT/i.test(document.getElementById("importEyebrow")?.textContent || "") || /^Actualizar\b/i.test(document.getElementById("importTitle")?.textContent || "");
  }
  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (importBypass || busy || !updating(form)) return;
    const project = context()?.project;
    if (!project?.id) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    busy = true;
    const button = document.getElementById("importSubmitButton");
    if (button) button.disabled = true;
    void (async () => {
      try {
        await drain(project.id);
        notify("Reemplazando snapshot…");
        importBypass = true;
        form.requestSubmit();
        importBypass = false;
      } catch (error) {
        importBypass = false;
        notify(error?.message || String(error), true);
      } finally {
        busy = false;
        if (button) button.disabled = false;
      }
    })();
  }, true);
  document.addEventListener("click", (event) => {
    const button = event.target?.closest?.('[data-forge034-action="delete"], [data-workspace-action="delete"]');
    if (!button || busy) return;
    const project = context()?.project;
    if (!project?.id) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (!window.confirm(`¿Eliminar ${project.name || "este proyecto"}? Se borrará su snapshot y evidencia local.`)) return;
    busy = true;
    button.disabled = true;
    void (async () => {
      try {
        await drain(project.id);
        notify("Eliminando proyecto…");
        await api(`/api/projects/${encodeURIComponent(project.id)}`, { method: "DELETE" });
        storage()?.removeItem?.("forge-project");
        window.location.reload();
      } catch (error) {
        notify(error?.message || String(error), true);
        button.disabled = false;
      } finally { busy = false; }
    })();
  }, true);
})();
