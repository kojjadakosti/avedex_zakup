#!/usr/bin/env node
/**
 * Validate the privileged libpq target before a destructive import.
 * Docker port publishing changes inet_server_addr() inside PostgreSQL:
 * the destination in this root-only service file is the security boundary.
 */
import { readFileSync, lstatSync } from "node:fs";
import { isAbsolute } from "node:path";

function blocked() {
  console.error("BLOCKED: PostgreSQL connection must use a protected local service and passfile");
  process.exit(78);
}
const [servicePath, serviceName] = process.argv.slice(2);
if (!servicePath || !isAbsolute(servicePath) ||
    !/^[a-zA-Z0-9_-]+$/.test(serviceName || "")) blocked();

for (const name of ["PGHOST", "PGHOSTADDR", "PGPORT", "PGDATABASE",
                    "PGUSER", "PGSERVICE", "PGPASSFILE", "PGPASSWORD"]) {
  if (process.env[name]) blocked();
}

function protectedFile(path) {
  try {
    if (!isAbsolute(path)) blocked();
    const st = lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink() || st.uid !== 0 || (st.mode & 0o777) !== 0o600)
      blocked();
  } catch {
    blocked();
  }
}
protectedFile(servicePath);
let raw;
try {
  raw = readFileSync(servicePath, "utf8");
  if (raw.length > 65536) blocked();
} catch {
  blocked();
}
const sections = new Map();
let current = null;
for (const original of raw.split(/\r?\n/)) {
  const line = original.trim();
  if (!line || line.startsWith("#") || line.startsWith(";")) continue;
  const section = /^\[([a-zA-Z0-9_-]+)\]$/.exec(line);
  if (section) {
    if (sections.has(section[1])) blocked();
    current = new Map();
    sections.set(section[1], current);
    continue;
  }
  const property = /^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
  if (!current || !property) blocked();
  const key = property[1].toLowerCase();
  if (current.has(key)) blocked();
  current.set(key, property[2]);
}
const cfg = sections.get(serviceName);
if (!cfg || cfg.get("host") !== "127.0.0.1" ||
    cfg.has("hostaddr") || cfg.has("service") ||
    cfg.get("dbname") !== "postgres" ||
    !["postgres", "supabase_admin"].includes(cfg.get("user")) ||
    !/^[0-9]{1,5}$/.test(cfg.get("port") || "")) blocked();
const port = Number(cfg.get("port"));
if (port < 1 || port > 65535) blocked();
protectedFile(cfg.get("passfile") || "");
console.log("PASS: local PostgreSQL service and password-file permissions validated");
