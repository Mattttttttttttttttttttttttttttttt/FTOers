import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
// Verify that Firebase's static asset graph is complete before publication.
for(const page of ['index.html','privacy/index.html','terms/index.html']){
 const html=await readFile(resolve(root,'public',page),'utf8');
 for(const [,url] of html.matchAll(/(?:src|href)="([^"#]+)"/g)){
  if(/^(https?:|mailto:)/.test(url)||['/','/virtual/','/fto-alg-finder/'].includes(url))continue;
  await access(resolve(root,'public',url.replace(/^\//,'')));
 }
}
for(const file of ['home.js','shared/account.js','shared/config.js']){
 const result=spawnSync(process.execPath,['--check',resolve(root,'public',file)],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);
}
const config=await import('../public/shared/config.js');
assert.ok(!config.backendConfig.key.startsWith('sb_secret_'),'A server secret must never be public');
const firebase=JSON.parse(await readFile(resolve(root,'firebase.json'),'utf8'));assert.equal(firebase.hosting.public,'public');
assert.equal(firebase.hosting.headers.at(-1).source,'**/shared/config.js');
assert.equal(firebase.hosting.headers.at(-1).headers[0].value,'no-store');
const isolation=firebase.hosting.headers.find(h=>h.source==='/fto-alg-finder/web/**');
assert.ok(isolation.headers.some(h=>h.key==='Cross-Origin-Embedder-Policy'&&h.value==='require-corp'));
await assert.rejects(access(resolve(root,'public/shared/leaderboard.js')));
console.log('Static assets, JavaScript syntax and public configuration checks passed.');
