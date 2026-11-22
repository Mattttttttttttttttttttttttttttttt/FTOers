import {createClient} from './supabase.js';
import {backendConfig} from './config.js';
export const configured=!!(backendConfig.url&&backendConfig.key);
export const client=configured?createClient(backendConfig.url,backendConfig.key,{auth:{storageKey:'ftoers.auth.v1',flowType:'pkce',detectSessionInUrl:true}}):null;
export let profile=null;
export let session=null;
const changes=new EventTarget();
export const onAccountChange=fn=>{changes.addEventListener('change',fn);return()=>changes.removeEventListener('change',fn);};
export async function rpc(name,args={}, {signal}={}){
 if(!client)throw Error('FTOers accounts are not configured yet.');
 const request=client.rpc(name,args);const {data,error}=await(signal?request.abortSignal(signal):request);if(error)throw Error(error.message);return data;
}
let revision=0;
async function refresh(next){
 const version=++revision;if(next?.user?.id!==session?.user?.id||!next)profile=null;session=next;let profileKnown=!next;
 if(next){try{const p=await rpc('my_profile');if(version!==revision)return;profile=p;profileKnown=true;}catch(error){console.warn('FTOers account:',error.message);}}
 if(version!==revision)return;changes.dispatchEvent(new Event('change'));
 if(session&&!profile&&profileKnown)openAccount('username');
 else if(profile&&dialog?.open&&['login','signup','username'].includes(mode))dialog.close();
}
export const ready=client?client.auth.getSession().then(async({data,error})=>{if(error)throw error;await refresh(data.session);}).catch(error=>{console.warn('FTOers account:',error.message);}):Promise.resolve();
client?.auth.onAuthStateChange((event,next)=>{if(event==='INITIAL_SESSION')return;setTimeout(()=>refresh(next),0);});
let dialog,mode='login';
function ensureDialog(){
 if(dialog)return;
 const css=document.createElement('link');css.rel='stylesheet';css.href=new URL('./account.css',import.meta.url).href;document.head.append(css);
 dialog=document.createElement('dialog');dialog.className='ft-dialog';dialog.setAttribute('aria-labelledby','ft-account-title');
 dialog.innerHTML=`<header><h2 id="ft-account-title">Sign in</h2><button type="button" class="ft-close" aria-label="Close account">×</button></header>

 <form><label data-identity>Username or email<input name="identity" autocomplete="username" required maxlength="254"></label><label data-email hidden>Email<input name="email" type="email" autocomplete="email" maxlength="254"></label><label data-name hidden>Username<input name="username" autocomplete="nickname" pattern="[A-Za-z0-9_]{3,24}" minlength="3" maxlength="24"><small>3–24 letters, numbers or underscores</small></label><label data-password>Password<input name="password" type="password" autocomplete="current-password" minlength="8" maxlength="256" required></label><button class="ft-submit" type="submit">Sign in</button></form><button class="ft-google" type="button">Continue with Google</button><button class="ft-switch" type="button">Create an account</button><button data-reset type="button" class="ft-switch">Forgot password?</button><p role="status" aria-live="polite"></p>`;
 document.body.append(dialog);dialog.querySelector('.ft-close').onclick=()=>dialog.close();dialog.addEventListener('close',()=>document.dispatchEvent(new Event('ftoers-account-close')));
 dialog.querySelector('.ft-switch').onclick=()=>openAccount(mode==='login'?'signup':'login');
 dialog.querySelector('[data-reset]').onclick=()=>openAccount('reset');
 dialog.querySelector('.ft-google').onclick=()=>busy(async()=>{const {error}=await client.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+location.pathname}});if(error)throw error;});
 dialog.querySelector('form').onsubmit=event=>{event.preventDefault();busy(async()=>{
  if(!client)throw Error('FTOers accounts are not configured yet.');
  const form=new FormData(event.target),password=form.get('password'),email=form.get('email')?.trim(),username=form.get('username')?.trim();
  if(mode==='username'){profile=await rpc('claim_username',{name:username});changes.dispatchEvent(new Event('change'));dialog.close();return;}
  if(mode==='new-password'){const {error}=await client.auth.updateUser({password});if(error)throw error;message('Password updated.');return;}
  if(mode==='reset'){const {error}=await client.auth.resetPasswordForEmail(email,{redirectTo:location.origin+'/'});if(error)throw error;message('If an account exists, a reset link has been sent.');return;}
  if(mode==='signup'){
   const {data,error}=await client.auth.signUp({email,password,options:{emailRedirectTo:location.origin+'/',data:{requested_username:username}}});if(error)throw error;
   if(data.session){await refresh(data.session);profile=await rpc('claim_username',{name:username});changes.dispatchEvent(new Event('change'));dialog.close();}
   else message('Check your email to confirm your account, then sign in and choose your username.');return;
  }
  const identity=form.get('identity').trim();
  if(identity.includes('@')){const {data,error}=await client.auth.signInWithPassword({email:identity,password});if(error)throw error;await refresh(data.session);}
  else{const response=await fetch(backendConfig.url+'/functions/v1/username-login',{method:'POST',headers:{'Content-Type':'application/json',apikey:backendConfig.key},body:JSON.stringify({username:identity,password})});const data=await response.json();if(!response.ok)throw Error(data.error||'Sign-in failed');const result=await client.auth.setSession(data);if(result.error)throw result.error;await refresh(result.data.session);}
  if(profile)dialog.close();
 });};
}
function message(text){dialog.querySelector('[role=status]').textContent=text;}
async function busy(fn){message('');const buttons=dialog.querySelectorAll('button');buttons.forEach(b=>b.disabled=true);try{await fn();}catch(error){message(error.message);}finally{buttons.forEach(b=>b.disabled=false);}}
export function openAccount(next='login'){
 if(profile&&next!=='new-password'){openSiteSettings();return;}
 ensureDialog();mode=session?(profile?(next==='new-password'?'new-password':'account'):'username'):next;
 const titles={login:'Sign in',signup:'Create account',username:'Choose your username',reset:'Reset password','new-password':'Set a new password'};
 dialog.querySelector('h2').textContent=titles[mode];
 dialog.querySelector('form').reset();
 if(mode==='username')dialog.querySelector('[name=username]').value=session?.user?.user_metadata?.requested_username??'';
 for(const [selector,visible] of Object.entries({'form':true,'[data-identity]':mode==='login','[data-email]':['signup','reset'].includes(mode),'[data-name]':['signup','username'].includes(mode),'[data-password]':['login','signup','new-password'].includes(mode),'.ft-google':['login','signup'].includes(mode),'.ft-switch':['login','signup'].includes(mode),'[data-reset]':mode==='login'}))dialog.querySelector(selector).hidden=!visible;
 for(const input of dialog.querySelectorAll('input')){input.disabled=input.closest('label').hidden;input.required=!input.disabled;}
 dialog.querySelector('[name=password]').autocomplete=mode==='signup'||mode==='new-password'?'new-password':'current-password';
 dialog.querySelector('.ft-submit').textContent={login:'Sign in',signup:'Create account',username:'Save username',reset:'Send reset link','new-password':'Save password'}[mode]??'Save';
 dialog.querySelector('.ft-switch').textContent=mode==='login'?'Create an account':'Already have an account? Sign in';
 message(configured?'':'FTOers accounts are not configured yet.');if(!dialog.open){dialog.showModal();document.dispatchEvent(new Event('ftoers-account-open'));}
}
let surfaceOptions={};
const personIcon='<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="3.4"/><path d="M5 21v-2a7 7 0 0 1 14 0v2"/></svg>';
function photoURL(){const value=session?.user?.user_metadata?.avatar_url??session?.user?.user_metadata?.picture;try{const url=new URL(value);return url.protocol==='https:'?url.href:null;}catch{return null;}}
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
  if(session&&options.showIdentity){const identity=document.createElement('div');identity.className='ft-menu-identity';const name=document.createElement('strong');name.textContent=profile?.username??session.user?.user_metadata?.full_name??'Signed in';identity.append(name);menu.append(identity);}if(!session)action('Sign in',()=>openAccount());
  if(options.onSettings)action('Settings',openSiteSettings,{id:'settings'});
  if(options.onAbout)action('About us',openSiteAbout,{id:'about'});
  if(profile?.admin&&options.onReview)action('Review solves',options.onReview,{id:'review-solves'});
  if(session)action('Log out',async()=>{const {error}=await client.auth.signOut();if(error){const message=document.createElement('p');message.className='ft-menu-error';message.setAttribute('role','alert');message.textContent='Couldn’t log out. Please try again.';menu.append(message);open();return;}await refresh(null);},{danger:true});
 };render();onAccountChange(render);ready.then(render);return button;
}
if(client){client.auth.onAuthStateChange(event=>{if(event==='PASSWORD_RECOVERY')setTimeout(()=>openAccount('new-password'),0);});}
