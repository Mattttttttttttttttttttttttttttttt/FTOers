// Explicitly authorized live backend smoke test. Uses disposable password
// accounts only; never merges a real user's profiles or creates leaderboard rows.
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {backendConfig} from '../public/shared/config.js';
const key=process.env.SUPABASE_SECRET_KEY;
if(!key)throw Error('A server-side key and explicit authorization are required.');
const options={auth:{persistSession:false,autoRefreshToken:false}};
const admin=createClient(backendConfig.url,key,options),created=[];
const check=(result,label)=>{if(result.error)throw Error(label+': '+(result.error.code??'request failed'));return result.data;};
const request=async(token,body)=>{
 const response=await fetch(backendConfig.url+'/functions/v1/merge-accounts',{method:'POST',headers:{origin:'http://127.0.0.1:5173',apikey:backendConfig.key,Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(body)});
 return {status:response.status,data:await response.json()};
};
try{
 const nonce=randomBytes(5).toString('hex');
 for(const [i,prefix] of ['MergeA','MergeB','MergeC'].entries()){
  const email=`ftoers-merge-${nonce}-${i}@example.invalid`,password=randomBytes(24).toString('hex');
  const {user}=check(await admin.auth.admin.createUser({email,password,email_confirm:true}),'Create temporary account');
  const account={id:user.id,email,password,name:prefix+'_'+nonce,client:createClient(backendConfig.url,backendConfig.key,options)};created.push(account);
  const signed=check(await account.client.auth.signInWithPassword({email,password}),'Sign in temporary account');account.token=signed.session.access_token;
  check(await account.client.rpc('claim_profile',{name:account.name,wca_id:null}),'Claim temporary profile');
 }
 const [a,b,c]=created;
 a.name='Renamed_'+nonce;
 assert.equal(check(await a.client.rpc('rename_username',{name:a.name}),'Rename profile').username,a.name);
 const duplicate=await a.client.rpc('rename_username',{name:b.name.toLowerCase()});assert.match(duplicate.error?.message??'',/already taken/i);
 assert.equal(check(await a.client.rpc('my_profile'),'Check failed duplicate rename').username,a.name);
 console.log('PASS live username changes, case-insensitive uniqueness, and failed-change preservation.');
 const today=new Date().toISOString().slice(0,10);
 check(await admin.from('short_link_daily_usage').insert([{user_id:a.id,day:today,bytes:350000},{user_id:b.id,day:today,bytes:250000}]),'Seed temporary quota records');
 const proofs={primary_token:a.token,secondary_token:b.token};
 const mismatch=await request(a.token,{action:'preview',primary_token:b.token,secondary_token:a.token});assert.equal(mismatch.status,409);
 const preview=await request(a.token,{action:'preview',...proofs});assert.equal(preview.status,200,'Live merge preview: '+preview.data.error);assert.equal(preview.data.primary.username,a.name);assert.equal(preview.data.secondary.username,b.name);
 const swapped=await request(a.token,{action:'confirm',...proofs,secondary_token:c.token,ticket:preview.data.ticket,keep:'secondary'});assert.equal(swapped.status,409);
 console.log('PASS live fresh-auth proofs, preview, and rejection of a substituted account.');
 const merged=await request(a.token,{action:'confirm',...proofs,ticket:preview.data.ticket,keep:'secondary'});assert.equal(merged.status,200,'Live merge confirmation: '+merged.data.error);assert.equal(merged.data.profile_id,b.id);
 for(const account of [a,b]){
  const old=createClient(backendConfig.url,backendConfig.key,{...options,global:{headers:{Authorization:'Bearer '+account.token}}});
  const response=await old.rpc('my_profile');assert.ok(response.error||response.data?.reauth_required===true,'Old session must not access the merged profile');
  check(await account.client.auth.signInWithPassword({email:account.email,password:account.password}),'Fresh sign-in after merge');
  assert.equal(check(await account.client.rpc('my_profile'),'Read merged profile').id,b.id);
 }
 const usage=check(await admin.from('short_link_daily_usage').select('bytes').eq('user_id',b.id).single(),'Read combined quota');assert.equal(usage.bytes,500000);
 console.log('PASS live merge, old-session blocking, both fresh logins resolving to one profile, and quota preservation.');
 const finalName='Combined_'+nonce;
 assert.equal(check(await a.client.rpc('rename_username',{name:finalName}),'Rename from merged alias').id,b.id);
 assert.equal(check(await b.client.rpc('my_profile'),'Read rename through other login').username,finalName);
 const loginResponse=await fetch(backendConfig.url+'/functions/v1/username-login',{method:'POST',headers:{origin:'http://127.0.0.1:5173',apikey:backendConfig.key,'Content-Type':'application/json'},body:JSON.stringify({username:finalName,password:b.password})});
 assert.equal(loginResponse.status,200,'Username login after merge must work');
 const login=await loginResponse.json();assert.ok(login.access_token&&login.refresh_token);
 assert.equal(check(await c.client.rpc('my_profile'),'Check unrelated account').username,c.name);
 console.log('PASS live rename through either login, merged username/password login, and unrelated-account isolation.');
}finally{
 const failures=[];
 for(const account of created){const result=await admin.auth.admin.deleteUser(account.id);if(result.error)failures.push(account.id);}
 if(failures.length)throw Error('Temporary-account cleanup needs attention ('+failures.length+' account(s)).');
 console.log('Deleted all temporary accounts and their test profiles, merge metadata and quota rows. No email, solves or submissions created.');
}
