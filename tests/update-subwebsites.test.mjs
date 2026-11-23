import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,cp,writeFile,readFile,readlink,rm,lstat,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {syncShared,sharedFiles,prepareSharedUpdate} from '../scripts/sync-shared.mjs';

async function fixture(t){
 const root=await mkdtemp(join(tmpdir(),'ftoers-update-'));t.after(()=>rm(root,{recursive:true,force:true}));
 await cp(new URL('../scripts/',import.meta.url),join(root,'scripts'),{recursive:true});
 await cp(new URL('../update-subwebsites.sh',import.meta.url),join(root,'update-subwebsites.sh'));
 await cp(new URL('../public/shared/',import.meta.url),join(root,'public/shared'),{recursive:true});
 await mkdir(join(root,'bin'));
 for(const name of ['git','npm'])await writeFile(join(root,'bin',name),`#!/usr/bin/env node
const fs=require('fs');fs.appendFileSync(process.env.TEST_LOG,JSON.stringify({name:'${name}',args:process.argv.slice(2),cwd:process.cwd()})+'\\n');
if('${name}'==='npm'&&process.argv[2]==='run'){fs.mkdirSync('dist',{recursive:true});fs.writeFileSync('dist/index.html','built');}
`,{mode:0o755});
 const config={finder:{path:'finder/main',build:true,command:['bash','../build.sh','--web'],output:'../public',required:['index.html','web/index.html','web/wasm/fto_web.wasm']},virtual:{path:'virtual',build:true,shared:'public/shared'}};
 for(const id of ['virtual','finder/main']){await mkdir(join(root,'submodules',id),{recursive:true});await writeFile(join(root,'submodules',id,'package-lock.json'),'{}');}
 await writeFile(join(root,'submodules/finder/build.sh'),'#!/usr/bin/env bash\nset -e\nmkdir -p ../public/web/wasm\necho landing > ../public/index.html\necho web > ../public/web/index.html\necho wasm > ../public/web/wasm/fto_web.wasm\n');
 await writeFile(join(root,'submodules.json'),JSON.stringify(config));
 const log=join(root,'commands.log');
 const environment={...process.env,PATH:join(root,'bin')+':'+process.env.PATH,TEST_LOG:log};
 const run=(...args)=>spawnSync('bash',[join(root,'update-subwebsites.sh'),...args],{cwd:tmpdir(),encoding:'utf8',env:environment});
 return {root,run,config,log,environment,save:()=>writeFile(join(root,'submodules.json'),JSON.stringify(config))};
}
test('locked update builds nested web output and standalone account copies, from another cwd',async t=>{
 const f=await fixture(t),result=f.run('--lock');assert.equal(result.status,0,result.stderr);
 const commands=(await readFile(f.log,'utf8')).trim().split('\n').map(JSON.parse);
 assert.equal(commands.some(c=>c.name==='git'),false);assert.equal(commands.filter(c=>c.args[0]==='ci').length,2);
 assert.equal(await readlink(join(f.root,'public/finder')),'../submodules/finder/public');
 assert.equal(await readFile(join(f.root,'public/finder/web/index.html'),'utf8'),'web\n');
 assert.equal(await readlink(join(f.root,'public/virtual')),'../submodules/virtual/dist');
 for(const name of sharedFiles)assert.deepEqual(await readFile(join(f.root,'submodules/virtual/public/shared',name)),await readFile(join(f.root,'public/shared',name)));
 assert.equal(f.run('--lock').status,0,'repeat update is safe');
});
test('selection, case folding, locking, default updating flags and plans',async t=>{
 const f=await fixture(t);f.config.finder.updating=false;await f.save();
 let r=f.run('--plan');assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/Git update: virtual/);assert.match(r.stdout,/finder: skip/);
 r=f.run('FINDER','--plan');assert.match(r.stdout,/Git update: finder/);assert.match(r.stdout,/finder: skip/);
 r=f.run('--lock','ViRtUaL','--plan');assert.match(r.stdout,/Git update: \(none\)/);assert.doesNotMatch(r.stdout,/public\/finder/);
 assert.equal(await lstat(f.log).catch(()=>null),null,'plans have no command side effects');
 assert.notEqual(f.run('missing').status,0);
 r=f.run('virtual','--skip-install');assert.equal(r.status,0,r.stderr);const calls=(await readFile(f.log,'utf8')).trim().split('\n').map(JSON.parse);assert.equal(calls[0].name,'git');assert.deepEqual(calls[0].args.slice(-1),['submodules/virtual']);assert.equal(calls.some(c=>c.args[0]==='ci'),false);
});
test('missing nested web artifacts fail; real public directories and escaping output are protected',async t=>{
 const f=await fixture(t);f.config.finder.required.push('web/missing.wasm');await f.save();
 assert.notEqual(f.run('--lock','finder').status,0);assert.equal(await lstat(join(f.root,'public/finder')).catch(()=>null),null);
 await mkdir(join(f.root,'public/virtual'));await writeFile(join(f.root,'public/virtual/keep'),'keep');
 assert.match(f.run('--lock','virtual').stderr,/Refusing to replace/);assert.equal(await readFile(join(f.root,'public/virtual/keep'),'utf8'),'keep');
 f.config.finder.output='../../../../outside';await f.save();assert.match(f.run('--plan').stderr,/must stay inside/);
});
test('shared sync refuses local edits before changing any files',async t=>{
 const f=await fixture(t),target=join(f.root,'consumer/shared'),source=join(f.root,'public/shared');
 await syncShared(target,{source});await writeFile(join(target,'account.js'),'friend edit');
 await writeFile(join(source,'account.css'),'upstream edit');
 const before=await readFile(join(target,'account.css'),'utf8');
 await assert.rejects(syncShared(target,{source}),/overwrite local changes/);
 assert.equal(await readFile(join(target,'account.js'),'utf8'),'friend edit');assert.equal(await readFile(join(target,'account.css'),'utf8'),before);
});

