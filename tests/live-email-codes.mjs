// Opt-in hosted Auth test. Admin generateLink returns codes without mailing them.
// Only this disposable user is created/modified/deleted; never use a real account.
import {createClient} from '@supabase/supabase-js';
import {randomBytes} from 'node:crypto';
import assert from 'node:assert/strict';
import {backendConfig} from '../public/shared/config.js';
const serviceKey=process.env.FTOERS_SMOKE_SERVICE_KEY;
if(!serviceKey)throw Error('FTOERS_SMOKE_SERVICE_KEY is required in the Node environment only.');
const options={auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}};
const admin=createClient(backendConfig.url,serviceKey,options),email='ftoers-code-qa-'+randomBytes(6).toString('hex')+'@example.com';
const password=randomBytes(20).toString('base64url')+'A7!',nextPassword=randomBytes(20).toString('base64url')+'B9!';let id;
try{
 const generated=await admin.auth.admin.generateLink({type:'signup',email,password,options:{redirectTo:'http://127.0.0.1:5173/'}});if(generated.error)throw generated.error;
 id=generated.data.user.id;assert.ok(generated.data.properties.email_otp);
 const otherBrowser=createClient(backendConfig.url,backendConfig.key,options);
 const verified=await otherBrowser.auth.verifyOtp({email,token:generated.data.properties.email_otp,type:'email'});if(verified.error)throw verified.error;assert.equal(verified.data.user.id,id);assert.ok(verified.data.user.email_confirmed_at);
 console.log('PASS: email code confirms signup in a client with no original browser verifier.');
 const recovery=await admin.auth.admin.generateLink({type:'recovery',email,options:{redirectTo:'http://127.0.0.1:5173/'}});if(recovery.error)throw recovery.error;
 const anotherBrowser=createClient(backendConfig.url,backendConfig.key,options);
 const recovered=await anotherBrowser.auth.verifyOtp({email,token:recovery.data.properties.email_otp,type:'recovery'});if(recovered.error)throw recovered.error;assert.equal(recovered.data.user.id,id);
 const changed=await anotherBrowser.auth.updateUser({password:nextPassword});if(changed.error)throw changed.error;
 const fresh=createClient(backendConfig.url,backendConfig.key,options);const signedIn=await fresh.auth.signInWithPassword({email,password:nextPassword});if(signedIn.error)throw signedIn.error;assert.equal(signedIn.data.user.id,id);
 console.log('PASS: recovery code sets a new password in another client, and the new password signs in.');
 console.log('No verification or recovery email was sent by this test.');
}finally{if(id){const deleted=await admin.auth.admin.deleteUser(id);if(deleted.error)throw deleted.error;console.log('Disposable Auth user removed.');}}
