// Never return the email associated with a username. Supabase Auth still enforces
// password checks; a per-IP database limiter also covers username resolution.
import {createClient} from 'npm:@supabase/supabase-js@2';
const allowed = new Set(['https://ftoers.web.app','https://ftoers.firebaseapp.com','http://127.0.0.1:5173','http://127.0.0.1:8080']);
Deno.serve(async req => {
 const origin=req.headers.get('origin')??'';
 const headers={'Access-Control-Allow-Origin':allowed.has(origin)?origin:'https://ftoers.web.app','Access-Control-Allow-Headers':'apikey,content-type,authorization','Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};
 if(req.method==='OPTIONS')return new Response(null,{headers});
 const fail=(status=400)=>new Response(JSON.stringify({error:'Unable to sign in. Check your credentials or try again later.'}),{status,headers});
 if(req.method!=='POST'||!allowed.has(origin))return fail();
 try {
  if(Number(req.headers.get('content-length')??0)>4096)return fail();
  const {username,password}=await req.json();
  if(typeof username!=='string'||!/^\w{3,24}$/.test(username)||typeof password!=='string'||password.length>256)return fail();
  const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const ip=req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()??'unknown';
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(ip));
  const key=Array.from(new Uint8Array(digest),n=>n.toString(16).padStart(2,'0')).join('');
  const {data:permitted,error:limitError}=await admin.rpc('allow_username_login',{ip_hash:key});
  if(limitError||!permitted)return fail(429);
  const {data:profile}=await admin.from('profiles').select('id').ilike('username',username.replaceAll('_','\\_')).maybeSingle();
  const user=profile?await admin.auth.admin.getUserById(profile.id):null;
  const email=user?.data.user?.email??'invalid-login@invalid.example';
  const client=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data,error}=await client.auth.signInWithPassword({email,password});
  if(error||!profile||!data.session)return fail(401);
  return new Response(JSON.stringify({access_token:data.session.access_token,refresh_token:data.session.refresh_token}),{headers});
 }catch{return fail();}
});
