import {readFile,writeFile,mkdir,rm,lstat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {dirname,resolve,relative,sep} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const sharedFiles=['account.js','account.css','config.js','supabase.js','SUPABASE-LICENSE','wca.svg','profile.js','merge-callback.html','merge-callback.js'];
const canonical=fileURLToPath(new URL('../public/shared/',import.meta.url));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
async function optional(file){try{return await readFile(file);}catch(error){if(error.code==='ENOENT')return null;throw error;}}

// Copies are checked in with their consumer, so a standalone clone needs no
// parent checkout, symlinks, network download or extra development server.
export async function syncShared(target,{source=canonical}={}){
 target=resolve(target);source=resolve(source);
 const directory=await lstat(target).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
 if(directory&&!directory.isDirectory())throw Error(`Shared target must be a real directory: ${target}`);
 if(target===source)throw Error('Shared target must differ from the canonical source.');
 const manifestPath=resolve(target,'.ftoers-shared.json');
 const previous=JSON.parse((await optional(manifestPath))?.toString()??'{"files":{}}');
 const payloads=new Map(),files={};
 for(const name of sharedFiles){const bytes=await readFile(resolve(source,name));payloads.set(name,bytes);files[name]=hash(bytes);}
 // Validate every managed file before changing any of them. Protect local edits.
 for(const name of new Set([...Object.keys(previous.files),...sharedFiles])){
  if(!/^[A-Za-z0-9_.-]+$/.test(name)||name==='.'||name==='..')throw Error('Invalid shared manifest filename.');
  const path=resolve(target,name);const stat=await lstat(path).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
  if(stat&&!stat.isFile())throw Error(`Shared sync refuses non-file: ${path}`);
  const current=await optional(path);if(!current)continue;
  const digest=hash(current);
  if(digest!==files[name]&&digest!==previous.files[name])throw Error(`Shared sync would overwrite local changes: ${path}. Move the edit to the canonical shared client or save it elsewhere before syncing.`);
 }
 await mkdir(target,{recursive:true});
 for(const [name,bytes] of payloads)await writeFile(resolve(target,name),bytes);
 for(const name of Object.keys(previous.files))if(!files[name])await rm(resolve(target,name),{force:true});
 await writeFile(manifestPath,JSON.stringify({source:'FTOers public/shared',files},null,2)+'\n');
 console.log(`  [shared] ${target}`);
}
// Remove only verified generated copies before Git merges their upstream versions.
// Keep an on-disk backup; hand edits and staged files always require user action.
export async function prepareSharedUpdate(repo,target,{source=canonical}={}){
 repo=resolve(repo);target=resolve(target);source=resolve(source);
 const prefix=relative(repo,target);
 if(!prefix||prefix.startsWith('..'+sep)||prefix==='..')throw Error('Shared update target must be inside its repository.');
 const git=(args)=>{const r=spawnSync('git',args,{cwd:repo,encoding:'utf8'});if(r.error)throw r.error;if(r.status!==0)throw Error(r.stderr.trim()||'Cannot inspect shared copies before updating.');return r.stdout;};
 const changed=git(['diff','--name-only','-z','HEAD','--',prefix]).split('\0').filter(Boolean);
 const untracked=git(['ls-files','--others','--exclude-standard','-z','--',prefix]).split('\0').filter(Boolean);
 const paths=[...new Set([...changed,...untracked])];if(!paths.length)return;
 if(git(['diff','--cached','--name-only','--',prefix]).trim())throw Error(`Commit or unstage shared edits in ${repo} before updating.`);
 const manifest=JSON.parse((await optional(resolve(target,'.ftoers-shared.json')))?.toString()??'null');
 if(manifest?.source!=='FTOers public/shared'||!manifest.files)throw Error(`Cannot verify generated shared copies in ${target}; preserve or commit them before updating.`);
 const payloads=new Map();
 for(const path of paths){
  const name=relative(target,resolve(repo,path));
  if(name!=='.ftoers-shared.json'&&!sharedFiles.includes(name))throw Error(`Unmanaged shared edit: ${path}. Commit or preserve it before updating.`);
  const info=await lstat(resolve(repo,path));if(!info.isFile())throw Error(`Shared update refuses non-file: ${path}`);
  const bytes=await readFile(resolve(repo,path));
  if(name!=='.ftoers-shared.json'){
   const upstream=await optional(resolve(source,name));
   if(hash(bytes)!==manifest.files[name]&&(!upstream||hash(bytes)!==hash(upstream)))throw Error(`Shared update would overwrite local edits: ${path}. Move them to the canonical shared client or commit them first.`);
  }
  payloads.set(path,bytes);
 }
 const gitDir=git(['rev-parse','--absolute-git-dir']).trim();
 const backup=resolve(gitDir,'ftoers-shared-backups',new Date().toISOString().replaceAll(':','-')+'-'+process.pid);
 for(const [path,bytes] of payloads){const out=resolve(backup,path);await mkdir(dirname(out),{recursive:true});await writeFile(out,bytes);}
 if(changed.length)git(['restore','--source=HEAD','--worktree','--',...changed]);
 for(const path of untracked)await rm(resolve(repo,path));
 console.log(`  [shared] Preserved generated copies in ${backup}; restoring tracked versions for Git update.`);
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const targets=process.argv.slice(2);if(!targets.length)throw Error('Usage: node scripts/sync-shared.mjs <repo/public/shared> [...]');
 for(const target of targets)await syncShared(resolve(process.cwd(),target));
}
