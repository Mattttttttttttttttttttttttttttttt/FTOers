import {spawnSync} from 'node:child_process';
import {access} from 'node:fs/promises';
import {resolve} from 'node:path';
import {homedir} from 'node:os';

// Source the SDK in a child shell and import only its exported environment.
// Nothing is installed, activated or written to the caller's shell here.
export async function emscriptenEnv(version,{env=process.env}={}){
 const matches=candidate=>{const result=spawnSync('emcc',['--version'],{env:candidate,encoding:'utf8'});return result.status===0&&new RegExp(`\\b${version.replaceAll('.','\\.')}\\b`).test(result.stdout.split('\n')[0]);};
 if(!/^\d+\.\d+\.\d+$/.test(version))throw Error('Invalid Emscripten version');
 if(!env.FTOERS_EMSDK_ENV&&matches(env))return env;
 const home=env.HOME??homedir(),data=env.XDG_DATA_HOME??resolve(home,'.local/share');
 const candidates=env.FTOERS_EMSDK_ENV?[env.FTOERS_EMSDK_ENV]:[
  ...(env.EMSDK?[resolve(env.EMSDK,'emsdk_env.sh')]:[]),
  resolve(data,'ftoers/emsdk/emsdk_env.sh'),resolve(data,'emsdk/emsdk_env.sh'),
  resolve(home,'emsdk/emsdk_env.sh'),resolve(home,'.emsdk/emsdk_env.sh')
 ];
 for(const file of new Set(candidates)){
  try{await access(file);}catch{continue;}
  const result=spawnSync('bash',['-c','source "$1" >/dev/null && env -0','ftoers-emsdk',resolve(file)],{env,encoding:'utf8',maxBuffer:2*1024*1024});
  if(result.status!==0)continue;
  const sdkEnv=Object.fromEntries(result.stdout.split('\0').filter(Boolean).map(item=>{const at=item.indexOf('=');return [item.slice(0,at),item.slice(at+1)];}));
  if(matches(sdkEnv)){console.log(`  [sdk] Emscripten ${version} · ${file}`);return sdkEnv;}
 }
 throw Error(`Emscripten ${version} is required for this build. No matching emcc was found on PATH or in the installed SDKs. Install/activate ${version} in an emsdk checkout, then set FTOERS_EMSDK_ENV=/path/to/emsdk/emsdk_env.sh (or source it before running this script).`);
}
