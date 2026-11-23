import {readFile,mkdir,lstat,symlink,rename,unlink} from 'node:fs/promises';
import {resolve,relative,dirname,isAbsolute,sep,extname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {emscriptenEnv} from './emscripten-env.mjs';
import {syncShared,prepareSharedUpdate} from './sync-shared.mjs';

const root=fileURLToPath(new URL('../',import.meta.url));
const submodules=resolve(root,'submodules'),publicDir=resolve(root,'public');
const usage=`Usage: update-subwebsites.sh [--site ... | id ...] [--lock [id ...]] [--plan] [--skip-install]
  No ids: process all configured sites, respecting updating: false.
  --site or ids: select only those submodule roots (case-insensitive); force their Git update.
  Example: ./update-subwebsites.sh --virtual --FB
  Unselected sites are not fetched, built, synced or mounted; their SDKs are not loaded.
  --lock ids: select these roots but never fetch/merge them; build normally.
  --lock with no ids: build all sites without fetching/merging.
  --plan: show the selected Git, shared sync, build and mount actions; change nothing.
  --skip-install: reuse existing npm dependencies instead of npm ci/install.
  Generated shared copies are backed up inside the submodule Git directory before updates.
  Hand edits and staged shared changes are never cleared automatically.
  Never deploys, stages, commits or pushes. Requires Node 20.19+, Git and npm.

submodules.json leaves:
  path: source directory or legacy Node build-script path (plus whitespace-separated args).
  updating: false skips builds/mounts and default Git updates for that root.
  build: true installs npm dependencies and builds path (default: npm run build).
  command: optional command argument array replacing npm run build.
  emscripten: optional SDK version, loaded automatically for this build.
  output: build output relative to path (default: dist).
  required: files required in output (default: index.html).
  shared: optional consumer directory relative to path for checked-in account files.`;
function inside(base,path,label){const full=resolve(base,path),rel=relative(base,full);if(!rel||rel.startsWith('..'+sep)||rel==='..'||isAbsolute(rel))throw Error(`${label} must stay inside ${base}`);return full;}
function flatten(value,prefix=''){
 if(!value||typeof value!=='object'||Array.isArray(value))throw Error(`Invalid site config: ${prefix}`);
 if(Object.hasOwn(value,'path')){
  if(typeof value.path!=='string'||!value.path.trim())throw Error(`Missing path: ${prefix}`);
  const [source,...args]=value.path.trim().split(/\s+/),sourceDir=inside(submodules,source,'Source path');
  const id=relative(submodules,sourceDir).split(sep)[0],repo=resolve(submodules,id);
  const mount=inside(publicDir,prefix,'Public mount');
  if(typeof value.build!=='undefined'&&typeof value.build!=='boolean')throw Error(`build must be boolean: ${prefix}`);
  if(typeof value.updating!=='undefined'&&typeof value.updating!=='boolean')throw Error(`updating must be boolean: ${prefix}`);
  if(value.command&&(!Array.isArray(value.command)||!value.command.length||value.command.some(x=>typeof x!=='string'||!x)))throw Error(`Invalid command: ${prefix}`);
  if(value.emscripten!==undefined&&(!value.build||typeof value.emscripten!=='string'||!/^\d+\.\d+\.\d+$/.test(value.emscripten)))throw Error(`Invalid Emscripten version: ${prefix}`);
  const output=value.build?inside(repo,relative(repo,resolve(sourceDir,value.output??'dist')),'Build output'):sourceDir;
  const shared=value.shared?inside(repo,relative(repo,resolve(sourceDir,value.shared)),'Shared destination'):null;
  const required=value.required??['index.html'];if(!Array.isArray(required)||required.some(x=>typeof x!=='string'))throw Error(`Invalid required files: ${prefix}`);
  for(const name of required)inside(output,name,'Required output');
  return [{...value,prefix,sourceDir,repo,id,mount,args,output,shared,required,updating:value.updating??true}];
 }
 return Object.entries(value).flatMap(([key,entry])=>flatten(entry,prefix?prefix+'/'+key:key));
}
function run(command,cwd,env={}){const result=spawnSync(command[0],command.slice(1),{cwd,env:{...process.env,...env},stdio:'inherit'});if(result.error)throw result.error;if(result.status!==0)throw Error(`${command[0]} failed (${result.status??result.signal}) in ${cwd}`);}
async function stat(path){return lstat(path).catch(error=>{if(error.code==='ENOENT')return null;throw error;});}
async function mount(entry){
 const current=await stat(entry.mount);if(current&&!current.isSymbolicLink())throw Error(`Refusing to replace a real file/directory: ${entry.mount}`);
 await mkdir(dirname(entry.mount),{recursive:true});
 const temporary=entry.mount+`.tmp-${process.pid}`;
 try{await symlink(relative(dirname(entry.mount),entry.output),temporary,'dir');await rename(temporary,entry.mount);}finally{await unlink(temporary).catch(error=>{if(error.code!=='ENOENT')throw error;});}
 console.log(`  [mount] public/${entry.prefix} → ${relative(root,entry.output)}`);
}
async function main(){
 const argv=process.argv.slice(2);if(argv.includes('--help')||argv.includes('-h')){console.log(usage);return;}
 const entries=flatten(JSON.parse(await readFile(resolve(root,'submodules.json'),'utf8')));
 for(const e of entries){const source=await stat(e.sourceDir);e.legacy=!e.build&&(source?.isFile()??!!extname(e.sourceDir));}
 const ids=new Map(entries.map(e=>[e.id.toLowerCase(),e.id]));
 const selected=new Set(),locked=new Set();let afterLock=false,allLocked=false,plan=false,skipInstall=false;
 for(const arg of argv){
  if(arg==='--plan'){plan=true;continue;}if(arg==='--skip-install'){skipInstall=true;continue;}if(arg==='--lock'){afterLock=true;allLocked=true;continue;}
  const id=ids.get((arg.startsWith('--')?arg.slice(2):arg).toLowerCase());if(!id)throw Error(`Unknown submodule id or option: ${arg}. Valid ids: ${[...ids.values()].join(', ')}`);
  selected.add(id);if(afterLock){locked.add(id);allLocked=false;}
 }
 const chosen=entries.filter(e=>!selected.size||selected.has(e.id));
 const updates=[...new Set(chosen.map(e=>e.id))].filter(id=>!allLocked&&!locked.has(id)&&(selected.has(id)||!entries.some(e=>e.id===id&&!e.legacy&&!e.updating)));
 if(plan){
  console.log(`Git update: ${updates.join(', ')||'(none)'}`);
  for(const e of chosen)console.log(e.updating?`public/${e.prefix}: ${e.shared?'sync accounts; ':''}${e.emscripten?'Emscripten '+e.emscripten+'; ':''}${e.build?JSON.stringify(e.command??['npm','run','build'])+'; ':''}mount ${relative(root,e.output)}; require ${e.required.join(', ')}`:`public/${e.prefix}: skip (updating: false)`);
  return;
 }
 for(const e of chosen)if(updates.includes(e.id)&&e.shared&&await stat(e.shared))await prepareSharedUpdate(e.repo,e.shared);
 if(updates.length)run(['git','submodule','update','--init','--remote','--merge','--recursive','--',...updates.map(id=>'submodules/'+id)],root);
 for(const e of chosen){
  if(!e.updating){console.log(`  [skip] public/${e.prefix} — updating: false`);continue;}
  // Validate the mount before doing expensive work or touching consumer copies.
  const source=await stat(e.sourceDir);if(!source)throw Error(`Source missing: ${e.sourceDir}. Initialize/update the submodule first.`);
  const old=await stat(e.mount);if(old&&!old.isSymbolicLink()&&(e.build||!source.isFile()))throw Error(`Refusing to replace a real file/directory: ${e.mount}`);
  const buildEnv=e.emscripten?await emscriptenEnv(e.emscripten):{};
  if(e.shared)await syncShared(e.shared);
  if(e.build){
   if(!skipInstall){const lock=await stat(resolve(e.sourceDir,'package-lock.json'))??await stat(resolve(e.sourceDir,'npm-shrinkwrap.json'));run(['npm',lock?'ci':'install','--include=dev'],e.sourceDir,buildEnv);}
   run(e.command??['npm','run','build'],e.sourceDir,buildEnv);
  }else if(source.isFile()){
   // Legacy Node scripts own BUILD_OUT_DIR; do not point them through an old link.
   if(old?.isSymbolicLink())await unlink(e.mount);await mkdir(dirname(e.mount),{recursive:true});
   run(['node',e.sourceDir,...e.args],dirname(e.sourceDir),{BUILD_OUT_DIR:e.mount});continue;
  }
  for(const name of e.required){const file=await stat(resolve(e.output,name));if(!file?.isFile()||!file.size)throw Error(`Missing or empty public/${e.prefix}/${name}; build the complete browser output before mounting.`);}
  await mount(e);
 }
 console.log('Subwebsites updated locally. Nothing deployed.');
}
main().catch(error=>{console.error('Error: '+error.message);process.exitCode=1;});
