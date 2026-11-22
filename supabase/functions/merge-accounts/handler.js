const origins = new Set([
  "https://ftoers.web.app",
  "https://ftoers.firebaseapp.com",
  "http://127.0.0.1:5173",
  "http://localhost:5173",
  "http://127.0.0.1:8080",
  "http://localhost:8080",
]);
function recentAuthentication(token, now) {
  try {
    const part = token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/");
    const claims = JSON.parse(atob(part));
    return (
      Array.isArray(claims.amr) &&
      claims.amr.some(
        (entry) =>
          Number.isFinite(entry.timestamp) &&
          entry.timestamp <= now + 30 &&
          entry.timestamp >= now - 600,
      )
    );
  } catch {
    return false;
  }
}
// Token payloads are inspected only AFTER Auth has verified each token through
// getUser(). Never accept browser-submitted UUIDs, emails or WCA IDs as proof.
export async function mergeAccounts(
  request,
  admin,
  { now = () => Date.now() } = {},
) {
  const origin = request.headers.get("origin") ?? "";
  const headers = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    Vary: "Origin",
    ...(origins.has(origin) ? { "Access-Control-Allow-Origin": origin } : {}),
    "Access-Control-Allow-Headers": "authorization,apikey,content-type",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
  };
  const reply = (status, data) =>
    new Response(JSON.stringify(data), { status, headers });
  if (!origins.has(origin))
    return reply(403, { error: "Open account merging from FTOers." });
  if (request.method === "OPTIONS")
    return new Response(null, { status: 204, headers });
  if (request.method !== "POST") return reply(405, { error: "Use POST." });
  try {
    if (Number(request.headers.get("content-length") ?? 0) > 28000)
      return reply(413, { error: "Merge request is too large." });
    const reader = request.body?.getReader();
    if (!reader)
      return reply(400, { error: "Verify both accounts before merging." });
    const decoder = new TextDecoder();
    let text = "",
      bytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 28000) {
        await reader.cancel();
        return reply(413, { error: "Merge request is too large." });
      }
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    const input = JSON.parse(text),
      current = request.headers
        .get("authorization")
        ?.match(/^Bearer (\S{1,8192})$/i)?.[1];
    if (
      !current ||
      !["preview", "confirm"].includes(input.action) ||
      ![input.primary_token, input.secondary_token].every(
        (value) => typeof value === "string" && value.length <= 8192,
      )
    )
      return reply(400, { error: "Verify both accounts before merging." });
    const tokens = [current, input.primary_token, input.secondary_token];
    const verified = await Promise.all(
      tokens.map((token) => admin.auth.getUser(token)),
    );
    if (verified.some((result) => result.error || !result.data?.user?.id))
      return reply(401, {
        error:
          "Account verification expired. Sign in and verify both accounts again.",
      });
    if (
      !tokens
        .slice(1)
        .every((token) => recentAuthentication(token, now() / 1000))
    )
      return reply(401, {
        error: "Please sign in to both accounts again to verify ownership.",
      });
    const [actor, primary, secondary] = verified.map(
      (result) => result.data.user.id,
    );
    const args = {
      actor,
      primary_identity: primary,
      secondary_identity: secondary,
    };
    if (input.action === "confirm") {
      if (
        !/^[0-9a-f-]{36}$/i.test(input.ticket ?? "") ||
        !["primary", "secondary"].includes(input.keep)
      )
        return reply(400, {
          error: "Review the merge preview and choose a profile to keep.",
        });
      Object.assign(args, { ticket: input.ticket, keep: input.keep });
    }
    const { data, error } = await admin.rpc(
      input.action === "preview"
        ? "prepare_account_merge"
        : "complete_account_merge",
      args,
    );
    if (error) {
      const safe = [
        "Verify the account",
        "These sign-ins",
        "These profiles",
        "Account unavailable",
        "different WCA",
        "Too many merge",
        "Merge verification",
        "Merge preview expired",
        "Choose the",
        "Account membership changed",
        "Account data changed",
        "Different WCA",
      ];
      const message = safe.some((prefix) => error.message?.startsWith(prefix))
        ? error.message
        : "Account merging is unavailable. Please try again later.";
      return reply(409, { error: message });
    }
    // The database blocks old session IDs atomically. Revocation is an additional
    // cleanup, not the authorization mechanism; failed cleanup cannot reopen them.
    if (input.action === "confirm")
      await Promise.allSettled(
        [input.primary_token, input.secondary_token, current].map((token) =>
          admin.auth.admin.signOut(token, "global"),
        ),
      );
    return reply(200, data);
  } catch {
    return reply(400, {
      error: "Could not verify this merge request. Please try again.",
    });
  }
}
