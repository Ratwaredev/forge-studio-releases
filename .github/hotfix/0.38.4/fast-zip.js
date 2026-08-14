import fs from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import yauzl from "yauzl";
import archiver from "archiver";
import { ensureDir, isPathInside, safeRelativePath } from "./utils.js";

const parsedConcurrency = Number.parseInt(process.env.FORGE_ZIP_CONCURRENCY || "8", 10);
const ZIP_CONCURRENCY = Number.isFinite(parsedConcurrency) ? Math.max(2, Math.min(16, parsedConcurrency)) : 8;

export async function extractZip(zipPath, destination) {
  await ensureDir(destination);
  await new Promise((resolve, reject) => {
    yauzl.open(zipPath, { lazyEntries: true, autoClose: false }, (openError, zipFile) => {
      if (openError || !zipFile) return reject(openError ?? new Error("Unable to open ZIP"));
      let settled = false;
      let ended = false;
      let active = 0;
      let entryRequestPending = false;
      const finish = () => {
        if (settled || !ended || active !== 0) return;
        settled = true;
        try { zipFile.close(); } catch {}
        resolve();
      };
      const fail = (error) => {
        if (settled) return;
        settled = true;
        try { zipFile.close(); } catch {}
        reject(error);
      };
      const requestNext = () => {
        if (settled || ended || entryRequestPending || active >= ZIP_CONCURRENCY) return;
        entryRequestPending = true;
        try { zipFile.readEntry(); } catch (error) { entryRequestPending = false; fail(error); }
      };
      zipFile.on("error", fail);
      zipFile.on("end", () => { entryRequestPending = false; ended = true; finish(); });
      zipFile.on("entry", (entry) => {
        entryRequestPending = false;
        let relative;
        let outputPath;
        try {
          relative = safeRelativePath(entry.fileName);
          if (!relative) { requestNext(); return; }
          outputPath = path.resolve(destination, relative);
          if (!isPathInside(destination, outputPath)) throw new Error(`ZIP entry escaped destination: ${entry.fileName}`);
        } catch (error) { fail(error); return; }
        active += 1;
        const work = /\/$/.test(entry.fileName)
          ? fs.promises.mkdir(outputPath, { recursive: true })
          : fs.promises.mkdir(path.dirname(outputPath), { recursive: true }).then(() => new Promise((resolveStream, rejectStream) => {
              zipFile.openReadStream(entry, (streamError, stream) => {
                if (streamError || !stream) return rejectStream(streamError ?? new Error("Unable to read ZIP entry"));
                const rawMode = (entry.externalFileAttributes >>> 16) & 0o777;
                pipeline(stream, fs.createWriteStream(outputPath, { mode: rawMode || 0o666 })).then(resolveStream, rejectStream);
              });
            }));
        requestNext();
        work.then(() => {
          active -= 1;
          if (!ended) requestNext();
          finish();
        }).catch(fail);
      });
      requestNext();
    });
  });
}

export async function zipDirectory(sourceDir, outputPath, options = {}) {
  await ensureDir(path.dirname(outputPath));
  await new Promise((resolve, reject) => {
    const output = fs.createWriteStream(outputPath);
    const archive = archiver("zip", { zlib: { level: 9 } });
    output.on("close", resolve);
    output.on("error", reject);
    archive.on("error", reject);
    archive.pipe(output);
    const walk = async (dir) => {
      const entries = await fs.promises.readdir(dir, { withFileTypes: true });
      for (const entry of entries) {
        const absolute = path.join(dir, entry.name);
        const relative = path.relative(sourceDir, absolute).replace(/\\/g, "/");
        if (options.ignore?.(relative, entry.isDirectory())) continue;
        if (entry.isDirectory()) await walk(absolute);
        else if (entry.isFile()) archive.file(absolute, { name: relative });
      }
    };
    walk(sourceDir).then(() => archive.finalize()).catch(reject);
  });
}

export async function openZipEntry(zipPath, requestedName) {
  const normalizedRequested = safeRelativePath(requestedName).replace(/\\/g, "/");
  if (!normalizedRequested) return undefined;
  return await new Promise((resolve, reject) => {
    yauzl.open(zipPath, { lazyEntries: true }, (openError, zipFile) => {
      if (openError || !zipFile) return reject(openError ?? new Error("Unable to open ZIP"));
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        if (!value) zipFile.close();
        resolve(value);
      };
      const fail = (error) => {
        if (settled) return;
        settled = true;
        zipFile.close();
        reject(error);
      };
      zipFile.on("error", fail);
      zipFile.on("end", () => finish(undefined));
      zipFile.on("entry", (entry) => {
        let normalizedEntry = "";
        try { normalizedEntry = safeRelativePath(entry.fileName).replace(/\\/g, "/"); }
        catch { zipFile.readEntry(); return; }
        if (normalizedEntry !== normalizedRequested || /\/$/.test(entry.fileName)) {
          zipFile.readEntry();
          return;
        }
        zipFile.openReadStream(entry, (streamError, stream) => {
          if (streamError || !stream) return fail(streamError ?? new Error("Unable to read ZIP entry"));
          settled = true;
          stream.once("end", () => zipFile.close());
          stream.once("error", () => zipFile.close());
          resolve({ stream, size: entry.uncompressedSize, fileName: normalizedEntry });
        });
      });
      zipFile.readEntry();
    });
  });
}
