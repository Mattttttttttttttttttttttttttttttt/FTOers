import { createClient } from "./supabase.js";
import { backendConfig } from "./config.js";
const dialog = document.querySelector("dialog"),
  notice = dialog.querySelector("[role=status]"),
  params = new URLSearchParams(location.search);
dialog.showModal();
dialog.querySelector(".ft-close").onclick = () => window.close();
let flow;
try {
  if (params.has("start")) {
    const nonce = params.get("nonce"),
      provider = params.get("provider"),
      surface = params.get("surface");
    if (
      !/^[a-f0-9]{64}$/.test(nonce) ||
      !["google", "custom:wca", "password"].includes(provider)
    )
      throw Error("Invalid verification request.");
    flow = { nonce, provider, surface, created: Date.now() };
    sessionStorage.setItem("ftoers.merge-flow", JSON.stringify(flow));
  } else
    flow = JSON.parse(sessionStorage.getItem("ftoers.merge-flow") ?? "null");
  if (!flow || Date.now() - flow.created > 10 * 60 * 1000)
    throw Error("Verification expired. Close this window and start again.");
  if (flow.surface === "simulator")
    document.documentElement.dataset.ftSurface = "simulator";
  const client = createClient(backendConfig.url, backendConfig.key, {
    auth: {
      storage: sessionStorage,
      storageKey: "ftoers.merge." + flow.nonce,
      flowType: "pkce",
      detectSessionInUrl: true,
      persistSession: true,
      autoRefreshToken: false,
    },
  });
  function accountLabel(user) {
    if (user.email) return user.email;
    const identity = user.identities?.find(
      (identity) => identity.provider === "custom:wca",
    );
    const wcaId = identity?.identity_data?.custom_claims?.wca_id;
    if (typeof wcaId === "string" && /^[0-9]{4}[A-Z]{4}[0-9]{2}$/.test(wcaId))
      return wcaId;
    const name = user.user_metadata?.full_name ?? user.user_metadata?.name;
    return typeof name === "string" ? name.slice(0, 120) : "WCA account";
  }
  async function finish(session) {
    if (!session) return;
    const { data, error } = await client.auth.getUser(session.access_token);
    if (error || !data.user)
      throw Error("Could not verify this account. Sign in again.");
    const channel = new BroadcastChannel("ftoers.merge." + flow.nonce);
    notice.textContent = "Signed in. Returning to the merge window…";
    channel.onmessage = (event) => {
      if (event.data?.type !== "ack") return;
      for (const key of Object.keys(sessionStorage))
        if (key === "ftoers.merge-flow" || key.startsWith("ftoers.merge."))
          sessionStorage.removeItem(key);
      channel.close();
      window.close();
    };
    channel.postMessage({
      type: "proof",
      access_token: session.access_token,
      user_id: data.user.id,
      account_label: accountLabel(data.user),
    });
  }
  if (params.has("start")) {
    if (flow.provider === "password") {
      const form = dialog.querySelector("form");
      form.hidden = false;
      notice.textContent = "";
      const eye = form.querySelector(".ft-password-toggle"),
        password = form.elements.password;
      eye.onclick = () => {
        password.type = password.type === "password" ? "text" : "password";
        eye.setAttribute(
          "aria-label",
          password.type === "password" ? "Show password" : "Hide password",
        );
      };
      form.onsubmit = async (event) => {
        event.preventDefault();
        const button = form.querySelector("[type=submit]");
        button.disabled = true;
        notice.textContent = "Verifying…";
        try {
          const { data, error } = await client.auth.signInWithPassword({
            email: form.elements.email.value.trim(),
            password: password.value,
          });
          if (error)
            throw Error("Unable to sign in. Check your email and password.");
          await finish(data.session);
        } catch (error) {
          notice.textContent = error.message;
        } finally {
          button.disabled = false;
        }
      };
    } else {
      const { error } = await client.auth.signInWithOAuth({
        provider: flow.provider,
        options: {
          redirectTo: location.origin + location.pathname,
          ...(flow.provider === "google"
            ? { queryParams: { prompt: "select_account" } }
            : {}),
        },
      });
      if (error) throw error;
    }
  } else {
    const { data, error } = await client.auth.getSession();
    if (error)
      throw Error(
        "Verification was not completed. Close this window and try again.",
      );
    await finish(data.session);
    if (!data.session)
      throw Error(
        "Verification was not completed. Close this window and try again.",
      );
  }
} catch (error) {
  notice.textContent =
    error.message ?? "Verification failed. Close this window and try again.";
}
