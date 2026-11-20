import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { filterEmptyVectorCopies } from "./prepare-restore-dump.mjs";

const dir = mkdtempSync(join(tmpdir(), "panda-vector-copy-"));
process.on("exit", () => rmSync(dir, { recursive: true, force: true }));

const vector = 'COPY "storage"."buckets_vectors" ("id") FROM stdin;\n\\.\n';
const indexes = 'COPY "storage"."vector_indexes" ("id") FROM stdin;\n\\.\n';
const user = 'COPY "auth"."users" ("id", "raw_data") FROM stdin;\n' +
  '1\timportant data\\nCOPY "storage"."vector_indexes" ("id") FROM stdin;\n\\.\n';
const original = 'SET search_path = \'\';\n' + vector + user + indexes +
  'SELECT pg_catalog.setval(\'public.table_id_seq\', 42, true);\n';

async function check(sourceText) {
  const src = join(dir, "source-" + Math.random().toString(16).slice(2));
  const out = src + ".out";
  writeFileSync(src, sourceText);
  try {
    return { stats: await filterEmptyVectorCopies(src, out), result: readFileSync(out, "utf8"),
      initial: readFileSync(src, "utf8") };
  } finally {
    rmSync(src, { force: true });
    rmSync(out, { force: true });
  }
}

test("removes exactly two empty vector COPY blocks, byte-preserving all other SQL", async () => {
  const x = await check(original);
  assert.deepEqual(x.stats, { inputCopyBlocks: 3, outputCopyBlocks: 1, omitted: 2 });
  assert.equal(x.result, original.replace(vector, "").replace(indexes, ""));
  assert.equal(x.initial, original);
});

test("handles CRLF without normalizing unrelated SQL or data", async () => {
  const x = await check(original.replaceAll("\n", "\r\n"));
  assert.equal(x.result, original.replace(vector, "").replace(indexes, "").replaceAll("\n", "\r\n"));
});

for (const [name, source] of [
  ["nonempty vector table", vector.replace("\\.\n", "private-data\n\\.\n") + indexes],
  ["duplicate vector copy", vector + vector + indexes],
  ["missing vector copy", vector + user],
  ["unterminated vector copy", vector.replace("\\.\n", "") + indexes],
  ["malformed COPY", vector + indexes + "COPY storage.bad FROM unknown;\n"],
  ["unterminated ordinary COPY", vector + indexes + "COPY auth.users (id) FROM stdin;\n1\n"],
]) {
  test(name + " fails closed without leaking the input", async () => {
    await assert.rejects(() => check(source));
  });
}
