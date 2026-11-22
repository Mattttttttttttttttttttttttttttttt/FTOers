// Preview by default. --apply changes hosted Auth configuration and requires
// Abid's hand testing and explicit deployment approval for this update.
import {readFile} from 'node:fs/promises';
import {homedir} from 'node:os';
import {resolve} from 'node:path';
import {createClient} from '@supabase/supabase-js';
import {backendConfig} from '../public/shared/config.js';
const file=process.env.FTOERS_WCA_CONFIG??resolve(homedir(),'.config/ftoers/wca.json');
const credentials=JSON.parse(await readFile(file,'utf8'));
if(!credentials.client_id||!credentials.client_secret)throw Error('Fill client_id and client_secret in the private WCA config file.');
const url=process.env.SUPABASE_URL??backendConfig.url;
if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url))throw Error('Use the project HTTPS supabase.co URL.');
const config={
 provider_type:'oauth2',identifier:'custom:wca',name:'WCA',
 client_id:credentials.client_id,client_secret:credentials.client_secret,
 authorization_url:'https://www.worldcubeassociation.org/oauth/authorize',
 token_url:'https://www.worldcubeassociation.org/oauth/token',
 userinfo_url:url+'/functions/v1/wca-userinfo',
 scopes:['public'],pkce_enabled:true,email_optional:true,
 custom_claims_allowlist:['wca_id','wca_user_id'],enabled:true,
};
if(!process.argv.includes('--apply')){
 console.log('Preview only. No hosted configuration changed.');
 console.log(JSON.stringify({...config,client_id:'[private config]',client_secret:'[redacted]'},null,2));
 console.log('Deploy the adapter/migration and enable manual identity linking only after hand testing and release approval.');
}else{
 const key=process.env.SUPABASE_SECRET_KEY;
 if(!key)throw Error('Set SUPABASE_SECRET_KEY to a server-side secret/service-role key for the approved update.');
 const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const providers=client.auth.admin.customProviders;
 const {data,error}=await providers.listProviders();
 if(error)throw Error('Could not list Auth providers: '+error.code);
 const existing=data.providers.find(provider=>provider.identifier==='custom:wca');
 const {provider_type:_type,identifier:_identifier,...update}=config;
 const result=existing?await providers.updateProvider(config.identifier,update):await providers.createProvider(config);
 if(result.error)throw Error('Could not configure WCA provider: '+result.error.code);
 console.log('WCA provider configured. No credentials were printed.');
}
