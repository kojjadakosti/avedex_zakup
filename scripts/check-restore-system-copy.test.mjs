import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { managedCopyTargets, buildAuditSql } from "./check-restore-system-copy.mjs";

const root = mkdtempSync(join(tmpdir(), "panda-managed-copy-"));
process.on("exit", () => rmSync(root, { recursive: true, force: true }));
async function parse(sql) {
  const file = join(root, "fixture.sql");
  writeFileSync(file, sql);
  return await managedCopyTargets(file);
}
test("reads only managed table headers, ignores COPY data and public tables", async () => {
  const got = await parse([
    'COPY "storage"."buckets" ("id", "name") FROM stdin;',
    'line of data',
    'COPY "storage"."buckets_vectors" ("id") FROM stdin;',
    '\\.',
    'COPY "public"."foo" ("id") FROM stdin;',
    '1',
    '\\.',
    'COPY "auth"."users" ("id") FROM stdin;',
    '2',
    '\\.',
  ].join("\n"));
  assert.deepEqual(got, [
    { schema: "storage", table: "buckets", columns: ["id", "name"] },
    { schema: "auth", table: "users", columns: ["id"] },
  ]);
});
test("SQL uses safe quoted identifiers and only read-only catalogue functions", async () => {
  const got = await parse('COPY "auth"."users" ("id") FROM stdin;\n1\n\\.\n');
  const sql = buildAuditSql(got);
  assert.match(sql, /has_table_privilege/);
  assert.match(sql, /pg_attribute/);
  assert.doesNotMatch(sql, /\bINSERT\s+INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE\s+FROM\b|\bALTER\s+TABLE\b/);
});
for (const [name, sql] of [
  ["invalid SQL header", 'COPY auth.users FROM some_table;\n'],
  ["bad column name", 'COPY auth.users ("a; DROP TABLE") FROM stdin;\n\\.\n'],
  ["duplicate system target", 'COPY auth.users (id) FROM stdin;\n\\.\nCOPY auth.users (id) FROM stdin;\n\\.\n'],
  ["unterminated COPY", 'COPY auth.users (id) FROM stdin;\n1\n'],
]) {
  test(name + " fails closed", async () => {
    await assert.rejects(() => parse(sql));
  });
}
