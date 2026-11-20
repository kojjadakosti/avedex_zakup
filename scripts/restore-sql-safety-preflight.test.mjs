import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const temp = mkdtempSync(join(tmpdir(), "panda-sql-safety-"));
process.on("exit", () => rmSync(temp, { recursive: true, force: true }));
const guard = new URL("./restore-sql-safety-preflight.mjs", import.meta.url);
function inspect(kind, sql) {
  const file = join(temp, "fixture.sql");
  writeFileSync(file, sql);
  return spawnSync(process.execPath, [guard.pathname, kind, file], { encoding: "utf8" });
}

test("COPY data URLs and cron-looking text are never treated as executable SQL", () => {
  const text = [
    "COPY public.example (note) FROM stdin;",
    "https://old.vercel.app/SECRET_CANARY",
    "SELECT cron.schedule(0, '* * * * *', 'SECRET_CANARY');",
    "\\.",
    "COPY auth.users (id) FROM stdin;",
    "1",
    "\\.",
    "",
  ].join("\n");
  const r = inspect("data", text);
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stdout + r.stderr, /SECRET_CANARY/);
});

for (const [name, kind, sql] of [
  ["old URL outside COPY", "data", "COPY auth.users (id) FROM stdin;\n1\n\\.\nSELECT 'https://old.vercel.app/SECRET_CANARY';\n"],
  ["cron call outside COPY", "data", "COPY auth.users (id) FROM stdin;\n1\n\\.\nSELECT cron.schedule(1, 2, 3);\n"],
  ["cron call in schema", "schema", "SELECT cron.schedule(1, 2, 3);\n"],
  ["old URL in roles", "roles", "-- https://old.vercel.app/SECRET_CANARY\n"],
  ["malformed COPY", "data", "COPY auth.users FROM unexpected;\n"],
  ["missing COPY terminator", "data", "COPY auth.users (id) FROM stdin;\n1\n"],
  ["stray COPY terminator", "data", "\\.\n"],
  ["no COPY block", "data", "SELECT 1;\n"],
  ["unterminated COPY with dangerous literal", "data", "COPY public.note (body) FROM stdin;\nhttps://old.vercel.app/SECRET_CANARY\n"],
]) {
  test(name + " is rejected without data leakage", () => {
    const r = inspect(kind, sql);
    assert.equal(r.status, 78, r.stdout + r.stderr);
    assert.doesNotMatch(r.stdout + r.stderr, /SECRET_CANARY/);
  });
}

test("CRLF COPY terminator and escaped backslashes work", () => {
  const r = inspect("data", "COPY public.example (note) FROM stdin;\r\n" +
    "\\\\.\r\nhttps://old.vercel.app\r\n\\.\r\n");
  assert.equal(r.status, 0, r.stderr);
});

test("ordinary schema and roles statements still pass", () => {
  assert.equal(inspect("schema", "CREATE TABLE public.example (id bigint);\n").status, 0);
  assert.equal(inspect("roles", "CREATE ROLE panda_test;\n").status, 0);
});
