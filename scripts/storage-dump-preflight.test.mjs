import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const dir = mkdtempSync(join(tmpdir(), "panda-storage-guard-"));
try {
  const program = new URL("./storage-dump-preflight.mjs", import.meta.url).pathname;

  function run(sql) {
    const file = join(dir, "data.sql");
    writeFileSync(file, sql);
    return spawnSync(process.execPath, [program, file], {
      encoding: "utf8",
      timeout: 10_000,
    });
  }

  const okay = run(
    "COPY auth.users (id) FROM stdin;\n100\n\\.\n" +
    "COPY storage.buckets (id) FROM stdin;\navatars\n\\.\n" +
    "COPY public.products (id) FROM stdin;\n1\n\\.\n"
  );
  assert.equal(okay.status, 0, okay.stderr);
  assert.match(okay.stdout, /"authUsersPresent":true/);

  const staleFile = run(
    "COPY auth.users (id) FROM stdin;\n100\n\\.\n" +
    "COPY storage.objects (id) FROM stdin;\n200\n\\.\n"
  );
  assert.equal(staleFile.status, 2);
  assert.match(staleFile.stderr, /storage\.objects/);
  assert.doesNotMatch(staleFile.stdout + staleFile.stderr, /200\n/);

  const missingUsers = run(
    "COPY storage.buckets (id) FROM stdin;\navatars\n\\.\n"
  );
  assert.equal(missingUsers.status, 3);
  assert.match(missingUsers.stderr, /auth\.users/);

  const quotedMetadata = run(
    'COPY "auth"."users" (id) FROM stdin;\n100\n\\.\n' +
    'INSERT INTO "storage"."objects" (id) VALUES (222);\n'
  );
  assert.equal(quotedMetadata.status, 2);

  const vaultDump = run(
    "COPY auth.users (id) FROM stdin;\n100\n\\.\n" +
    "COPY vault.secrets (id) FROM stdin;\n200\n\\.\n"
  );
  assert.equal(vaultDump.status, 4);
  assert.match(vaultDump.stderr, /vault\.secrets/);

  const cronDump = run(
    "COPY auth.users (id) FROM stdin;\n100\n\\.\n" +
    "COPY cron.job (jobid) FROM stdin;\n1\n\\.\n"
  );
  assert.equal(cronDump.status, 5);
  assert.match(cronDump.stderr, /cron\.job/);

  const vectorDump = run(
    'COPY "auth"."users" (id) FROM stdin;\n100\n\\.\n' +
    'COPY "storage"."buckets_vectors" (id) FROM stdin;\n\\.\n'
  );
  assert.equal(vectorDump.status, 6);
  assert.match(vectorDump.stderr, /vector Storage COPY/);
  assert.doesNotMatch(vectorDump.stdout + vectorDump.stderr, /100\n/);

  console.log("PASS: migration guards block Storage metadata, empty vector tables, Vault, cron and missing users");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
