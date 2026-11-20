#!/usr/bin/env node
/**
 * Read-only preflight: compare managed COPY targets against the running local
 * PostgreSQL catalogue, including INSERT rights of the actual restore role.
 * Never print rows, connection strings, credentials or SQL values.
 */
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MANAGED = new Set(["auth", "storage", "realtime"]);
const HEADER = /^\s*COPY\s+"?([A-Za-z_]\w*)"?\."?([A-Za-z_]\w*)"?\s+\((.*)\)\s+FROM\s+stdin\s*;\s*$/i;
const COLUMN = /^"?([A-Za-z_]\w*)"?$/i;

export async function managedCopyTargets(path) {
  const reader = createInterface({
    input: createReadStream(path, { encoding: "utf8" }),
    crlfDelay: Infinity,
  });
  let inCopy = false;
  const targets = [];
  const seen = new Set();
  for await (const line of reader) {
    if (inCopy) {
      if (line === "\\.") inCopy = false;
      continue;
    }
    if (!/^\s*COPY\b/i.test(line)) continue;
    const match = HEADER.exec(line);
    if (!match) throw Error("Unrecognized COPY header");
    inCopy = true;
    const schema = match[1].toLowerCase(), table = match[2].toLowerCase();
    if (!MANAGED.has(schema)) continue;
    const columns = match[3].split(",").map(value => {
      const column = COLUMN.exec(value.trim());
      if (!column) throw Error("Unrecognized COPY column");
      return column[1];
    });
    const key = schema + "." + table;
    if (seen.has(key)) throw Error("Duplicated managed COPY target");
    seen.add(key);
    targets.push({ schema, table, columns });
  }
  if (inCopy) throw Error("Unterminated COPY");
  return targets;
}

const literal = value => "'" + value.replaceAll("'", "''") + "'";
export function buildAuditSql(targets) {
  if (!targets.length) throw Error("No managed COPY targets");
  const values = targets.map(x =>
    "(" + literal(x.schema) + "," + literal(x.table) + ",ARRAY[" +
    x.columns.map(literal).join(",") + "]::text[])"
  ).join(",");
  return "\nWITH expected(schema_name, table_name, columns) AS (VALUES " + values + "),\n" +
    "inspected AS (\n" +
    "  SELECT e.schema_name, e.table_name,\n" +
    "    CASE WHEN c.oid IS NULL THEN 'MISSING_TABLE'\n" +
    "         WHEN c.relkind NOT IN ('r','p') THEN 'WRONG_RELATION_TYPE'\n" +
    "         WHEN NOT has_table_privilege(current_user, c.oid, 'INSERT') THEN 'NO_INSERT_PRIVILEGE'\n" +
    "         ELSE 'OK' END AS access_state,\n" +
    "    COALESCE(array_to_string(ARRAY(\n" +
    "      SELECT column_name FROM unnest(e.columns) AS names(column_name)\n" +
    "      WHERE NOT EXISTS (\n" +
    "        SELECT 1 FROM pg_attribute a WHERE a.attrelid=c.oid\n" +
    "          AND a.attname=column_name AND a.attnum > 0 AND NOT a.attisdropped\n" +
    "      )\n" +
    "    ), ','), '') AS missing_columns\n" +
    "  FROM expected e\n" +
    "  LEFT JOIN pg_namespace n ON n.nspname=e.schema_name\n" +
    "  LEFT JOIN pg_class c ON c.relnamespace=n.oid AND c.relname=e.table_name\n" +
    ")\n" +
    "SELECT schema_name, table_name, access_state, missing_columns\n" +
    "FROM inspected ORDER BY schema_name, table_name;";
}

async function main() {
  if (process.argv.length !== 3) {
    console.error("Usage: node check-restore-system-copy.mjs <protected-data.sql>");
    process.exitCode = 64;
    return;
  }
  try {
    const targets = await managedCopyTargets(resolve(process.argv[2]));
    const sql = buildAuditSql(targets);
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
    const cmd = spawnSync("docker", [
      "compose", "-f", "compose.local.yaml", "--env-file", ".env.docker",
      "exec", "-T", "db", "psql", "-X", "-U", "postgres", "-d", "postgres",
      "-v", "ON_ERROR_STOP=1", "-At", "-F", "\t", "-c", sql,
    ], { cwd: root, encoding: "utf8", maxBuffer: 1024 * 1024 });
    if (cmd.status !== 0 || cmd.error) throw Error("Database inspection failed");

    const rows = cmd.stdout.split(/\r?\n/).filter(line => line.length > 0);
    if (rows.length !== targets.length) throw Error("Incomplete database response");
    const issues = [];
    for (const line of rows) {
      const cells = line.split("\t");
      if (cells.length !== 4) throw Error("Unexpected catalogue output");
      const [schema, table, privilege, columns] = cells;
      if (privilege !== "OK" || columns) {
        issues.push([schema + "." + table, privilege, columns].filter(Boolean).join(": "));
      }
    }
    if (issues.length) {
      console.error("BLOCKED: managed COPY targets incompatible with local database");
      for (const issue of issues.slice(0, 40)) console.error(issue);
      process.exitCode = 78;
    } else {
      console.log("PASS: " + targets.length +
        " managed COPY targets have matching columns and INSERT privileges");
    }
  } catch {
    console.error("BLOCKED: cannot validate managed COPY targets safely");
    process.exitCode = 78;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  await main();
}
