import {readFile,writeFile,mkdir,rm,lstat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

export const sharedFiles=['account.js','account.css','config.js','supabase.js','SUPABASE-LICENSE','wca.svg'];
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
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const targets=process.argv.slice(2);if(!targets.length)throw Error('Usage: node scripts/sync-shared.mjs <repo/public/shared> [...]');
 for(const target of targets)await syncShared(resolve(process.cwd(),target));
}