test('legacy Node build scripts receive arguments and can rebuild their real output directory',async t=>{
 const f=await fixture(t);f.config.legacy={path:'virtual/build.mjs --small'};await f.save();
 await writeFile(join(f.root,'submodules/virtual/build.mjs'),"import {mkdir,writeFile} from 'node:fs/promises';await mkdir(process.env.BUILD_OUT_DIR,{recursive:true});await writeFile(process.env.BUILD_OUT_DIR+'/index.html',process.argv[2]);");
 let result=f.run('--lock','virtual');assert.equal(result.status,0,result.stderr);assert.equal(await readFile(join(f.root,'public/legacy/index.html'),'utf8'),'--small');
 result=f.run('--lock','virtual');assert.equal(result.status,0,result.stderr);
 f.config.legacy.updating=false;await f.save();result=f.run('--plan');assert.match(result.stdout,/Git update: finder, virtual/);
});

test('SDK environment reaches the configured build; an unavailable SDK fails before npm installs',async t=>{
 const f=await fixture(t);f.config.finder.emscripten='4.0.20';await f.save();
 f.environment.FTOERS_EMSDK_ENV=join(f.root,'missing/emsdk_env.sh');
 assert.equal(f.run('--lock','finder','--plan').status,0);
 let result=f.run('--lock','finder');assert.notEqual(result.status,0);assert.match(result.stderr,/Emscripten 4.0.20 is required/);assert.equal(await lstat(f.log).catch(()=>null),null);
 const sdk=join(f.root,'custom sdk');await mkdir(join(sdk,'bin'),{recursive:true});
 await writeFile(join(sdk,'bin/emcc'),"#!/bin/sh\necho 'emcc 4.0.20'\n",{mode:0o755});
 f.environment.FTOERS_EMSDK_ENV=join(sdk,'emsdk_env.sh');
 await writeFile(f.environment.FTOERS_EMSDK_ENV,`export PATH='${sdk}/bin':"$PATH"\nexport FTOERS_SDK_MARKER=found\n`);
 await writeFile(join(f.root,'submodules/finder/build.sh'),'#!/usr/bin/env bash\nset -eu\n[ "$FTOERS_SDK_MARKER" = found ]\nemcc --version\nmkdir -p ../public/web/wasm\necho landing > ../public/index.html\necho web > ../public/web/index.html\necho wasm > ../public/web/wasm/fto_web.wasm\n');
 result=f.run('--lock','finder');assert.equal(result.status,0,result.stderr);assert.match(result.stdout,/\[sdk\] Emscripten 4.0.20/);assert.equal(await readFile(join(f.root,'public/finder/web/wasm/fto_web.wasm'),'utf8'),'wasm\n');
});


