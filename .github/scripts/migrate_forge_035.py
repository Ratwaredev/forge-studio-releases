from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing migration anchor: {label}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: migrate_forge_035.py <source-root>")
    root = Path(sys.argv[1]).resolve()
    if not (root / "package.json").exists():
        raise SystemExit(f"not a Forge source root: {root}")

    # The canonical Forge repository must contain only Forge product/source surfaces.
    for target in [
        "api",
        "website",
        "electron-builder.ratlab.json",
        "forge-studio-release",
        "rge-studio",
        "vercel.json",
        ".vercelignore",
        "artifacts",
        "data",
        "workspace",
    ]:
        path = root / target
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        elif path.exists():
            path.unlink()

    for base in [root / "desktop", root / "scripts", root / ".github" / "workflows"]:
        if not base.exists():
            continue
        for path in list(base.iterdir()):
            if "ratlab" not in path.name.lower():
                continue
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink()

    env_path = root / ".env.example"
    if env_path.exists():
        env = env_path.read_text(encoding="utf-8")
        marker = "\n# RatLab web — Google Identity Services"
        if marker in env:
            env = env.split(marker, 1)[0].rstrip() + "\n"
        env_path.write_text(env, encoding="utf-8")

    pkg_path = root / "package.json"
    pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
    pkg["version"] = "0.35.0"
    pkg["scripts"] = {k: v for k, v in pkg.get("scripts", {}).items() if not k.startswith("ratlab:")}
    pkg_path.write_text(json.dumps(pkg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    retention_path = root / "src/shared/retention.ts"
    retention = retention_path.read_text(encoding="utf-8")
    retention = replace_once(
        retention,
        'import { JobRecord, StateShape, VersionRecord } from "./types.js";',
        'import { JobRecord, ProjectRecord, StateShape, VersionRecord } from "./types.js";',
        "retention type import",
    )
    helper_anchor = '''export function activeJobsForProject(state: StateShape, projectId: string): JobRecord[] {
  return state.jobs.filter((job) => job.projectId === projectId && ACTIVE_JOB_STATUSES.has(job.status));
}
'''
    helper = helper_anchor + '''
export function replaceProjectState(
  state: StateShape,
  project: ProjectRecord,
  version: VersionRecord
): { removedVersionIds: string[]; removedJobIds: string[] } {
  const removedVersionIds = state.versions.filter((item) => item.projectId === project.id).map((item) => item.id);
  const removedVersionIdSet = new Set(removedVersionIds);
  const removedJobIds = state.jobs
    .filter((job) => job.projectId === project.id || removedVersionIdSet.has(job.versionId))
    .map((job) => job.id);
  const removedJobIdSet = new Set(removedJobIds);

  const existingProject = state.projects.find((item) => item.id === project.id);
  if (existingProject) Object.assign(existingProject, project, { latestVersionId: version.id });
  else state.projects.push({ ...project, latestVersionId: version.id });

  state.versions = state.versions.filter((item) => item.projectId !== project.id);
  state.versions.push(version);
  state.jobs = state.jobs.filter((job) => job.projectId !== project.id && !removedVersionIdSet.has(job.versionId));
  state.logs = state.logs.filter((entry) => !removedJobIdSet.has(entry.jobId));
  state.captures = state.captures.filter((capture) => !removedVersionIdSet.has(capture.versionId));
  state.issues = state.issues.filter((issue) => issue.projectId !== project.id && !removedVersionIdSet.has(issue.versionId));

  return { removedVersionIds, removedJobIds };
}
'''
    if "export function replaceProjectState(" not in retention:
        retention = replace_once(retention, helper_anchor, helper, "replaceProjectState helper")
    retention_path.write_text(retention, encoding="utf-8")

    server_path = root / "src/server/index.ts"
    server = server_path.read_text(encoding="utf-8")
    server = replace_once(
        server,
        'import { activeJobsForProject, pruneVersionsFromState, versionIdsToPrune } from "../shared/retention.js";',
        'import { activeJobsForProject, pruneVersionsFromState, replaceProjectState, versionIdsToPrune } from "../shared/retention.js";',
        "server retention import",
    )

    inspect_old = '''    // An explicit project selection is authoritative. Detection may warn, but it must not split an update into a new project.
    const policy = classifyImportPolicy({ duplicate: Boolean(duplicate), projectSelected: Boolean(selected), identityMatch: same, regressionStatus: regression?.status });
    const classification = policy.classification;
    res.json({
      classification,
      duplicate: duplicate ? { projectId: duplicate.projectId, versionId: duplicate.id, label: duplicate.label } : undefined,'''
    inspect_new = '''    // Selecting an existing project means replacement, not a historical merge/update.
    const replaceMode = Boolean(selected);
    const policy = classifyImportPolicy({ duplicate: Boolean(duplicate), projectSelected: Boolean(selected), identityMatch: same, regressionStatus: regression?.status });
    const classification = replaceMode ? "replace" : policy.classification;
    res.json({
      mode: replaceMode ? "replace" : "import",
      classification,
      duplicate: !replaceMode && duplicate ? { projectId: duplicate.projectId, versionId: duplicate.id, label: duplicate.label } : undefined,'''
    server = replace_once(server, inspect_old, inspect_new, "ZIP inspector policy")
    server = replace_once(
        server,
        "      regression,\n      identityMatch:",
        "      regression: replaceMode ? undefined : regression,\n      identityMatch:",
        "ZIP inspector regression",
    )
    server = replace_once(
        server,
        "      recommendation: policy.recommendation\n    });",
        '      recommendation: replaceMode ? "El ZIP reemplazará por completo el proyecto actual. No se conservará historial, baseline ni evidencia anterior." : policy.recommendation\n    });',
        "ZIP inspector recommendation",
    )

    start_marker = 'app.post("/api/import", adminAuth, upload.single("file"), async (req, res, next) => {'
    end_marker = "\n\nasync function importLocalZipThroughApi"
    start = server.find(start_marker)
    end = server.find(end_marker, start)
    if start < 0 or end < 0:
        raise SystemExit("ZIP import route markers missing")

    route = r'''app.post("/api/import", adminAuth, upload.single("file"), async (req, res, next) => {
  try {
    if (!req.file) return res.status(400).json({ error: "ZIP file required" });
    if (!req.file.originalname.toLowerCase().endsWith(".zip")) return res.status(400).json({ error: "Only .zip files are accepted" });

    const inspected = await inspectUploadedZip(req.file);
    const now = nowIso();
    const replacingExisting = Boolean(req.body.projectId);
    let project = replacingExisting ? findProject(String(req.body.projectId)) : undefined;
    if (replacingExisting && !project) return res.status(404).json({ error: "Project not found" });

    if (!project) {
      const requestedName = String(req.body.projectName || path.basename(req.file.originalname, ".zip"));
      project = {
        id: makeId("prj"),
        name: requestedName,
        slug: slugify(requestedName),
        createdAt: now,
        updatedAt: now,
        category: (["game", "app", "tool", "other"].includes(String(req.body.projectCategory)) ? String(req.body.projectCategory) : projectCategoryForAnalysis(inspected.analysis.kind)) as ProjectRecord["category"],
        pipelineSettings: { ...DEFAULT_PIPELINE_SETTINGS }
      };
    }

    if (replacingExisting && activeJobsForProject(store.snapshot(), project.id).length) {
      return res.status(409).json({ error: "Detené la ejecución antes de reemplazar el proyecto con un ZIP." });
    }

    const projectVersions = store.read((state) => state.versions.filter((version) => version.projectId === project.id));
    const previousLabel = project.latestVersionId ? projectVersions.find((item) => item.id === project.latestVersionId)?.label : undefined;
    const sourceSha256 = inspected.sha256;

    if (!replacingExisting) {
      const duplicate = projectVersions.find((item) => item.sourceSha256 === sourceSha256);
      if (duplicate) return res.status(409).json({ error: `Este ZIP ya fue importado como ${duplicate.label}`, duplicateVersionId: duplicate.id });
    }

    const requestedLabel = String(
      req.body.label || (replacingExisting ? "Actual" : incrementVersionLabel(previousLabel, projectVersions.length))
    ).trim();
    if (!replacingExisting) {
      const duplicateLabel = projectVersions.find((item) => item.label.toLowerCase() === requestedLabel.toLowerCase());
      if (duplicateLabel) return res.status(409).json({ error: `La etiqueta ${requestedLabel} ya existe. Usá una variante como ${requestedLabel}-visual.` });
    }

    const version: VersionRecord = {
      id: makeId("ver"),
      projectId: project.id,
      parentVersionId: undefined,
      label: requestedLabel,
      notes: String(req.body.notes || ""),
      sourceArtifact: "current/source.zip",
      sourceStorage: "project-current",
      sourceOriginalName: req.file.originalname,
      sourceSha256,
      sourceSize: inspected.size,
      createdAt: now,
      updatedAt: now,
      status: "uploaded",
      analysis: inspected.analysis
    };
    const committedProject: ProjectRecord = { ...project, latestVersionId: version.id, updatedAt: now };

    // ZIP update is a transactional replacement from zero. No old baseline, issues,
    // evidence or source metadata is carried into the new project state.
    await coreStorage.commitSnapshot({
      project: committedProject,
      version,
      sourcePath: req.file.path,
      issues: []
    });

    let removedVersionIds: string[] = [];
    await store.mutate((state) => {
      if (replacingExisting) {
        removedVersionIds = replaceProjectState(state, committedProject, version).removedVersionIds;
      } else {
        if (!state.projects.some((item) => item.id === committedProject.id)) state.projects.push(committedProject);
        else Object.assign(state.projects.find((item) => item.id === committedProject.id)!, committedProject);
        state.versions.push(version);
      }
    });

    await store.mutate((state) => {
      const current = state.versions.find((item) => item.id === version.id);
      if (current) { current.status = "ready"; current.updatedAt = nowIso(); }
    });

    if (replacingExisting) {
      await fs.promises.rm(visualEditsPath(project.id), { force: true }).catch(() => undefined);
      await Promise.all(removedVersionIds.flatMap((versionId) => [
        fs.promises.rm(path.join(config.paths.artifactDir, project.id, versionId), { recursive: true, force: true }),
        fs.promises.rm(path.join(config.paths.workspaceDir, versionId), { recursive: true, force: true })
      ]));
      await compactProjectRecords(project.id);
    } else {
      removedVersionIds = await pruneProjectHistory(project.id);
    }

    await syncCoreProject(project.id);
    res.status(201).json({
      project: findProject(project.id),
      version: findVersion(version.id),
      job: null,
      replaceMode: replacingExisting,
      removedVersionIds,
      prunedVersionIds: removedVersionIds,
      versionRetention: 1
    });
  } catch (error) {
    next(error);
  } finally {
    if (req.file) await fs.promises.rm(req.file.path, { force: true }).catch(() => undefined);
  }
});'''
    server = server[:start] + route + server[end:]
    server_path.write_text(server, encoding="utf-8")

    app_path = root / "public/app.js"
    app = app_path.read_text(encoding="utf-8")
    app = replace_once(
        app,
        'toast(state.importProjectId ? "Snapshot actualizado. El ZIP anterior fue eliminado." : "Proyecto importado.");',
        'toast(state.importProjectId ? "Proyecto reemplazado desde cero con el ZIP nuevo." : "Proyecto importado.");',
        "ZIP replacement toast",
    )
    app = replace_once(
        app,
        '$("importInspection").innerHTML = "<strong>Inspeccionando…</strong><p>Calculando manifest, identidad y raíz.</p>";',
        '$("importInspection").innerHTML = state.importProjectId ? "<strong>Inspeccionando…</strong><p>El ZIP nuevo reemplazará el proyecto completo.</p>" : "<strong>Inspeccionando…</strong><p>Calculando manifest, identidad y raíz.</p>";',
        "ZIP inspector copy",
    )
    app_path.write_text(app, encoding="utf-8")

    # Keep feature asset names at 0.34, but move explicit application-version assertions to 0.35.
    for path in list((root / "src/shared").glob("*.test.ts")) + [root / "scripts/verify-desktop-contracts.mjs"]:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if "0.34.0" in text:
            path.write_text(text.replace("0.34.0", "0.35.0"), encoding="utf-8")

    test_path = root / "src/shared/forge-clean-replace-035.test.ts"
    test_path.write_text(
        r'''import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { replaceProjectState } from "./retention.js";
import type { StateShape } from "./types.js";

function fixtureState(): StateShape {
  return {
    projects: [
      { id: "p1", name: "Sovereign", slug: "sovereign", category: "game", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z", latestVersionId: "v2", pipelineSettings: {} },
      { id: "p2", name: "Other", slug: "other", category: "app", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", latestVersionId: "x1", pipelineSettings: {} }
    ],
    versions: [
      { id: "v1", projectId: "p1", label: "old-1", sourceArtifact: "old1.zip", sourceSha256: "1", sourceSize: 1, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", status: "ready" },
      { id: "v2", projectId: "p1", parentVersionId: "v1", label: "old-2", sourceArtifact: "old2.zip", sourceSha256: "2", sourceSize: 2, createdAt: "2026-01-02T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z", status: "ready" },
      { id: "x1", projectId: "p2", label: "keep", sourceArtifact: "keep.zip", sourceSha256: "x", sourceSize: 3, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", status: "ready" }
    ],
    jobs: [
      { id: "j1", projectId: "p1", versionId: "v2", type: "run", status: "succeeded", createdAt: "2026-01-02T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z" },
      { id: "jx", projectId: "p2", versionId: "x1", type: "run", status: "succeeded", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z" }
    ],
    logs: [
      { id: "l1", jobId: "j1", at: "2026-01-02T00:00:00Z", stream: "stdout", message: "old" },
      { id: "lx", jobId: "jx", at: "2026-01-01T00:00:00Z", stream: "stdout", message: "keep" }
    ],
    agents: [],
    captures: [
      { id: "c1", projectId: "p1", versionId: "v2", createdAt: "2026-01-02T00:00:00Z", artifact: "old.png" },
      { id: "cx", projectId: "p2", versionId: "x1", createdAt: "2026-01-01T00:00:00Z", artifact: "keep.png" }
    ],
    issues: [
      { id: "i1", projectId: "p1", versionId: "v2", title: "old", status: "open", createdAt: "2026-01-02T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z" },
      { id: "ix", projectId: "p2", versionId: "x1", title: "keep", status: "open", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z" }
    ]
  } as unknown as StateShape;
}

test("ZIP replacement leaves exactly one clean project snapshot", () => {
  const state = fixtureState();
  const project = { ...state.projects[0]!, latestVersionId: "v3", updatedAt: "2026-01-03T00:00:00Z" };
  const version = { id: "v3", projectId: "p1", label: "Actual", sourceArtifact: "current/source.zip", sourceStorage: "project-current", sourceSha256: "3", sourceSize: 3, createdAt: "2026-01-03T00:00:00Z", updatedAt: "2026-01-03T00:00:00Z", status: "ready" } as any;
  const removed = replaceProjectState(state, project, version);

  assert.deepEqual(removed.removedVersionIds.sort(), ["v1", "v2"]);
  assert.deepEqual(state.versions.filter((item) => item.projectId === "p1").map((item) => item.id), ["v3"]);
  assert.equal(state.versions.find((item) => item.id === "v3")?.parentVersionId, undefined);
  assert.equal(state.jobs.some((item) => item.projectId === "p1"), false);
  assert.equal(state.logs.some((item) => item.jobId === "j1"), false);
  assert.equal(state.captures.some((item) => item.projectId === "p1"), false);
  assert.equal(state.issues.some((item) => item.projectId === "p1"), false);
  assert.equal(state.projects.find((item) => item.id === "p1")?.latestVersionId, "v3");
  assert.equal(state.versions.some((item) => item.id === "x1"), true);
  assert.equal(state.jobs.some((item) => item.id === "jx"), true);
});

test("Forge 0.35 source contract uses clean ZIP replacement and has no RatLab product shell", () => {
  const server = fs.readFileSync(path.resolve("src/server/index.ts"), "utf8");
  const app = fs.readFileSync(path.resolve("public/app.js"), "utf8");
  const pkg = JSON.parse(fs.readFileSync(path.resolve("package.json"), "utf8"));

  assert.equal(pkg.version, "0.35.0");
  assert.equal(Object.keys(pkg.scripts).some((key) => key.startsWith("ratlab:")), false);
  assert.equal(fs.existsSync(path.resolve("website")), false);
  assert.equal(fs.existsSync(path.resolve("api")), false);
  assert.equal(fs.existsSync(path.resolve("electron-builder.ratlab.json")), false);
  assert.match(server, /const replacingExisting = Boolean\(req\.body\.projectId\)/);
  assert.match(server, /replaceProjectState\(state, committedProject, version\)/);
  assert.match(server, /parentVersionId: undefined/);
  assert.match(server, /issues: \[\]/);
  assert.match(server, /rm\(visualEditsPath\(project\.id\)/);
  assert.match(server, /Detené la ejecución antes de reemplazar el proyecto con un ZIP/);
  assert.match(app, /Proyecto reemplazado desde cero con el ZIP nuevo/);
});
''',
        encoding="utf-8",
    )

    (root / "README.md").write_text(
        """# Forge Studio

Repositorio fuente privado y canónico de Forge Studio.

Forge es un workbench local para abrir, ejecutar, inspeccionar y editar proyectos con Preview, Código y Terminal. RatLab es un producto separado y no vive en este repositorio.

## Desarrollo

```bash
npm ci
npm test
npm run desktop:dev
```

## Actualizar un proyecto con ZIP

Cuando se elige **Actualizar con ZIP** dentro de un proyecto, el ZIP nuevo reemplaza el estado anterior de forma transaccional. No se conserva historial de ZIPs, baseline, evidencia, issues ni ajustes visuales del source anterior.

Los instaladores públicos se publican por separado en `Ratwaredev/forge-studio-releases`.
""",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
