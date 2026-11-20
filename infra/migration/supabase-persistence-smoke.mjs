/**
 * Verify that real self-hosted Auth and private Storage data survive
 * stopping and starting the Docker services without deleting their volumes.
 *
 * Only synthetic records created by supabase-stack-smoke.mjs are used.
 */
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createHash} from "node:crypto";

const [envPath, statePath] = process.argv.slice(2);
if (!envPath || !statePath) throw new Error("Usage: node supabase-persistence-smoke.mjs <test.env> <test-state.json>");

const env=Object.fromEntries(
  (await readFile(envPath,"utf8")).split(/\r?\n/)
  .filter(x=>x&&!x.trimStart().startsWith("#")&&x.includes("="))
  .map(x=>{
    const idx=x.indexOf("=");
    return [x.slice(0,idx).trim(),x.slice(idx+1).trim().replace(/^(['"])(.*)\1$/,"$2")];
  })
);
const serviceKey=env.SUPABASE_SECRET_KEY;
const publicKey=env.SUPABASE_PUBLISHABLE_KEY;
assert.ok(serviceKey?.startsWith("sb_secret_"));
assert.ok(publicKey?.startsWith("sb_publishable_"));
const state=JSON.parse(await readFile(statePath,"utf8"));
assert.match(state.userId,/^[0-9a-f-]{36}$/i);
assert.match(state.email,/^panda-ci-/);
assert.match(state.objectPath,/^panda-ci-[a-f0-9]+\/smoke\/photo\.png$/);
const base=process.env.PANDA_SMOKE_ORIGIN || "http://127.0.0.1:8000";
assert.ok(["http://127.0.0.1:8000","http://127.0.0.1:8080"].includes(base),
  "Synthetic persistence smoke may use only the isolated loopback gateway");
const abort=()=>AbortSignal.timeout(15000);

async function getJson(path,{method="GET",body,token,key=publicKey}={}){
  const headers={apikey:key};
  if(token)headers.authorization="Bearer "+token;
  if(body!==undefined) headers["content-type"]="application/json";
  const response=await fetch(base+path,{
    method, headers, signal:abort(), redirect:"error",
    body:body===undefined?undefined:JSON.stringify(body),
  });
  if(!response.ok)throw Error(path.split("?")[0]+" returned HTTP "+response.status);
  return response.json();
}
const session=await getJson("/auth/v1/token?grant_type=password",{
  method:"POST",body:{email:state.email,password:state.password},
});
assert.ok(session.access_token, "No session after restarting containers");
const user=await getJson("/auth/v1/user",{token:session.access_token});
assert.equal(user.id,state.userId,"Synthetic user disappeared after restart");
console.log("PASS: synthetic user retained and can sign in after database restart");

const response=await fetch(base+"/storage/v1/object/"+state.objectPath,{
  headers:{apikey:serviceKey,authorization:"Bearer "+serviceKey},
  signal:abort(),redirect:"error",
});
assert.equal(response.status,200,"Private photo lost after Storage/database restart");
const photo=Buffer.from(await response.arrayBuffer());
const expected=Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/ygAAAABJRU5ErkJggg==","base64"
);
assert.equal(createHash("sha256").update(photo).digest("hex"),createHash("sha256").update(expected).digest("hex"),
  "Photo checksum changed after restart");
const unauth=await fetch(base+"/storage/v1/object/public/"+state.objectPath,{signal:abort(),redirect:"error"});
assert.notEqual(unauth.status,200,"Private photo became publicly readable after restart");
await unauth.body?.cancel();

const signed=await getJson("/storage/v1/object/sign/"+state.objectPath,{
  method:"POST",key:serviceKey,token:serviceKey,body:{expiresIn:60},
});
const path=signed.signedURL||signed.signedUrl;
assert.equal(typeof path,"string");
const u=new URL(path,base);
assert.equal(u.origin,base,"Signed URL escaped the private gateway");
const suffix=u.pathname.startsWith("/storage/v1/")?u.pathname.slice("/storage/v1".length):u.pathname;
assert.ok(suffix.startsWith("/object/sign/"));
const link=new URL("/storage/v1"+suffix+u.search,base);
const download=await fetch(link,{signal:abort(),redirect:"error"});
assert.equal(download.status,200,"Signed URL did not work after restart");
assert.deepEqual(Buffer.from(await download.arrayBuffer()),expected);
console.log("PASS: private photo survived restart byte-for-byte, signed URL works, public access denied");
console.log("PASS: disposable persistence smoke check");
