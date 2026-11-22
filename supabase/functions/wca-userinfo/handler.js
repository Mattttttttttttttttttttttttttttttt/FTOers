// WCA wraps its OAuth userinfo in {me: ...}. Supabase's generic OAuth provider
// needs flat standard claims. No OAuth client secret or WCA token is retained.
export async function wcaUserinfo(request, fetchWca = fetch) {
  const headers = {'Content-Type':'application/json','Cache-Control':'no-store'};
  const fail=(status,message)=>new Response(JSON.stringify({error:message}),{status,headers});
  if (request.method!=='GET') return fail(405,'Use GET');
  const authorization=request.headers.get('authorization')??'';
  if (!/^Bearer [^\s]{1,8192}$/i.test(authorization)) return fail(401,'WCA authorization required');
  try {
    const response=await fetchWca('https://www.worldcubeassociation.org/api/v0/me',{
      headers:{Authorization:authorization,Accept:'application/json'},signal:AbortSignal.timeout(8000),redirect:'error',
    });
    if (!response.ok) return fail([401,403].includes(response.status)?401:502,'WCA could not verify this account');
    const text=await response.text();
    if(text.length>131072) return fail(502,'Invalid WCA identity response');
    const {me}=JSON.parse(text);
    if(!Number.isSafeInteger(me?.id)||me.id<=0||typeof me.name!=='string'||me.name.length>250) return fail(502,'Invalid WCA identity response');
    const id=typeof me.wca_id==='string'&&/^[0-9]{4}[A-Z]{4}[0-9]{2}$/.test(me.wca_id)?me.wca_id:null;
    let picture;
    try {const url=new URL(me.avatar?.thumb_url??me.avatar?.url);if(url.protocol==='https:') picture=url.href;}catch{}
    return new Response(JSON.stringify({sub:String(me.id),name:me.name,...(picture?{picture}:{}),wca_id:id,wca_user_id:String(me.id)}),{headers});
  } catch { return fail(502,'WCA identity service is unavailable. Please try again.'); }
}
