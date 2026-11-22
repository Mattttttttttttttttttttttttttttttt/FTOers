import {
  client,
  profile,
  session,
  rpc,
  onAccountChange,
  reloadAccount,
  openAccount,
  showAccountNotice,
  renderAccountAvatar,
} from "./account.js";
import { backendConfig } from "./config.js";
let dialog, mergeDialog, mergeState, accountId;
const wcaIcon = new URL("./wca.svg", import.meta.url).href;
const $ = (root, selector) => root.querySelector(selector);
function mountDialog(className, title, id) {
  const node = document.createElement("dialog");
  node.className = "ft-dialog " + className;
  node.setAttribute("aria-labelledby", id);
  node.innerHTML = `<header><h2 id="${id}"></h2><button type="button" class="ft-close" aria-label="Close"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg></button></header>`;
  $(node, "h2").textContent = title;
  $(node, ".ft-close").onclick = () => node.close();
  node.addEventListener("close", () =>
    document.dispatchEvent(new Event("ftoers-account-close")),
  );
  document.body.append(node);
  return node;
}
function show(node) {
  if (!node.open) {
    node.showModal();
    document.dispatchEvent(new Event("ftoers-account-open"));
  }
}
function notice(node, text) {
  $(node, ".ft-notice").textContent = text;
}
function logins() {
  return profile?.logins ?? session?.user?.identities ?? [];
}
function connected(provider) {
  return provider === "custom:wca"
    ? !!profile?.wca_connected
    : logins().some((identity) => identity.provider === provider);
}
function ensureProfile() {
  if (dialog) return;
  dialog = mountDialog("ft-profile", "Profile", "ft-profile-title");
  dialog.insertAdjacentHTML(
    "beforeend",
    `<section class="ft-profile-card"><span class="ft-avatar ft-profile-avatar" aria-hidden="true"></span><div class="ft-profile-identity"><div class="ft-profile-name-row"><h3 data-profile-name></h3><button type="button" data-edit-username aria-label="Change username" title="Change username"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m15 4 5 5M4 20l5-1L20 8a2.8 2.8 0 0 0-4-4L5 15l-1 5Z"/></svg></button></div><p data-profile-email></p></div></section><form data-username-form hidden><label for="ft-profile-username">Username</label><input id="ft-profile-username" name="username" autocomplete="nickname" pattern="[A-Za-z0-9_]{3,24}" minlength="3" maxlength="24" required aria-describedby="ft-profile-username-hint ft-profile-username-status"><small id="ft-profile-username-hint">3–24 letters, numbers or underscores. Must be unique.</small><div class="ft-profile-actions"><button type="submit" class="ft-primary-action">Save username</button><button type="button" data-cancel-username>Cancel</button></div><p id="ft-profile-username-status" class="ft-username-status" role="status" aria-live="polite"></p></form><section class="ft-profile-section"><h3>Sign-in methods</h3><ul class="ft-login-list"></ul><div class="ft-profile-actions"><button type="button" data-connect="google">Connect Google</button><button type="button" data-connect="custom:wca"><img src="${wcaIcon}" alt="">Connect WCA account</button></div></section><section class="ft-profile-section"><h3>WCA ID</h3><p data-verified-wca hidden></p><details data-wca-editor><summary data-wca-edit-label>Add WCA ID (optional)</summary><form data-wca-form><label>WCA ID <span class="ft-optional">(optional)</span><input name="wca_id" autocomplete="off" autocapitalize="characters" spellcheck="false" pattern="[0-9]{4}[A-Za-z]{4}[0-9]{2}" maxlength="10" placeholder="e.g. 2024ASHR02"></label><small>Self-reported until you connect your WCA account.</small><button type="submit">Save WCA ID</button></form></details></section><section class="ft-profile-section"><h3>Combine existing accounts</h3><p>Combine two existing FTOers profiles.</p><button type="button" data-merge>Merge accounts</button></section><footer class="ft-profile-footer"><button type="button" data-sign-out><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 4H5v16h5M9 12h12m-4-4 4 4-4 4"/></svg>Log out</button></footer><p class="ft-notice" role="status" aria-live="polite"></p>`,
  );
  $(dialog, "[data-edit-username]").onclick = () => {
    $(dialog, "[data-username-form]").hidden = false;
    $(dialog, "[name=username]").value = profile.username;
    $(dialog, ".ft-username-status").textContent = "";
    $(dialog, "[name=username]").focus();
    $(dialog, "[name=username]").select();
  };
  $(dialog, "[name=username]").oninput = () => {
    $(dialog, ".ft-username-status").textContent = "";
    $(dialog, "[name=username]").removeAttribute("aria-invalid");
  };
  $(dialog, "[data-cancel-username]").onclick = () => {
    $(dialog, "[data-username-form]").hidden = true;
    $(dialog, "[data-edit-username]").focus();
  };
  $(dialog, "[data-username-form]").onsubmit = (event) => {
    event.preventDefault();
    profileBusy(async () => {
      const status = $(dialog, ".ft-username-status");
      status.textContent = "";
      try {
        await rpc("rename_username", {
          name: $(dialog, "[name=username]").value.trim(),
        });
      } catch (error) {
        status.textContent = /could not find the function|does not exist/i.test(
          error.message,
        )
          ? "Username changes are not enabled yet. Your username is unchanged."
          : error.message;
        $(dialog, "[name=username]").focus();
        return;
      }
      await reloadAccount();
      renderProfile();
      $(dialog, "[data-username-form]").hidden = true;
      $(dialog, "[data-edit-username]").focus();
      notice(dialog, "Username updated.");
    });
  };
  $(dialog, "[data-sign-out]").onclick = () =>
    profileBusy(async () => {
      const { error } = await client.auth.signOut();
      if (error) throw Error("Couldn’t log out. Please try again.");
      await reloadAccount();
      dialog.close();
    });
  for (const button of dialog.querySelectorAll("[data-connect]"))
    button.onclick = () =>
      profileBusy(async () => {
        const { error } = await client.auth.linkIdentity({
          provider: button.dataset.connect,
          options: { redirectTo: location.origin + location.pathname },
        });
        if (error)
          throw Error(
            "Could not connect this sign-in method. If it belongs to another profile, use Merge accounts.",
          );
      });
  $(dialog, "[name=wca_id]").oninput = (event) => {
    event.target.value = event.target.value.toUpperCase();
  };
  $(dialog, "[data-wca-form]").onsubmit = (event) => {
    event.preventDefault();
    profileBusy(async () => {
      await rpc("set_wca_id", {
        wca_id: $(dialog, "[name=wca_id]").value.trim().toUpperCase() || null,
      });
      await reloadAccount();
      renderProfile();
      notice(dialog, "WCA ID saved.");
    });
  };
  $(dialog, "[data-merge]").onclick = () =>
    profileBusy(async () => {
      try {
        await rpc("merge_features");
      } catch {
        throw Error(
          "Account merging is not enabled yet. Please try again after the site update.",
        );
      }
      openMerge();
    });
  onAccountChange(() => {
    if (session?.user?.id !== accountId && mergeDialog?.open)
      mergeDialog.close();
    if (dialog.open) {
      if (!profile) dialog.close();
      else renderProfile();
    }
  });
}
function renderProfile() {
  if (!profile) return;
  renderAccountAvatar($(dialog, ".ft-profile-avatar"));
  $(dialog, "[data-profile-name]").textContent = profile.username;
  $(dialog, "[data-profile-email]").textContent = session?.user?.email ?? "";
  const list = $(dialog, ".ft-login-list");
  list.replaceChildren();
  for (const identity of logins()) {
    const item = document.createElement("li");
    item.textContent =
      ({ google: "Google", "custom:wca": "WCA", email: "Email and password" }[
        identity.provider
      ] ?? identity.provider) + (identity.email ? " · " + identity.email : "");
    list.append(item);
  }
  if (!list.children.length) {
    const item = document.createElement("li");
    item.textContent = "Signed in";
    list.append(item);
  }
  for (const button of dialog.querySelectorAll("[data-connect]"))
    button.hidden = connected(button.dataset.connect);
  $(dialog, "[data-wca-form]").hidden = !!profile.wca_connected;
  $(dialog, "[data-verified-wca]").hidden =
    !profile.wca_connected && !profile.wca_id;
  $(dialog, "[data-wca-editor]").hidden = !!profile.wca_connected;
  $(dialog, "[data-wca-edit-label]").textContent = profile.wca_id
    ? "Edit WCA ID"
    : "Add WCA ID (optional)";
  $(dialog, "[data-verified-wca]").textContent = profile.wca_id
    ? profile.wca_id +
      (profile.wca_connected ? " · Verified through WCA" : " · Self-reported")
    : (profile.wca_name ?? "WCA account") + " · No WCA ID assigned yet";
  $(dialog, "[name=wca_id]").value = profile.wca_id ?? "";
}
async function profileBusy(fn) {
  notice(dialog, "");
  for (const button of dialog.querySelectorAll("button:not(.ft-close)"))
    button.disabled = true;
  try {
    await fn();
  } catch (error) {
    notice(dialog, error.message);
  } finally {
    for (const button of dialog.querySelectorAll("button"))
      button.disabled = false;
  }
}
export async function openProfile() {
  if (!session || !profile) {
    openAccount();
    return;
  }
  ensureProfile();
  accountId = session.user.id;
  renderProfile();
  $(dialog, "[data-username-form]").hidden = true;
  notice(dialog, "");
  show(dialog);
  try {
    await reloadAccount();
    renderProfile();
  } catch {
    notice(dialog, "Could not refresh your profile. Try again.");
  }
}
function proofButtons(slot) {
  return `<fieldset data-proof="${slot}" data-proof-state="idle"><legend>${slot === "primary" ? "1. Your current account" : "2. The other account"}</legend><div class="ft-proof-result" hidden><span class="ft-proof-check" aria-hidden="true">✓</span><div class="ft-proof-identity"><strong data-proof-title></strong><small data-proof-account></small></div><button type="button" data-change-proof>Change</button></div><p data-proof-status role="status">Choose a sign-in method.</p><div class="ft-proof-methods"><button type="button" data-provider="google">Google</button><button type="button" data-provider="custom:wca"><img src="${wcaIcon}" alt="">WCA</button><button type="button" data-provider="password">Email / password</button></div></fieldset>`;
}
function hasProofs(state = mergeState) {
  return !!(state?.primary?.token && state?.secondary?.token);
}
function renderProof(slot) {
  const field = $(mergeDialog, `[data-proof=${slot}]`),
    proof = mergeState?.[slot],
    stage = proof?.stage ?? "idle";
  field.dataset.proofState = stage;
  $(field, ".ft-proof-result").hidden = stage === "idle";
  $(field, ".ft-proof-methods").hidden = stage !== "idle";
  $(field, "[data-change-proof]").textContent =
    stage === "signing-in"
      ? "Cancel"
      : stage === "needs-sign-in"
        ? "Sign in again"
        : "Change";
  $(field, ".ft-proof-check").textContent = ["signing-in", "checking"].includes(
    stage,
  )
    ? "…"
    : stage === "needs-sign-in"
      ? "!"
      : "✓";
  const provider =
    { google: "Google", "custom:wca": "WCA", password: "email / password" }[
      proof?.provider
    ] ?? "your account";
  $(field, "[data-proof-title]").textContent =
    {
      "signing-in": "Signing in…",
      "signed-in": "Signed in with " + provider,
      checking: "Checking account…",
      verified: "Account verified",
      "needs-sign-in": "Sign in again",
    }[stage] ?? "";
  $(field, "[data-proof-account]").textContent =
    proof?.verifiedName ?? proof?.label ?? "";
  $(field, "[data-proof-status]").textContent = {
    idle: "Choose a sign-in method.",
    "signing-in": "Complete sign-in in the verification window.",
    "signed-in": hasProofs()
      ? "Sign-in succeeded. The merge check is not complete."
      : "Sign-in succeeded. Waiting for the other account.",
    checking: "Waiting for the merge service to check both accounts.",
    verified:
      "Ownership and account selection were checked by the merge service.",
    "needs-sign-in":
      "This sign-in expired or could not be verified. Please sign in again.",
  }[stage];
}
function changeProof(slot) {
  const state = mergeState;
  if (!state || state.busy) return;
  for (const flow of state.flows.filter((flow) => flow.slot === slot)) {
    flow.channel.close();
    try {
      flow.popup?.close();
    } catch {}
  }
  state.flows = state.flows.filter((flow) => flow.slot !== slot);
  state[slot] = null;
  state.generation = (state.generation ?? 0) + 1;
  state.preview = null;
  $(mergeDialog, "[data-preview]").hidden = true;
  $(mergeDialog, "[data-proof-area]").hidden = false;
  $(mergeDialog, "[data-retry-check]").hidden = true;
  $(mergeDialog, "[data-confirm-merge]").checked = false;
  for (const step of ["primary", "secondary"]) {
    if (state[step]?.token) {
      state[step].stage = "signed-in";
      delete state[step].verifiedName;
    }
    renderProof(step);
  }
  notice(mergeDialog, "");
  $(mergeDialog, `[data-proof=${slot}] [data-provider]`).focus();
}
function ensureMerge() {
  if (mergeDialog) return;
  mergeDialog = mountDialog("ft-merge", "Merge accounts", "ft-merge-title");
  mergeDialog.insertAdjacentHTML(
    "beforeend",
    `<p class="ft-description">Verify both sign-ins in separate windows. Your current session stays signed in until you confirm the merge.</p><div data-proof-area>${proofButtons("primary")}${proofButtons("secondary")}</div><section data-preview hidden><button type="button" data-change-proofs>Verify different accounts</button><h3>Choose the username to keep</h3><div class="ft-merge-choices"></div><ul class="ft-merge-rules"><li>Both sign-ins will open the chosen profile.</li><li>Approved results, review history and temporary links stay intact. Existing recordings and link expiry are preserved.</li><li>The latest pending submission per category is kept. Other pending submissions are archived; investigation holds stay in place.</li><li>Daily sharing usage is combined. A new online average sequence starts after merging.</li><li>Albums saved on your devices stay on those devices. They are not uploaded by merging.</li><li>You will need to sign in again on your devices.</li></ul><label class="ft-merge-confirm"><input type="checkbox" data-confirm-merge>I reviewed both accounts and want to combine them.</label><div class="ft-profile-actions"><button type="button" data-refresh-preview>Refresh preview</button><button type="button" class="ft-primary-action" data-complete disabled>Merge accounts</button></div></section><p class="ft-notice" role="status" aria-live="polite"></p><button type="button" data-retry-check hidden>Retry account check</button><button type="button" data-check-profile hidden>Sign in again to check your profile</button>`,
  );
  for (const field of mergeDialog.querySelectorAll("[data-proof]"))
    for (const button of field.querySelectorAll("[data-provider]"))
      button.onclick = () =>
        startProof(field.dataset.proof, button.dataset.provider);
  for (const field of mergeDialog.querySelectorAll("[data-proof]"))
    $(field, "[data-change-proof]").onclick = () =>
      changeProof(field.dataset.proof);
  $(mergeDialog, "[data-retry-check]").onclick = previewMerge;
  $(mergeDialog, "[data-check-profile]").onclick = async () => {
    mergeDialog.close();
    await client.auth.signOut({ scope: "local" });
    await reloadAccount();
    openAccount("login");
    showAccountNotice("Sign in again to check whether the merge finished.");
  };
  $(mergeDialog, "[data-confirm-merge]").onchange = () => {
    $(mergeDialog, "[data-complete]").disabled = !$(
      mergeDialog,
      "[data-confirm-merge]",
    ).checked;
  };
  $(mergeDialog, "[data-refresh-preview]").onclick = previewMerge;
  $(mergeDialog, "[data-change-proofs]").onclick = () => {
    if (!mergeState || mergeState.busy) return;
    mergeState.preview = null;
    $(mergeDialog, "[data-preview]").hidden = true;
    $(mergeDialog, "[data-proof-area]").hidden = false;
    notice(
      mergeDialog,
      "Verify either account again to change your selection.",
    );
  };
  $(mergeDialog, "[data-complete]").onclick = completeMerge;
  mergeDialog.addEventListener("cancel", (event) => {
    if (mergeState?.confirming) event.preventDefault();
  });
  mergeDialog.addEventListener("close", () => {
    if (mergeState) {
      for (const flow of mergeState.flows) {
        flow.channel.close();
        try {
          flow.popup?.close();
        } catch {}
      }
      mergeState = null;
    }
  });
}
function openMerge() {
  ensureMerge();
  dialog.close();
  mergeState = {
    primary: null,
    secondary: null,
    preview: null,
    flows: [],
    keep: "primary",
  };
  $(mergeDialog, "[data-proof-area]").hidden = false;
  $(mergeDialog, "[data-preview]").hidden = true;
  for (const slot of ["primary", "secondary"]) renderProof(slot);
  $(mergeDialog, "[data-retry-check]").hidden = true;
  $(mergeDialog, "[data-check-profile]").hidden = true;
  for (const button of mergeDialog.querySelectorAll("button"))
    button.disabled = false;
  notice(mergeDialog, "");
  show(mergeDialog);
}
function startProof(slot, provider) {
  if (!mergeState || mergeState.busy) return;
  const state = mergeState;
  const nonce = Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const channel = new BroadcastChannel("ftoers.merge." + nonce),
    url = new URL("./merge-callback.html", import.meta.url);
  url.search = new URLSearchParams({
    start: "1",
    nonce,
    provider,
    surface: document.documentElement.dataset.ftSurface ?? "home",
  });
  const popup = window.open(
    url.href,
    "ftoers-verify-" + nonce,
    "popup,width=490,height=720",
  );
  if (!popup) {
    channel.close();
    notice(
      mergeDialog,
      "Allow popups for FTOers, then verify the account again.",
    );
    return;
  }
  for (const old of state.flows.filter((flow) => flow.slot === slot)) {
    old.channel.close();
    try {
      old.popup?.close();
    } catch {}
  }
  state.flows = state.flows.filter((flow) => flow.slot !== slot);
  state.flows.push({ channel, popup, slot });
  state[slot] = { token: null, provider, stage: "signing-in" };
  state.preview = null;
  state.generation = (state.generation ?? 0) + 1;
  $(mergeDialog, "[data-preview]").hidden = true;
  $(mergeDialog, "[data-retry-check]").hidden = true;
  renderProof(slot);
  notice(mergeDialog, "");
  channel.onmessage = (event) => {
    if (
      mergeState !== state ||
      !state.flows.some((flow) => flow.channel === channel) ||
      event.data?.type !== "proof" ||
      typeof event.data.access_token !== "string" ||
      event.data.access_token.length > 8192
    )
      return;
    state[slot] = {
      token: event.data.access_token,
      provider,
      stage: "signed-in",
      label:
        typeof event.data.account_label === "string"
          ? event.data.account_label.slice(0, 160)
          : "",
    };
    state.generation = (state.generation ?? 0) + 1;
    state.preview = null;
    $(mergeDialog, "[data-preview]").hidden = true;
    channel.postMessage({ type: "ack" });
    setTimeout(() => channel.close(), 500);
    for (const step of ["primary", "secondary"]) renderProof(step);
    if (hasProofs(state)) previewMerge();
  };
}
async function mergeRequest(action, extra = {}) {
  const state = mergeState;
  if (!hasProofs(state))
    throw Error("Sign in to both accounts before checking the merge.");
  const proofs = {
    primary_token: state.primary.token,
    secondary_token: state.secondary.token,
  };
  const { data, error } = await client.auth.getSession();
  if (error || !data.session)
    throw Error("Sign in again before merging accounts.");
  let response;
  try {
    response = await fetch(backendConfig.url + "/functions/v1/merge-accounts", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: backendConfig.key,
        Authorization: "Bearer " + data.session.access_token,
      },
      body: JSON.stringify({ action, ...proofs, ...extra }),
      signal: AbortSignal.timeout(20000),
    });
  } catch {
    const error = Error(
      action === "confirm"
        ? "The connection was lost. The merge may have finished. Sign in again to check your profile before trying another merge."
        : "Could not reach the merge service. Your sign-ins succeeded, but the account check is incomplete. No accounts were merged. Retry the account check.",
    );
    error.network = true;
    throw error;
  }
  let result;
  try {
    result = await response.json();
  } catch {
    const error = Error(
      action === "confirm"
        ? "The service response could not be read. Sign in again to check whether the merge finished."
        : "The merge service returned an unreadable response. No accounts were merged. Retry the account check.",
    );
    error.network = true;
    throw error;
  }
  if (!response.ok) {
    const error = Error(
      result.error ?? "Account merging is unavailable. Try again later.",
    );
    error.status = response.status;
    throw error;
  }
  return result;
}
function setMergeBusy(value) {
  if (!mergeState) return;
  mergeState.busy = value;
  for (const button of mergeDialog.querySelectorAll("button"))
    button.disabled = value;
  $(mergeDialog, "[data-complete]").disabled =
    value ||
    !!mergeState.confirmUnknown ||
    !$(mergeDialog, "[data-confirm-merge]").checked;
  for (const input of mergeDialog.querySelectorAll("input"))
    input.disabled = value || !!mergeState.confirmUnknown;
  if (mergeState.confirmUnknown)
    for (const button of mergeDialog.querySelectorAll(
      "button:not(.ft-close):not([data-check-profile])",
    ))
      button.disabled = true;
}
async function previewMerge() {
  const state = mergeState;
  if (!hasProofs(state) || state.busy) return;
  const generation = state.generation;
  setMergeBusy(true);
  $(mergeDialog, "[data-retry-check]").hidden = true;
  for (const slot of ["primary", "secondary"]) {
    state[slot].stage = "checking";
    renderProof(slot);
  }
  notice(mergeDialog, "Checking both accounts…");
  try {
    const preview = await mergeRequest("preview");
    if (mergeState !== state || state.generation !== generation) return;
    state.preview = preview;
    for (const slot of ["primary", "secondary"]) {
      state[slot].stage = "verified";
      state[slot].verifiedName = preview[slot].username;
      renderProof(slot);
    }
    state.keep = "primary";
    const choices = $(mergeDialog, ".ft-merge-choices");
    choices.replaceChildren();
    for (const slot of ["primary", "secondary"]) {
      const account = preview[slot],
        label = document.createElement("label"),
        radio = document.createElement("input"),
        details = document.createElement("span"),
        name = document.createElement("strong"),
        counts = document.createElement("small");
      radio.type = "radio";
      radio.name = "keep-profile";
      radio.value = slot;
      radio.checked = slot === "primary";
      radio.disabled = !account.username;
      radio.onchange = () => {
        state.keep = slot;
      };
      name.textContent = account.username ?? "No username chosen";
      counts.textContent = `${account.approved} approved · ${account.pending} pending · ${account.held} on hold · ${account.links} shared links`;
      details.append(name, counts);
      if (account.wca_id) {
        const id = document.createElement("small");
        id.textContent =
          account.wca_id +
          (account.wca_verified ? " · WCA verified" : " · Self-reported");
        details.append(id);
      }
      label.append(radio, details);
      choices.append(label);
    }
    $(mergeDialog, "[data-preview]").hidden = false;
    $(mergeDialog, "[data-proof-area]").hidden = true;
    $(mergeDialog, "[data-confirm-merge]").checked = false;
    notice(
      mergeDialog,
      "Preview expires in 5 minutes. Review it before confirming.",
    );
  } catch (error) {
    if (mergeState === state) {
      state.preview = null;
      $(mergeDialog, "[data-preview]").hidden = true;
      $(mergeDialog, "[data-proof-area]").hidden = false;
      for (const slot of ["primary", "secondary"]) {
        if (state[slot]) {
          state[slot].stage =
            error.status === 401 ? "needs-sign-in" : "signed-in";
          delete state[slot].verifiedName;
          if (error.status === 401) state[slot].token = null;
          renderProof(slot);
        }
      }
      $(mergeDialog, "[data-retry-check]").hidden = !hasProofs(state);
      notice(mergeDialog, error.message);
    }
  } finally {
    if (mergeState === state) {
      setMergeBusy(false);
      const disabled = (choices) => {
        for (const radio of choices.querySelectorAll("input"))
          radio.disabled = !state.preview?.[radio.value]?.username;
      };
      disabled($(mergeDialog, ".ft-merge-choices"));
      if (state.generation !== generation) previewMerge();
    }
  }
}
async function completeMerge() {
  const state = mergeState;
  if (
    !state?.preview ||
    state.busy ||
    !$(mergeDialog, "[data-confirm-merge]").checked
  )
    return;
  state.confirming = true;
  setMergeBusy(true);
  notice(mergeDialog, "Combining accounts…");
  try {
    const result = await mergeRequest("confirm", {
      ticket: state.preview.ticket,
      keep: state.keep,
    });
    mergeDialog.close();
    await client.auth.signOut({ scope: "local" });
    await reloadAccount();
    openAccount("login");
    showAccountNotice(
      "Accounts merged. Sign in with either account to continue as " +
        result.username +
        ".",
    );
  } catch (error) {
    if (mergeState === state) {
      if (error.network) {
        state.confirmUnknown = true;
        $(mergeDialog, "[data-check-profile]").hidden = false;
      }
      notice(mergeDialog, error.message);
    }
  } finally {
    if (mergeState === state) {
      state.confirming = false;
      setMergeBusy(false);
    }
  }
}
