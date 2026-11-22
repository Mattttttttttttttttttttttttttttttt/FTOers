import {openProfile} from './profile.js';
import {createClient} from './supabase.js';
import {backendConfig} from './config.js';
export const configured=!!(backendConfig.url&&backendConfig.key);
export const client=configured?createClient(backendConfig.url,backendConfig.key,{auth:{storageKey:'ftoers.auth.v1',flowType:'pkce',detectSessionInUrl:true}}):null;
export let profile=null;
export let session=null;
const callbackParams=new URLSearchParams(location.search),callbackHash=new URLSearchParams(location.hash.slice(1));
const callbackError=callbackParams.get('error_code')??callbackHash.get('error_code')??callbackParams.get('error')??callbackHash.get('error');
const changes=new EventTarget();
export const onAccountChange=fn=>{changes.addEventListener('change',fn);return()=>changes.removeEventListener('change',fn);};
export async function rpc(name,args={}, {signal}={}){
 if(!client)throw Error('FTOers accounts are not configured yet.');
 const request=client.rpc(name,args);const {data,error}=await(signal?request.abortSignal(signal):request);if(error)throw Error(error.message);return data;
}
let revision=0;
async function refresh(next){
 const version=++revision;if(next?.user?.id!==session?.user?.id||!next)profile=null;session=next;let profileKnown=!next;
 if(next){try{const p=await rpc('my_profile');if(version!==revision)return;if(p?.reauth_required){await client.auth.signOut({scope:'local'});session=null;profile=null;changes.dispatchEvent(new Event('change'));openAccount('login');message('This account was merged. Sign in again to continue.');return;}profile=p;profileKnown=true;}catch(error){console.warn('FTOers account:',error.message);}}
 if(version!==revision)return;if(profile)clearVerification();changes.dispatchEvent(new Event('change'));
 if(session&&!profile&&profileKnown&&!['new-password','verify-recovery'].includes(mode))openAccount('username');
 else if(profile&&dialog?.open&&['login','signup','username','verify-signup'].includes(mode)){clearVerification();dialog.close();}
}
export async function reloadAccount(){if(!client)return;const {data,error}=await client.auth.getSession();if(error)throw error;await refresh(data.session);}
export const ready=client?client.auth.getSession().then(async({data,error})=>{if(error)throw error;await refresh(data.session);}).catch(error=>{console.warn('FTOers account:',error.message);if(callbackError){openAccount(session?'account':'login');dialog.dataset.state='error';message(['identity_already_exists','identity_already_linked'].includes(callbackError)?'This WCA account is already connected to another FTOers profile. Open Profile → Merge accounts to combine them.':'Sign-in was not completed. Please try again.');}}):Promise.resolve();
client?.auth.onAuthStateChange((event,next)=>{if(event==='INITIAL_SESSION')return;setTimeout(()=>refresh(next),0);});
let dialog,mode='login',pendingVerification=null;
try{const saved=JSON.parse(sessionStorage.getItem('ftoers.email-verification.v1')??'null');if(['signup','recovery'].includes(saved?.kind)&&typeof saved.email==='string'&&saved.email.length<=254&&saved.email.includes('@'))pendingVerification=saved;}catch{}
function clearVerification(){pendingVerification=null;try{sessionStorage.removeItem('ftoers.email-verification.v1');}catch{}}
function beginVerification(kind,email){pendingVerification={kind,email};try{sessionStorage.setItem('ftoers.email-verification.v1',JSON.stringify(pendingVerification));}catch{}openAccount('verify-'+kind);}

