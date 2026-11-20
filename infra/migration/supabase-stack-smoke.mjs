/**
 * Disposable integration check: official self-hosted Supabase Auth, PostgREST
 * and private Storage through the exact private Envoy gateway used by Panda.
 *
 * No production credentials or existing project data. Never print keys,
 * signed links, tokens, password, or response bodies on failure.
 */
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";

const envPath = process.argv[2];
if (!envPath) throw new Error("Missing isolated .env path");

const config = Object.fromEntries(
  (await readFile(envPath, "utf8")).split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith("#") && line.includes("="))
    .map(line => {
      const index = line.indexOf("=");
      let value = line.slice(index + 1);
      if (/^(['"]).*\1$/.test(value)) value = value.slice(1, -1);
      return [line.slice(0, index), value];
    })
);
const publicKey = config.SUPABASE_PUBLISHABLE_KEY;
const serviceKey = config.SUPABASE_SECRET_KEY;
assert.ok(publicKey?.startsWith("sb_publishable_"), "Missing generated public key");
assert.ok(serviceKey?.startsWith("sb_secret_"), "Missing generated private key");
const origin = process.env.PANDA_SMOKE_ORIGIN || "http://127.0.0.1:8000";
assert.ok(["http://127.0.0.1:8000","http://127.0.0.1:8080"].includes(origin),
  "Synthetic smoke may use only the isolated loopback gateway");

async function request(path, {method="GET", body, token, key=publicKey, mime="application/json"}={}) {
  const headers = { apikey: key };
  if(token) headers.Authorization = "Bearer " + token;
  if(body!==undefined) headers["content-type"] = mime;
  const response = await fetch(origin + path,{
    method,headers,body:body===undefined?undefined:(Buffer.isBuffer(body)?body:JSON.stringify(body)),
    signal:AbortSignal.timeout(15000),redirect:"error"
  });
  return response;
}
async function expectJson(response, statuses, label) {
  if (!statuses.includes(response.status)) {
    throw new Error(label + " returned HTTP " + response.status);
  }
  const data=await response.json().catch(()=>null);
  assert.ok(data&&typeof data==="object",label+" did not return JSON");
  return data;
}
async function ready() {
  for(let n=0;n<45;n++){
    try {
      const res=await request("/auth/v1/health");
      if(res.ok) return;
    }catch{}
    await new Promise(resolve=>setTimeout(resolve,2000));
  }
  throw new Error("Self-hosted Auth gateway never became ready");
}
await ready();
console.log("PASS: API gateway -> Auth health");

const denied = await request("/rest/v1/", {key:"invalid-test-key"});
assert.ok([401,403].includes(denied.status),"Invalid REST key unexpectedly allowed");
await denied.body?.cancel();
const rest = await request("/rest/v1/", {key:serviceKey,token:serviceKey});
assert.equal(rest.status,200,"Authenticated REST gateway unavailable");
await rest.body?.cancel();
console.log("PASS: API gateway -> REST key protection");

const password = "Test!" + randomBytes(24).toString("hex");
const email = "panda-ci-" + randomBytes(8).toString("hex") + "@example.invalid";
const created = await expectJson(await request("/auth/v1/admin/users", {
  method:"POST",key:serviceKey,token:serviceKey,
  body:{email,password,email_confirm:true}
}),[200,201],"Create synthetic user");
assert.ok(created.id,"Auth did not return created account ID");

const session=await expectJson(await request("/auth/v1/token?grant_type=password",{
  method:"POST",body:{email,password}
}),[200],"Sign in synthetic user");
assert.ok(session.access_token,"Password sign in did not return access token");

const user=await expectJson(await request("/auth/v1/user",{token:session.access_token}),[200],"Get signed-in user");
assert.equal(user.id,created.id,"Session belongs to wrong user");
console.log("PASS: create account, password sign-in, verify user");

const bucket = "panda-ci-"+randomBytes(6).toString("hex");
await expectJson(await request("/storage/v1/bucket",{
  method:"POST",key:serviceKey,token:serviceKey,
  body:{id:bucket,name:bucket,public:false}
}),[200,201],"Create private test bucket");

const filename = "photo.png";
// Valid 1x1 PNG. Only test bytes, no actual user image.
const bytes=Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/ygAAAABJRU5ErkJggg==",
  "base64"
);
const objectPath=bucket+"/smoke/"+filename;
await expectJson(await request("/storage/v1/object/"+objectPath,{
  method:"POST",key:serviceKey,token:serviceKey,
  body:bytes,mime:"image/png"
}),[200,201],"Upload private photo");

const publicAttempt=await fetch(origin+"/storage/v1/object/public/"+objectPath,{
  signal:AbortSignal.timeout(15000),redirect:"error"
});
assert.notEqual(publicAttempt.status,200,"PRIVATE photo was publicly readable");
await publicAttempt.body?.cancel();

const direct = await request("/storage/v1/object/"+objectPath,{key:serviceKey,token:serviceKey});
assert.equal(direct.status,200,"Authorized photo download failed");
assert.deepEqual(Buffer.from(await direct.arrayBuffer()),bytes,"Photo bytes were changed");

const signed=await expectJson(await request("/storage/v1/object/sign/"+objectPath,{
  method:"POST",key:serviceKey,token:serviceKey,body:{expiresIn:60}
}),[200],"Create private signed photo URL");
const signedPath=signed.signedURL||signed.signedUrl;
assert.ok(typeof signedPath==="string","Missing signed photo URL");
// The raw Storage REST endpoint returns a path relative to /storage/v1,
// while SDK clients may return the full /storage/v1/object/sign/... URL.
// Accept both, but never follow a URL pointing at a different origin.
const parsed=new URL(signedPath,origin);
assert.equal(parsed.origin,origin,"Signed photo URL pointed to an external host");
const relativePath=parsed.pathname.startsWith("/storage/v1/")
  ? parsed.pathname.slice("/storage/v1".length)
  : parsed.pathname;
assert.ok(relativePath.startsWith("/object/sign/"),"Unexpected signed photo URL path");
const signedUrl=new URL("/storage/v1"+relativePath+parsed.search,origin);
const signedResponse=await fetch(signedUrl,{signal:AbortSignal.timeout(15000),redirect:"error"});
assert.equal(signedResponse.status,200,"Signed private photo was inaccessible");
assert.deepEqual(Buffer.from(await signedResponse.arrayBuffer()),bytes,"Signed photo bytes were changed");
console.log("PASS: private Storage upload/download, access denied publicly, signed photo URL");
// Record only synthetic test credentials for the restart test.
// Do not print them and never persist any working-system credentials.
if (process.argv[3]) {
  await writeFile(process.argv[3], JSON.stringify({
    userId: created.id, email, password, objectPath,
  }), {mode: 0o600});
  console.log("PASS: synthetic restart fixture saved with private permissions");
}
console.log("PASS: isolated Supabase Auth, REST and Storage integration");
