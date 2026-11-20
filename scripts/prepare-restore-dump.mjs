#!/usr/bin/env node
/**
 * Make a root-only, byte-preserving COPY dump for self-hosted restoration.
 * Drops ONLY the two known EMPTY vector Storage COPY blocks.
 * The source SQL files are never edited or overwritten.
 */
import {
  createReadStream, createWriteStream, copyFileSync, mkdirSync, lstatSync,
  chmodSync, rmSync, constants,
} from "node:fs";
import { once } from "node:events";
import { finished } from "node:stream/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const OMIT = new Set(["storage.buckets_vectors", "storage.vector_indexes"]);
const COPY = /^\s*COPY\s+((?:"?[A-Za-z_][A-Za-z0-9_]*"?\.)?"?[A-Za-z_][A-Za-z0-9_]*"?)\s+\(.*\)\s+FROM\s+stdin\s*;\s*$/i;

async function* rawLines(file) {
  let carry = Buffer.alloc(0);
  for await (const chunk of createReadStream(file)) {
    let start = 0;
    let index;
    while ((index = chunk.indexOf(10, start)) !== -1) {
      const part = chunk.subarray(start, index + 1);
      yield carry.length ? Buffer.concat([carry, part]) : part;
      carry = Buffer.alloc(0);
      start = index + 1;
    }
    if (start < chunk.length) {
      const end = chunk.subarray(start);
      carry = carry.length ? Buffer.concat([carry, end]) : Buffer.from(end);
      if (carry.length > 64 * 1024 * 1024) {
        throw Error("Oversized SQL line");
      }
    }
  }
  if (carry.length) yield carry;
}

/** Streaming core, used by both CLI and synthetic unit tests. */
export async function filterEmptyVectorCopies(source, destination) {
  const output = createWriteStream(destination, { flags: "wx", mode: 0o600 });
  const seen = new Set();
  let active = null;
  let total = 0;
  try {
    for await (const bytes of rawLines(source)) {
      if (active !== null) {
        const terminator = bytes.length <= 4 && /^\\\.(?:\r?\n)?$/.test(bytes.toString("ascii"));
        if (terminator) {
          if (active !== "omit" && !output.write(bytes)) await once(output, "drain");
          active = null;
          continue;
        }
        if (active === "omit") {
          throw Error("Excluded vector COPY is not empty");
        }
        if (!output.write(bytes)) await once(output, "drain");
        continue;
      }

      const line = bytes.toString("utf8");
      if (/^\s*COPY\b/i.test(line)) {
        const header = COPY.exec(line);
        if (!header) throw Error("Malformed COPY header");
        total++;
        const relation = header[1].replaceAll('"', "").toLowerCase();
        if (OMIT.has(relation)) {
          if (seen.has(relation)) throw Error("Duplicate vector COPY");
          seen.add(relation);
          active = "omit";
        } else {
          active = "keep";
          if (!output.write(bytes)) await once(output, "drain");
        }
      } else {
        if (bytes.length <= 4 && /^\\\.(?:\r?\n)?$/.test(line)) {
          throw Error("Unexpected COPY terminator");
        }
        if (!output.write(bytes)) await once(output, "drain");
      }
    }
    if (active !== null) throw Error("Unterminated COPY");
    if (seen.size !== OMIT.size) throw Error("Missing required vector COPY");
    output.end();
    await finished(output);
    return { inputCopyBlocks: total, outputCopyBlocks: total - seen.size, omitted: seen.size };
  } catch (error) {
    output.destroy();
    await finished(output).catch(() => {});
    throw error;
  }
}

function protectedFile(path, expectedMode) {
  const info = lstatSync(path);
  if (!info.isFile() || info.isSymbolicLink() || info.uid !== 0 ||
      (info.mode & 0o777) !== expectedMode || info.size === 0) {
    throw Error("Unprotected source file");
  }
}

async function main() {
  if (process.getuid?.() !== 0 || process.argv.length !== 4) {
    console.error("Usage (root): node prepare-restore-dump.mjs <protected-source-dir> <new-sibling-dir>");
    process.exitCode = 78;
    return;
  }

  const source = resolve(process.argv[2]);
  const destination = resolve(process.argv[3]);
  let created = false;
  try {
    if (source === destination || dirname(source) !== dirname(destination)) {
      throw Error("Output must be a separate sibling directory");
    }
    const sourceStat = lstatSync(source);
    if (!sourceStat.isDirectory() || sourceStat.isSymbolicLink() ||
        sourceStat.uid !== 0 || (sourceStat.mode & 0o777) !== 0o700) {
      throw Error("Source directory must be private");
    }
    for (const name of ["roles", "schema", "data"]) {
      protectedFile(source + "/" + name + ".sql", 0o600);
    }
    mkdirSync(destination, { mode: 0o700 });
    created = true;
    for (const name of ["roles", "schema"]) {
      const output = destination + "/" + name + ".sql";
      copyFileSync(source + "/" + name + ".sql", output, constants.COPYFILE_EXCL);
      chmodSync(output, 0o600);
    }
    const results = await filterEmptyVectorCopies(
      source + "/data.sql", destination + "/data.sql",
    );
    console.log("PASS: protected filtered SQL dump prepared; original unchanged");
    console.log(JSON.stringify(results));
  } catch {
    if (created) rmSync(destination, { recursive: true, force: true });
    console.error("BLOCKED: dump preparation failed; no source files were changed");
    process.exitCode = 78;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  await main();
}
