(() => {
  const CHECK_TIMEOUT_MS = 4_000;
  const ACTIVE = new Set(["queued", "claimed", "running", "cancel_requested"]);
  let monitorTimer = null;

  function tokenHeaders() {
    const token = localStorage.getItem("forge-admin-token") || "";
    return token ? { Authorization: `Bearer ${token}` } : {};
  }

  function context() {
    try { return window.__forgeProductContext?.() || {}; }
    catch { return {}; }
  }

  function projectKind() {
    return context()?.version?.analysis?.kind || "generic";
  }

  function ensureStyle() {
    if (document.getElementById("forge0383Style")) return;
    const style = document.createElement("style");
    style.id = "forge0383Style";
    style.textContent = `
      .forge-purpose-strip{display:flex;align-items:baseline;gap:12px;margin:-2px 0 18px;padding:0 0 14px;border-bottom:1px solid var(--border,rgba(20,20,20,.12));color:var(--muted,#676761);font-size:12px;line-height:1.45}.forge-purpose-strip strong{flex:0 0 auto;color:var(--text,#171714);font-weight:620}.forge-workflow-bar{display:flex;align-items:center;justify-content:space-between;gap:18px;min-height:46px;padding:8px 0 10px;border-bottom:1px solid var(--border,rgba(20,20,20,.12))}.forge-workflow-copy{min-width:0;display:flex;align-items:baseline;gap:9px;overflow:hidden;white-space:nowrap}.forge-workflow-copy strong{flex:0 0 auto;font-size:12px;font-weight:620}.forge-workflow-copy span{overflow:hidden;text-overflow:ellipsis;color:var(--muted,#70706a);font-size:11px}.forge-workflow-actions{display:flex;flex:0 0 auto}.forge-workflow-actions button{height:28px;padding:0 10px;border:0;border-left:1px solid var(--border,rgba(20,20,20,.12));border-radius:0;background:transparent;color:var(--muted,#666660);font:inherit;font-size:11px;cursor:pointer}.forge-workflow-actions button:hover{color:var(--text,#171714);background:rgba(20,20,20,.035)}.forge-runtime-status{min-height:32px;display:flex;align-items:center;margin:8px 0 0;padding:0 10px;border-left:2px solid rgba(20,20,20,.22);background:rgba(20,20,20,.025);color:var(--muted,#676761);font-size:11px;line-height:1.35}.forge-runtime-status.hidden{display:none}.forge-runtime-status.success{border-left-color:#4c7957;color:#31543a;background:rgba(76,121,87,.07)}.forge-runtime-status.warning{border-left-color:#9b7430;color:#74551d;background:rgba(155,116,48,.07)}.forge-runtime-status.error{border-left-color:#a74640;color:#7a302c;background:rgba(167,70,64,.07)}#viewportLoading p{max-width:min(520px,80%);text-align:center;line-height:1.45}@media(max-width:980px){.forge-purpose-strip,.forge-workflow-bar,.forge-workflow-copy{align-items:flex-start}.forge-purpose-strip,.forge-workflow-bar{flex-direction:column;gap:7px}.forge-workflow-copy{flex-direction:column;gap:2px;white-space:normal}.forge-workflow-actions button:first-child{border-left:0;padding-left:0}}
    `;
    document.head.append(style);
  }

  function ensureWorkbenchUi() {
    ensureStyle();
    const projectsHeading = document.querySelector(".projects-heading");
    if (projectsHeading && !document.getElementById("forgeProjectPurpose")) {
      const strip = document.createElement("div");
      strip.id = "forgeProjectPurpose";
      strip.className = "forge-purpose-strip";
      strip.innerHTML = `<strong>Del ZIP al proyecto listo para probar.</strong><span>Importá o conectá un repo · ejecutá · editá · validá · capturá · exportá.</span>`;
      projectsHeading.after(strip);
    }

    const toolbar = document.querySelector(".workspace-toolbar");
    if (toolbar && !document.getElementById("forgeWorkflowBar")) {
      const bar = document.createElement("div");
      bar.id = "forgeWorkflowBar";
      bar.className = "forge-workflow-bar";
      bar.innerHTML = `<div class="forge-workflow-copy"><strong id="forgeWorkflowTitle">Probá el proyecto real.</strong><span id="forgeWorkflowCopy">Forge trabaja sobre una copia aislada y deja el ZIP original intacto.</span></div><div class="forge-workflow-actions"><button type="button" data-workspace-action="validate">Validar</button><button type="button" data-workspace-action="capture">Capturar</button><button type="button" data-workspace-action="export">Exportar</button></div>`;
      toolbar.after(bar);
    }

    const stage = document.getElementById("viewportStage");
    if (stage && !document.getElementById("forgeRuntimeStatus")) {
      const status = document.createElement("div");
      status.id = "forgeRuntimeStatus";
      status.className = "forge-runtime-status hidden";
      stage.before(status);
    }

    const title = document.getElementById("forgeWorkflowTitle");
    const copy = document.getElementById("forgeWorkflowCopy");
    const editor = document.querySelector('[data-workspace-action="open-editor"]');
    const kind = projectKind();
    if (title && copy && kind === "godot") {
      title.textContent = "Jugá, corregí y entregá sin salir de Forge.";
      copy.textContent = "Godot 4.7.1 viene incluido. Ejecutá el juego, abrí Godot para editar y validá antes de exportar.";
      if (editor) editor.textContent = "Abrir Godot";
    } else if (title && copy && ["next", "vite", "static"].includes(kind)) {
      title.textContent = "Probá la web como producto, no como carpeta.";
      copy.textContent = "Levantá la app, revisala en distintas resoluciones, capturá evidencia y exportá el snapshot limpio.";
      if (editor) editor.textContent = "Abrir proyecto";
    } else if (title && copy && ["node", "python", "rust"].includes(kind)) {
      title.textContent = "Ejecutá y validá la herramienta en un workspace aislado.";
      copy.textContent = "Forge conserva el snapshot, registra la salida y deja una entrega limpia para compartir o volver atrás.";
      if (editor) editor.textContent = "Abrir proyecto";
    }
  }

  function showStatus(message = "", tone = "") {
    ensureWorkbenchUi();
    const node = document.getElementById("forgeRuntimeStatus");
    if (!node) return;
    node.textContent = message;
    node.className = `forge-runtime-status ${message ? "" : "hidden"} ${tone}`.trim();
  }

  function showRuntimeError(message) {
    document.getElementById("viewportLoading")?.classList.add("hidden");
    document.getElementById("viewportEmpty")?.classList.remove("hidden");
    const hint = document.getElementById("viewportHint");
    if (hint) hint.textContent = message;
    showStatus(message, "error");
    const region = document.getElementById("toastRegion");
    if (!region) return;
    const toast = document.createElement("div");
    toast.className = "toast error";
    toast.textContent = message;
    region.append(toast);
    setTimeout(() => toast.remove(), 6500);
  }

  async function bootstrap(signal) {
    const response = await fetch("/api/bootstrap", { cache: "no-store", headers: tokenHeaders(), signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  }

  async function godotAvailable() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), CHECK_TIMEOUT_MS);
    try {
      const payload = await bootstrap(controller.signal);
      return (payload.agents || []).some((agent) => agent.status === "online" && Array.isArray(agent.capabilities) && agent.capabilities.includes("godot"));
    } finally { clearTimeout(timer); }
  }

  function monitorRun() {
    clearTimeout(monitorTimer);
    const tick = async () => {
      try {
        const payload = await bootstrap();
        const versionId = context()?.version?.id;
        const run = (payload.jobs || []).filter((job) => job.versionId === versionId && job.type === "run").sort((a, b) => Date.parse(b.updatedAt || b.createdAt || 0) - Date.parse(a.updatedAt || a.createdAt || 0))[0];
        if (!run) { monitorTimer = setTimeout(tick, 1200); return; }
        const seconds = Math.max(0, Math.round((Date.now() - Date.parse(run.startedAt || run.createdAt || new Date().toISOString())) / 1000));
        const loading = document.querySelector("#viewportLoading p");
        if (ACTIVE.has(run.status)) {
          const message = `${projectKind() === "godot" ? "Iniciando Godot" : "Iniciando proyecto"} · ${seconds}s${seconds >= 25 ? " · está tardando más de lo normal; abrí Actividad o detenelo." : ""}`;
          if (loading) loading.textContent = message;
          showStatus(seconds >= 25 ? message : "", seconds >= 25 ? "warning" : "");
          monitorTimer = setTimeout(tick, 1000);
          return;
        }
        if (run.status === "failed") { showRuntimeError(`No pudo iniciar · ${run.error || run.classificationReason || "revisá Actividad"}`); return; }
        if (run.status === "cancelled") { showStatus("Ejecución detenida.", "warning"); setTimeout(() => showStatus(""), 3000); return; }
        showStatus(projectKind() === "godot" ? "Godot listo." : "Proyecto listo.", "success");
        setTimeout(() => showStatus(""), 2500);
      } catch (error) {
        showStatus(`No se pudo leer el estado · ${error?.message || error}`, "error");
      }
    };
    monitorTimer = setTimeout(tick, 400);
  }

  document.addEventListener("click", (event) => {
    const button = event.target instanceof Element ? event.target.closest("#workspaceRunButton") : null;
    if (!(button instanceof HTMLButtonElement)) return;
    if (button.dataset.forgeRuntimeGuardBypass === "1") { monitorRun(); return; }
    if (button.classList.contains("stop") || /detener/i.test(button.textContent || "")) return;
    if (context()?.version?.analysis?.kind !== "godot") { monitorRun(); return; }

    event.preventDefault();
    event.stopImmediatePropagation();
    if (button.dataset.forgeRuntimeGuardChecking === "1") return;
    button.dataset.forgeRuntimeGuardChecking = "1";
    button.disabled = true;
    showStatus("Comprobando Godot…");

    void godotAvailable().then((available) => {
      if (!available) { showRuntimeError("Godot no está disponible en esta instalación de Forge. Reiniciá Forge o revisá Ajustes → Toolchains."); return; }
      button.dataset.forgeRuntimeGuardBypass = "1";
      button.disabled = false;
      button.click();
      delete button.dataset.forgeRuntimeGuardBypass;
      monitorRun();
    }).catch((error) => {
      const detail = error?.name === "AbortError" ? "el servicio local no respondió" : (error?.message || "error desconocido");
      showRuntimeError(`Forge no pudo comprobar Godot: ${detail}.`);
    }).finally(() => {
      delete button.dataset.forgeRuntimeGuardChecking;
      button.disabled = false;
    });
  }, true);

  window.addEventListener("forge:context-changed", () => requestAnimationFrame(ensureWorkbenchUi));
  window.addEventListener("forge:product-changed", () => requestAnimationFrame(ensureWorkbenchUi));
  document.addEventListener("DOMContentLoaded", ensureWorkbenchUi, { once: true });
  requestAnimationFrame(ensureWorkbenchUi);
})();
