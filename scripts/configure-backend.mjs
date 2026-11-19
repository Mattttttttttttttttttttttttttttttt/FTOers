import {writeFile} from 'node:fs/promises';
const url=process.env.SUPABASE_URL,key=process.env.SUPABASE_PUBLISHABLE_KEY;
if(!url||!key)throw Error('Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY (public/anon key).');
if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url))throw Error('Use the project HTTPS supabase.co URL.');
if(key.startsWith('sb_secret_'))throw Error('Never publish a secret key.');
if(!key.startsWith('sb_publishable_')){
 let payload;try{payload=JSON.parse(Buffer.from(key.split('.')[1],'base64url'));}catch{throw Error('Invalid public key');}
 if(payload.role!=='anon')throw Error('Only an anon/publishable key is allowed in browser configuration.');
}
await writeFile(new URL('../public/shared/config.js',import.meta.url),'// Public browser configuration.\nexport const backendConfig = '+JSON.stringify({url,key})+';\n');
console.log('Public backend configuration written.');
