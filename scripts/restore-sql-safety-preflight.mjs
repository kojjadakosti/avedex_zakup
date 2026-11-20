#!/usr/bin/env node
/**
 * Fail-closed inspection of Supabase CLI SQL dumps before a privileged restore.
 * COPY FROM stdin rows are data, not executable SQL. Never print source rows.
 */
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";

const [kind, file] = process.argv.slice(2);
if (!["roles", "schema", "data"].includes(kind) || !file) {
  console.error("Usage: restore-sql-safety-preflight.mjs <roles|schema|data> <path>");
  process.exit(64);
}

const forbidden = /vercel[.]app|cron[.]schedule[ \t]*\(/i;
const copyHeader = /^\s*COPY\s+.+\s+FROM\s+stdin\s*;\s*$/i;
let inCopy = false;
let copyBlocks = 0;

function blocked(reason) {
  // Report only the type of failure, not data, table names, URLs or SQL.
  console.error("BLOCKED: unsafe " + kind + " dump (" + reason + ")");
  process.exitCode = 78;
}

try {
  const lines = createInterface({
    input: createReadStream(file, { encoding: "utf8" }),
    crlfDelay: Infinity,
  });
  for await (const line of lines) {
    if (inCopy) {
      if (line === "\\.") inCopy = false;
      continue;
    }
    if (kind === "data" && /^\s*COPY\b/i.test(line)) {
      if (!copyHeader.test(line)) {
        blocked("unrecognized COPY header");
        break;
      }
      inCopy = true;
      copyBlocks++;
      continue;
    }
    if (kind === "data" && line === "\\.") {
      blocked("unexpected COPY terminator");
      break;
    }
    if (forbidden.test(line)) {
      blocked("obsolete cloud URL or executable cron command");
      break;
    }
  }
  if (!process.exitCode && inCopy) blocked("unterminated COPY block");
  if (!process.exitCode && kind === "data" && copyBlocks === 0) {
    blocked("expected COPY data blocks are absent");
  }
} catch {
  blocked("cannot read or inspect file");
}

if (!process.exitCode) {
  console.log("PASS: SQL dump safety preflight (" + kind + ")");
}
