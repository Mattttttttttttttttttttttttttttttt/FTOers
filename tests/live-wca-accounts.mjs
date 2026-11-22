// Explicit live smoke check. Creates a temporary account, sends no email,
// requests an OAuth linking URL without consent, and deletes the account.
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {backendConfig} from '../public/shared/config.js';
const key=process.env.SUPABASE_SECRET_KEY;
if(!key)throw Error('Set the server-side SUPABASE_SECRET_KEY for an explicitly authorized live check.');
const options={auth:{persistSession:false,autoRefreshToken:false}};
const admin=createClient(backendConfig.url,key,options),client=createClient(backendConfig.url,backendConfig.key,options);
const check=result=>{if(result.error)throw Error(result.error.code??'Live WCA operation failed');return result.data;};
let uid;
try{
 const nonce=randomBytes(6).toString('hex'),email=`wca-check-${nonce}@example.invalid`,password=randomBytes(32).toString('hex');
 const {user}=check(await admin.auth.admin.createUser({email,password,email_confirm:true}));uid=user.id;
 const signed=check(await client.auth.signInWithPassword({email,password}));assert.equal(signed.user.id,uid);
 const profile=check(await client.rpc('claim_profile',{name:'WcaCheck_'+nonce,wca_id:'2024ashr02'}));
 assert.equal(profile.id,uid);assert.equal(profile.wca_id,'2024ASHR02');assert.equal(profile.wca_verified,false);
 console.log('Live username/optional WCA-ID onboarding works; self-reported ID is unverified.');
 for(const redirectTo of ['http://127.0.0.1:5173/','https://ftoers.web.app/virtual/']){
  const linked=check(await client.auth.linkIdentity({provider:'custom:wca',options:{redirectTo,skipBrowserRedirect:true}}));
  const url=new URL(linked.url);assert.equal(url.hostname,'www.worldcubeassociation.org');assert.equal(url.pathname,'/oauth/authorize');
  assert.equal(url.searchParams.get('scope'),'public');assert.equal(url.searchParams.get('code_challenge_method'),'S256');
  assert.equal(check(await client.auth.getUser()).user.id,uid);
  console.log('Live linking initiates WCA consent and retains the signed-in UUID for:',redirectTo);
 }
 const result=check(await client.rpc('my_profile'));assert.equal(result.wca_connected,false);
 // A linking URL alone is not proof of WCA ownership.
 assert.equal(result.wca_verified,false);
 assert.ok(Array.isArray(check(await client.rpc('leaderboard_profiles',{kind:'single'}))));
 console.log('Live public WCA leaderboard RPC works; no consent or ownership was fabricated.');
}finally{
 if(uid){check(await admin.auth.admin.deleteUser(uid));console.log('Temporary live-check account and profile deleted. No solves, submissions or emails created.');}
}