test('Git updates preserve generated shared copies but refuse hand edits and staged changes',async t=>{
 const root=await mkdtemp(join(tmpdir(),'ftoers-shared-git-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const repo=join(root,'consumer'),target=join(repo,'public/shared'),source=join(root,'source');
 await mkdir(repo);await cp(new URL('../public/shared/',import.meta.url),source,{recursive:true});
 const git=(...args)=>{const r=spawnSync('git',args,{cwd:repo,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout;};
 git('init','-q');git('config','user.email','fixture@example.test');git('config','user.name','Fixture');
 await syncShared(target,{source});git('add','.');git('commit','-qm','Initial shared copies');
 const original=await readFile(join(target,'account.css'),'utf8');
 await writeFile(join(source,'account.css'),original+'\n/* Canonical update */\n');await syncShared(target,{source});
 await writeFile(join(repo,'keep.txt'),'Unrelated work');
 await prepareSharedUpdate(repo,target,{source});
 assert.equal(await readFile(join(target,'account.css'),'utf8'),original);
 assert.equal(git('diff','--name-only'),'');assert.equal(await readFile(join(repo,'keep.txt'),'utf8'),'Unrelated work');
 const backups=await readdir(join(repo,'.git/ftoers-shared-backups'));
 assert.equal(backups.length,1);assert.match(await readFile(join(repo,'.git/ftoers-shared-backups',backups[0],'public/shared/account.css'),'utf8'),/Canonical update/);
 // The normal post-merge sync restores the canonical copy.
 await syncShared(target,{source});assert.match(await readFile(join(target,'account.css'),'utf8'),/Canonical update/);
 await writeFile(join(target,'profile.js'),'Independent developer edit');
 await assert.rejects(prepareSharedUpdate(repo,target,{source}),/overwrite local edits/);
 assert.equal(await readFile(join(target,'profile.js'),'utf8'),'Independent developer edit');
 git('add','public/shared/profile.js');await assert.rejects(prepareSharedUpdate(repo,target,{source}),/Commit or unstage/);
});

test('site flags select one or several roots without loading an unselected SDK',async t=>{
 const f=await fixture(t);
 f.config.finder.emscripten='4.0.20';
 f.config.FB={path:'FB',build:true};
 await mkdir(join(f.root,'submodules/FB'),{recursive:true});
 await writeFile(join(f.root,'submodules/FB/package-lock.json'),'{}');
 await f.save();
 f.environment.FTOERS_EMSDK_ENV=join(f.root,'missing/emsdk_env.sh');
 let result=f.run('--fb','--plan');assert.equal(result.status,0,result.stderr);assert.match(result.stdout,/Git update: FB/);assert.doesNotMatch(result.stdout,/public\/(finder|virtual)|Emscripten/);
 result=f.run('--virtual','--FB','--lock','--skip-install');assert.equal(result.status,0,result.stderr);
 const commands=(await readFile(f.log,'utf8')).trim().split('\n').map(JSON.parse);
 assert.equal(commands.some(c=>c.name==='git'),false);
 assert.equal(commands.filter(c=>c.name==='npm'&&c.args[0]==='run').length,2);
 assert.ok(commands.every(c=>!c.cwd.includes('finder')));
 assert.equal(await readlink(join(f.root,'public/FB')),'../submodules/FB/dist');
 result=f.run('--LOCK-NOT-A-SITE','--plan');assert.notEqual(result.status,0);
 result=f.run('--lock','--fb','--plan');assert.equal(result.status,0,result.stderr);assert.match(result.stdout,/Git update: \(none\)/);assert.doesNotMatch(result.stdout,/public\/virtual/);
});