function ensureDialog(){
 if(dialog)return;
 const css=document.createElement('link');css.rel='stylesheet';css.href=new URL('./account.css',import.meta.url).href;document.head.append(css);
 dialog=document.createElement('dialog');dialog.className='ft-dialog ft-auth';dialog.setAttribute('aria-labelledby','ft-account-title');
 dialog.innerHTML=`<header><h2 id="ft-account-title">Sign in</h2><button type="button" class="ft-close" aria-label="Close account">×</button></header>
 <p class="ft-description" hidden></p>
 <div class="ft-oauth"><button class="ft-google" type="button"><svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M21.6 12.23c0-.71-.06-1.39-.18-2.05H12v3.88h5.38a4.6 4.6 0 0 1-2 3.02 6.05 6.05 0 1 1-3.38-11.12c1.44 0 2.73.5 3.75 1.49l2.81-2.81A9.9 9.9 0 0 0 12 2a10 10 0 1 0 0 20c5.77 0 9.6-4.05 9.6-9.77Z"/></svg><span>Continue with Google</span></button><button class="ft-wca" type="button"><img src="${new URL('./wca.svg',import.meta.url).href}" alt=""><span>Continue with WCA</span></button><div class="ft-divider"><span>or</span></div></div>
 <form><label data-code hidden>Verification code<input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6,10}" minlength="6" maxlength="10" placeholder="Code from email"></label><label data-identity>Username or email<input name="identity" autocomplete="username" required maxlength="254"></label><label data-email hidden>Email<input name="email" type="email" autocomplete="email" maxlength="254"></label><label data-name hidden>Username<input name="username" autocomplete="nickname" pattern="[A-Za-z0-9_]{3,24}" minlength="3" maxlength="24"><small>3–24 letters, numbers or underscores</small></label><label data-wca hidden>WCA ID <span class="ft-optional">(optional)</span><input name="wca_id" autocomplete="off" autocapitalize="characters" spellcheck="false" pattern="[0-9]{4}[A-Za-z]{4}[0-9]{2}" maxlength="10" placeholder="e.g. 2024ASHR02"><small>A typed ID is self-reported. Connect your WCA account to verify it.</small></label><p data-wca-details hidden></p><button data-connect-wca type="button" hidden>Connect WCA account</button><div data-password><div class="ft-label-row"><label for="ft-password">Password</label><button data-reset type="button">Forgot password?</button></div><div class="ft-password-control"><input id="ft-password" name="password" type="password" autocomplete="current-password" minlength="8" maxlength="256" required><button class="ft-password-toggle" data-password-toggle="ft-password" type="button" aria-controls="ft-password" aria-pressed="false" aria-label="Show password"></button></div></div><div data-confirm hidden><label for="ft-password-confirm">Confirm password</label><div class="ft-password-control"><input id="ft-password-confirm" name="confirm" type="password" autocomplete="new-password" minlength="8" maxlength="256" aria-describedby="ft-password-mismatch"><button class="ft-password-toggle" data-password-toggle="ft-password-confirm" type="button" aria-controls="ft-password-confirm" aria-pressed="false" aria-label="Show confirmation password"></button></div><small id="ft-password-mismatch" hidden>Passwords do not match.</small></div><button class="ft-submit" type="submit">Sign in</button></form>
 <p class="ft-notice" role="status" aria-live="polite"></p><div class="ft-auth-footer"><span data-switch-caption>New to FTOers?</span><button class="ft-switch" type="button">Create an account</button><button data-resend type="button" hidden>Resend code</button><button data-back type="button" hidden>Back to sign in</button><button data-done type="button" hidden>Done</button></div>`;
 document.body.append(dialog);dialog.querySelector('.ft-close').onclick=()=>dialog.close();dialog.addEventListener('close',()=>document.dispatchEvent(new Event('ftoers-account-close')));
 dialog.querySelector('.ft-switch').onclick=()=>openAccount(mode==='login'?'signup':'login');
 dialog.querySelector('[data-reset]').onclick=()=>openAccount('reset');
 dialog.querySelector('[data-back]').onclick=()=>{clearVerification();openAccount('login');};
 dialog.querySelector('[name=code]').oninput=event=>{event.target.value=event.target.value.replace(/\D/g,'').slice(0,10);};
 dialog.querySelector('[data-resend]').onclick=()=>busy(async()=>{
  if(!client)throw Error('FTOers accounts are not configured yet.');
  if(!pendingVerification)throw Error('Start signup or password reset again.');
  const {kind,email}=pendingVerification;
  const result=kind==='signup'?await client.auth.resend({type:'signup',email,options:{emailRedirectTo:location.origin+location.pathname}}):await client.auth.resetPasswordForEmail(email,{redirectTo:location.origin+location.pathname});
  if(result.error)throw result.error;message('A new code has been sent. Check your email.');
 });
 dialog.querySelector('[data-done]').onclick=()=>{if(session&&!profile)openAccount('username');else dialog.close();};
 const confirm=dialog.querySelector('[name=confirm]');const validateConfirmation=(showError=false)=>{const mismatch=!confirm.disabled&&!!confirm.value&&confirm.value!==dialog.querySelector('[name=password]').value;confirm.setCustomValidity(mismatch?'Passwords do not match.':'');const visible=mismatch&&showError;confirm.setAttribute('aria-invalid',String(visible));dialog.querySelector('#ft-password-mismatch').hidden=!visible;};
 for(const button of dialog.querySelectorAll('[data-password-toggle]')){setPasswordVisibility(button,false);button.onclick=()=>{const input=document.getElementById(button.dataset.passwordToggle);setPasswordVisibility(button,input.type==='password');};}
 confirm.oninput=()=>validateConfirmation();dialog.querySelector('[name=password]').oninput=()=>validateConfirmation();
 confirm.oninvalid=()=>validateConfirmation(true);
 for(const field of dialog.querySelectorAll('[data-password],[data-confirm]'))field.addEventListener('focusout',event=>{if(!field.contains(event.relatedTarget))validateConfirmation(true);});
 dialog.querySelector('[name=wca_id]').oninput=event=>{event.target.value=event.target.value.toUpperCase();};
 dialog.querySelector('.ft-wca').onclick=()=>busy(()=>wcaOAuth(false));
 dialog.querySelector('[data-connect-wca]').onclick=()=>busy(()=>wcaOAuth(true));
 dialog.querySelector('.ft-google').onclick=()=>busy(async()=>{if(!client)throw Error('FTOers accounts are not configured yet.');const {error}=await client.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+location.pathname}});if(error)throw error;});
 dialog.querySelector('form').onsubmit=event=>{event.preventDefault();busy(async()=>{
  if(!client)throw Error('FTOers accounts are not configured yet.');
  const form=new FormData(event.target),password=form.get('password'),email=form.get('email')?.trim(),username=form.get('username')?.trim(),wca_id=form.get('wca_id')?.trim().toUpperCase()||null;
  if(mode==='verify-signup'||mode==='verify-recovery'){
   if(!pendingVerification)throw Error('Start signup or password reset again.');
   const recovering=pendingVerification.kind==='recovery';
   const {data,error}=await client.auth.verifyOtp({email:pendingVerification.email,token:form.get('code').trim(),type:recovering?'recovery':'email'});if(error)throw error;
   clearVerification();if(recovering){openAccount('new-password');await refresh(data.session);}else{mode='login';await refresh(data.session);if(profile)dialog.close();else if(session)openAccount('username');}return;
  }
  if(mode==='account'){profile=await rpc('set_wca_id',{wca_id});changes.dispatchEvent(new Event('change'));dialog.close();return;}
  if(mode==='username'){profile=await rpc('claim_profile',{name:username,wca_id});changes.dispatchEvent(new Event('change'));dialog.close();return;}
  if(mode==='new-password'){const {error}=await client.auth.updateUser({password});if(error)throw error;success('Your password has been updated.');return;}
  if(mode==='reset'){const {error}=await client.auth.resetPasswordForEmail(email,{redirectTo:location.origin+location.pathname});if(error)throw error;beginVerification('recovery',email);return;}
  if(mode==='signup'){
   const {data,error}=await client.auth.signUp({email,password,options:{emailRedirectTo:location.origin+location.pathname,data:{requested_username:username,requested_wca_id:wca_id}}});if(error)throw error;
   if(data.session){await refresh(data.session);profile=await rpc('claim_profile',{name:username,wca_id});changes.dispatchEvent(new Event('change'));dialog.close();}
   else beginVerification('signup',email);return;
  }
  const identity=form.get('identity').trim();
  if(identity.includes('@')){const {data,error}=await client.auth.signInWithPassword({email:identity,password});if(error)throw error;await refresh(data.session);}
  else{const response=await fetch(backendConfig.url+'/functions/v1/username-login',{method:'POST',headers:{'Content-Type':'application/json',apikey:backendConfig.key},body:JSON.stringify({username:identity,password})});const data=await response.json();if(!response.ok)throw Error(data.error||'Sign-in failed');const result=await client.auth.setSession(data);if(result.error)throw result.error;await refresh(result.data.session);}
  if(profile)dialog.close();
 });};
}
async function wcaOAuth(link){
 if(!client)throw Error('FTOers accounts are not configured yet.');
 if(link&&!session)throw Error('Sign in before connecting a WCA account.');
 const options={provider:'custom:wca',options:{redirectTo:location.origin+location.pathname}};
 const {error}=link?await client.auth.linkIdentity(options):await client.auth.signInWithOAuth(options);
 if(error){if(['identity_already_exists','identity_already_linked'].includes(error.code))throw Error('This WCA account is already connected to another FTOers profile. Open Profile → Merge accounts to combine them.');throw error;}
}
function setPasswordVisibility(button,visible){
 const input=document.getElementById(button.dataset.passwordToggle),start=input.selectionStart,end=input.selectionEnd;
 input.type=visible?'text':'password';if(start!==null&&end!==null)input.setSelectionRange(start,end);
 const label=(visible?'Hide ':'Show ')+(input.name==='confirm'?'confirmation password':'password');
 button.setAttribute('aria-label',label);button.setAttribute('aria-pressed',String(visible));button.title=label;
 button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>'+(visible?'<path d="m3 3 18 18"/>':'')+'</svg>';
}
export function showAccountNotice(text){ensureDialog();message(text);}
function message(text){dialog.querySelector('[role=status]').textContent=text;}
function success(text){dialog.dataset.state='success';dialog.querySelector('.ft-description').hidden=true;dialog.querySelector('h2').textContent={signup:'Check your email',reset:'Check your inbox','new-password':'Password updated'}[mode]??'Done';message(text);dialog.querySelector('form').hidden=true;dialog.querySelector('.ft-oauth').hidden=true;dialog.querySelector('[data-switch-caption]').hidden=true;dialog.querySelector('.ft-switch').hidden=true;dialog.querySelector('[data-back]').hidden=mode==='new-password';dialog.querySelector('[data-done]').hidden=mode!=='new-password';}
function accountError(error){
 if(error?.code==='over_email_send_rate_limit'||/email rate limit exceeded/i.test(error?.message??''))return 'The site has reached its hourly email limit. No email was sent. Please try again later.';
 if(error?.code==='over_request_rate_limit')return 'Too many requests. Please wait a moment and try again.';
 return error?.message??'Something went wrong. Please try again.';
}
async function busy(fn){message('');delete dialog.dataset.state;const buttons=[...dialog.querySelectorAll('button:not(.ft-close)')];buttons.forEach(b=>b.disabled=true);dialog.setAttribute('aria-busy','true');try{await fn();}catch(error){dialog.dataset.state='error';message(accountError(error));}finally{buttons.forEach(b=>b.disabled=false);dialog.removeAttribute('aria-busy');}}
export function openAccount(next='login'){
 if(profile&&!['new-password','account'].includes(next)){openProfile();return;}
 ensureDialog();mode=next==='new-password'?'new-password':session&&!profile?'username':next==='login'&&pendingVerification?'verify-'+pendingVerification.kind:next;
 const titles={account:'WCA account','verify-signup':'Confirm your email','verify-recovery':'Reset your password',login:'Sign in',signup:'Create account',username:'Choose your username',reset:'Reset password','new-password':'Set a new password'};
 const verificationDescription='Enter the code sent to '+(pendingVerification?.email??'your email')+'. You can read the email on another device.';
 const descriptions={account:'Connect your WCA account to verify your identity on the leaderboard. Your FTOers profile and results stay together.','verify-signup':verificationDescription,'verify-recovery':verificationDescription,username:'Your username will appear beside your shared solves and leaderboard results.',reset:'Enter your account email and we’ll send you a verification code.','new-password':'Choose a new password with at least 8 characters.'};
 dialog.querySelector('h2').textContent=titles[mode];
 const description=dialog.querySelector('.ft-description');description.textContent=descriptions[mode]??'';description.hidden=!description.textContent;
 dialog.querySelector('form').reset();delete dialog.dataset.state;
 if(mode==='username')dialog.querySelector('[name=username]').value=session?.user?.user_metadata?.requested_username??'';
 const wcaIdentity=session?.user?.identities?.find(identity=>identity.provider==='custom:wca');
 const connected=profile?!!profile.wca_connected:!!wcaIdentity;
 const wcaId=connected?(profile?profile.wca_id??'':wcaIdentity?.identity_data?.custom_claims?.wca_id??''):(mode==='account'?profile?.wca_id:session?.user?.user_metadata?.requested_wca_id)??'';
 const wcaInput=dialog.querySelector('[name=wca_id]');wcaInput.value=wcaId;
 const details=dialog.querySelector('[data-wca-details]');details.textContent=connected?'Connected to '+(profile?.wca_name??wcaIdentity?.identity_data?.full_name??wcaIdentity?.identity_data?.name??'your WCA account')+(wcaId?' · '+wcaId+' (verified)':' · No WCA ID assigned yet')+'.':'';
 for(const [selector,visible] of Object.entries({'form':true,'[data-wca]':['signup','username','account'].includes(mode)&&!connected,'[data-wca-details]':['username','account'].includes(mode)&&connected,'[data-connect-wca]':mode==='account'&&!connected,'.ft-submit':mode!=='account'||!connected,'[data-code]':mode.startsWith('verify-'),'[data-resend]':mode.startsWith('verify-'),'[data-identity]':mode==='login','[data-email]':['signup','reset'].includes(mode),'[data-name]':['signup','username'].includes(mode),'[data-password]':['login','signup','new-password'].includes(mode),'[data-confirm]':['signup','new-password'].includes(mode),'.ft-oauth':['login','signup'].includes(mode),'.ft-switch':['login','signup'].includes(mode),'[data-switch-caption]':['login','signup'].includes(mode),'[data-reset]':mode==='login','[data-back]':mode==='reset'||mode.startsWith('verify-'),'[data-done]':false}))dialog.querySelector(selector).hidden=!visible;
 for(const input of dialog.querySelectorAll('input')){input.disabled=input.closest('label,[data-password],[data-confirm]').hidden;input.required=!input.disabled&&input.name!=='wca_id';input.setCustomValidity('');}
 for(const button of dialog.querySelectorAll('[data-password-toggle]'))setPasswordVisibility(button,false);
 dialog.querySelector('#ft-password-mismatch').hidden=true;dialog.querySelector('[name=confirm]').removeAttribute('aria-invalid');
 dialog.querySelector('[name=password]').autocomplete=mode==='signup'||mode==='new-password'?'new-password':'current-password';
 dialog.querySelector('.ft-submit').textContent={account:'Save WCA ID','verify-signup':'Confirm email','verify-recovery':'Verify code',login:'Sign in',signup:'Create account',username:'Save username',reset:'Send reset email','new-password':'Save password'}[mode];
 dialog.querySelector('.ft-switch').textContent=mode==='login'?'Create an account':'Sign in';
 dialog.querySelector('[data-switch-caption]').textContent=mode==='login'?'New to FTOers?':'Already have an account?';
 message(configured?'':'FTOers accounts are not configured yet.');if(!dialog.open){dialog.showModal();document.dispatchEvent(new Event('ftoers-account-open'));}
 dialog.querySelector('input:not(:disabled)')?.focus();
}
let surfaceOptions={};
const personIcon='<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="3.4"/><path d="M5 21v-2a7 7 0 0 1 14 0v2"/></svg>';
function photoURL(){const value=session?.user?.user_metadata?.avatar_url??session?.user?.user_metadata?.picture;try{const url=new URL(value);return url.protocol==='https:'?url.href:null;}catch{return null;}}
export function renderAccountAvatar(host){avatar(host);}
function avatar(host){host.replaceChildren();const photo=photoURL();if(session&&photo){const img=document.createElement('img');img.src=photo;img.alt='';img.referrerPolicy='no-referrer';host.append(img);}else if(session){host.textContent=(profile?.username??session.user?.user_metadata?.full_name??'A').slice(0,1).toUpperCase();}else host.innerHTML=personIcon;}
function openSiteSettings(){surfaceOptions.onSettings?.();}
function openSiteAbout(){surfaceOptions.onAbout?.();}
export function mountAccount(host,options={}){
 surfaceOptions=options;document.documentElement.dataset.ftSurface=options.surface??'home';ensureDialog();
 const button=document.createElement('button');button.className='ft-avatar-trigger';button.id='ft-account-trigger';button.type='button';button.setAttribute('aria-label','Account menu');button.setAttribute('aria-haspopup','menu');button.setAttribute('aria-expanded','false');
 const picture=document.createElement('span');picture.className='ft-avatar';button.append(picture);host.append(button);
 const menu=document.createElement('div');menu.id='ft-account-menu';menu.className='ft-menu';menu.setAttribute('popover','auto');menu.setAttribute('role','menu');menu.setAttribute('aria-label','Account');document.body.append(menu);button.setAttribute('aria-controls',menu.id);
 function close(){if(menu.matches(':popover-open'))menu.hidePopover();}
 function open(){const box=button.getBoundingClientRect();menu.style.top=(box.bottom+10)+'px';menu.style.right=Math.max(12,innerWidth-box.right)+'px';menu.showPopover();menu.querySelector('button')?.focus();}
 button.onclick=()=>menu.matches(':popover-open')?close():open();
 button.onkeydown=e=>{if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();open();}};
 menu.addEventListener('toggle',()=>{const active=menu.matches(':popover-open');button.setAttribute('aria-expanded',String(active));document.dispatchEvent(new Event(active?'ftoers-account-open':'ftoers-account-close'));});
 menu.onkeydown=e=>{const items=[...menu.querySelectorAll('button:not(:disabled)')],index=items.indexOf(document.activeElement);if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();const next=e.key==='Home'?0:e.key==='End'?items.length-1:(index+(e.key==='ArrowDown'?1:-1)+items.length)%items.length;items[next]?.focus();}if(e.key==='Escape'){close();button.focus();}};
 function action(label,fn,{id,danger=false}={}){const item=document.createElement('button');item.type='button';item.setAttribute('role','menuitem');item.textContent=label;if(id)item.id=id;if(danger)item.className='ft-menu-danger';item.onclick=async()=>{close();await fn();};menu.append(item);}
 const render=()=>{avatar(picture);button.title=profile?.username??'Account';button.dataset.signedIn=String(!!session);menu.replaceChildren();
  if(!session)action('Sign in',()=>openAccount());
  if(session)action('Profile',openProfile,{id:'profile'});
  if(options.onSettings)action('Settings',openSiteSettings,{id:'settings'});
  if(options.onAbout)action('About us',openSiteAbout,{id:'about'});
  if(profile?.admin&&options.onReview)action('Review solves',options.onReview,{id:'review-solves'});

 };render();onAccountChange(render);ready.then(render);return button;
}
if(client){client.auth.onAuthStateChange(event=>{if(event==='PASSWORD_RECOVERY')setTimeout(()=>openAccount('new-password'),0);});}
