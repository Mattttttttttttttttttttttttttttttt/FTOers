import { test } from "node:test";
import assert from "node:assert/strict";
import { mergeAccounts } from "../supabase/functions/merge-accounts/handler.js";
const now = 1800000000000;
const token = (id, age = 0) =>
  "header." +
  Buffer.from(
    JSON.stringify({
      sub: id,
      amr: [{ method: "oauth", timestamp: now / 1000 - age }],
    }),
  ).toString("base64url") +
  ".signature";
const first = token("first"),
  second = token("second");
function request(body, origin = "https://ftoers.web.app") {
  return new Request("https://backend.test/merge-accounts", {
    method: "POST",
    headers: {
      origin,
      Authorization: "Bearer current",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      action: "preview",
      primary_token: first,
      secondary_token: second,
      ...body,
    }),
  });
}
function backend({ expired = false, rpcError = null } = {}) {
  const calls = [],
    revoked = [];
  return {
    calls,
    revoked,
    auth: {
      getUser: async (value) =>
        expired
          ? { error: { message: "Expired" } }
          : {
              data: {
                user: {
                  id:
                    value === "current"
                      ? "actor"
                      : value === first
                        ? "first"
                        : "second",
                },
              },
            },
      admin: {
        signOut: async (value, scope) => {
          revoked.push({ value, scope });
        },
      },
    },
    rpc: async (name, args) => {
      calls.push({ name, args });
      return rpcError
        ? { error: { message: rpcError } }
        : {
            data: {
              ticket: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              username: "Solver",
            },
          };
    },
  };
}
test("preview verifies both proofs plus the current session, and derives UUIDs on the server", async () => {
  const admin = backend();
  const response = await mergeAccounts(
    request({ primary_identity: "attacker", actor: "attacker" }),
    admin,
    { now: () => now },
  );
  assert.equal(response.status, 200);
  assert.deepEqual(admin.calls, [
    {
      name: "prepare_account_merge",
      args: {
        actor: "actor",
        primary_identity: "first",
        secondary_identity: "second",
      },
    },
  ]);
  assert.equal(admin.revoked.length, 0);
});
test("old authentication and expired/unverified proofs cannot reach the database", async () => {
  for (const [body, options] of [
    [{ primary_token: token("first", 601) }, {}],
    [{}, { expired: true }],
    [{ primary_token: "not-a-jwt" }, {}],
  ]) {
    const admin = backend(options);
    const response = await mergeAccounts(request(body), admin, {
      now: () => now,
    });
    assert.equal(response.status, 401);
    assert.equal(admin.calls.length, 0);
  }
});
test("hostile origins, oversize requests and malformed confirmation are rejected", async () => {
  const admin = backend();
  assert.equal(
    (await mergeAccounts(request({}, "https://attacker.test"), admin)).status,
    403,
  );
  assert.equal(
    (
      await mergeAccounts(
        request({ secondary_token: "x".repeat(30000) }),
        admin,
      )
    ).status,
    413,
  );
  assert.equal(
    (
      await mergeAccounts(
        request({ action: "confirm", ticket: "bad", keep: "primary" }),
        admin,
        { now: () => now },
      )
    ).status,
    400,
  );
  assert.equal(admin.calls.length, 0);
});
test("confirmation binds ticket/choice/proofs and revokes sessions only after success", async () => {
  const admin = backend();
  const response = await mergeAccounts(
    request({
      action: "confirm",
      ticket: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      keep: "secondary",
    }),
    admin,
    { now: () => now },
  );
  assert.equal(response.status, 200);
  assert.equal(admin.calls[0].name, "complete_account_merge");
  assert.equal(admin.calls[0].args.keep, "secondary");
  assert.equal(admin.revoked.length, 3);
  assert.ok(admin.revoked.every((call) => call.scope === "global"));
});
test("failed transactions never revoke sessions or leak database details", async () => {
  const admin = backend({ rpcError: "internal password=private details" });
  const response = await mergeAccounts(
    request({
      action: "confirm",
      ticket: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      keep: "primary",
    }),
    admin,
    { now: () => now },
  );
  assert.equal(response.status, 409);
  assert.equal(admin.revoked.length, 0);
  assert.doesNotMatch(await response.text(), /password|private/);
});
