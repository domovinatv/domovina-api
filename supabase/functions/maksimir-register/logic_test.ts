// deno test supabase/functions/maksimir-register/logic_test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { privateKeyToAccount } from "npm:viem@2/accounts";
import { recoverTypedDataAddress } from "npm:viem@2";
import { type Chain, type DbResult, type Deps, handle, registerTypedData } from "./logic.ts";

// Hardhat račun #1 — ISTI vektor provjerava chain/test/v1/registrar-vector.test.ts u
// stadion-maksimir-natjecaj-2026 (tamo potpis prolazi register() na Hardhatu).
const KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const VECTOR = {
  chainId: 31337,
  contract: "0x5fbdb2315678afecb367f032d93f642f64180aa3",
  commitment: 12345n,
  deadline: 2000000000n,
  signer: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  signature:
    "0x5599fd03ac39f1e4175d5bf4995287400cd5d116f783458af6da78f2796f64281063f0d694e38e8b5deb48c2a31f14d9a382e9b0dc66c55367a7f3d4a8d531ef1c",
};

const CHAIN: Chain = { chainId: 100, contract: "0x00000000000000000000000000000000000000aa", rpcUrl: "http://rpc", counts: true };
const account = privateKeyToAccount(KEY);

function deps(over: Partial<Deps> = {}, log: string[] = []): Deps {
  return {
    userId: async (a) => (a === "Bearer ok" ? "user-1" : null),
    chain: async (id, c) => (id === 100 && c === CHAIN.contract ? CHAIN : null),
    registrarOf: async () => account.address,
    register: async (_u, _c, commitment): Promise<DbResult> => {
      log.push(`register ${commitment}`);
      return { status: "ok", commitment, existing: false, transfer_seq: 7, transferred: { W3YS5VJBZ: 100 } };
    },
    signer: (id) => (id === 100 ? { address: account.address, signTypedData: (td) => account.signTypedData(td) } : null),
    now: () => 1_800_000_000_000,
    ...over,
  };
}
const body = (over: Record<string, unknown> = {}) => ({ chainId: 100, contract: CHAIN.contract.toUpperCase().replace("0X", "0x"), commitment: "42", ...over });

Deno.test("fiksni vektor: isti potpis kao chain/client registerTypedData", async () => {
  const sig = await account.signTypedData(registerTypedData(VECTOR));
  assertEquals(sig, VECTOR.signature);
  assertEquals(account.address, VECTOR.signer);
});

Deno.test("uspjeh: potpis Register(commitment, rok = sada + 1 h) od registrara", async () => {
  const r = await handle("Bearer ok", body(), deps());
  assertEquals(r.status, 200);
  assertEquals(r.body.contract, CHAIN.contract);
  assertEquals(r.body.deadline, String(1_800_000_000 + 3600));
  assertEquals(r.body.transferSeq, 7);
  assertEquals(r.body.transferred, { W3YS5VJBZ: 100 });
  const who = await recoverTypedDataAddress({
    ...registerTypedData({ chainId: 100, contract: CHAIN.contract, commitment: 42n, deadline: BigInt(r.body.deadline as string) }),
    signature: r.body.signature as `0x${string}`,
  });
  assertEquals(who, account.address);
});

Deno.test("bez sesije → 401, baza se ne zove", async () => {
  const log: string[] = [];
  assertEquals((await handle("", body(), deps({}, log))).status, 401);
  assertEquals((await handle("Bearer krivo", body(), deps({}, log))).status, 401);
  assertEquals(log, []);
});

Deno.test("neispravan ulaz → 400 prije baze", async () => {
  const log: string[] = [];
  const d = deps({}, log);
  for (const b of [body({ commitment: "0" }), body({ commitment: "abc" }), body({ commitment: 42 }),
    body({ commitment: "21888242871839275222246405745257275088548364400416034343698204186575808495617" })]) {
    assertEquals((await handle("Bearer ok", b, d)).body.error, "invalid_commitment");
  }
  for (const b of [body({ chainId: "x" }), body({ chainId: -1 }), body({ contract: "0x12" }), null, body({ chainId: 1 })]) {
    assertEquals((await handle("Bearer ok", b, d)).body.error, "unknown_chain");
  }
  assertEquals(log, []);
});

Deno.test("nema ključa ili se ne slaže s ugovorom → 503, baza se ne zove (nema prijenosa bez potpisa)", async () => {
  const log: string[] = [];
  assertEquals((await handle("Bearer ok", body(), deps({ signer: () => null }, log))).body.error, "registrar_unavailable");
  assertEquals((await handle("Bearer ok", body(), deps({ registrarOf: async () => "0x000000000000000000000000000000000000dEaD" }, log))).body.error, "registrar_mismatch");
  assertEquals(log, []);
});

Deno.test("pravila baze: already_registered i commitment_taken → 409 bez potpisa", async () => {
  let r = await handle("Bearer ok", body(), deps({ register: async () => ({ status: "already_registered", commitment: "7" }) }));
  assertEquals([r.status, r.body.error, r.body.commitment, r.body.signature], [409, "already_registered", "7", undefined]);
  r = await handle("Bearer ok", body(), deps({ register: async () => ({ status: "commitment_taken" }) }));
  assertEquals([r.status, r.body.error], [409, "commitment_taken"]);
});

Deno.test("greške baze → poznat kod ili server_error", async () => {
  const fail = (m: string) => deps({ register: async () => { throw new Error(m); } });
  assertEquals((await handle("Bearer ok", body(), fail("chain_terms_not_accepted"))).status, 403);
  assertEquals((await handle("Bearer ok", body(), fail("not_verified"))).status, 403);
  assertEquals((await handle("Bearer ok", body(), fail("voting_closed"))).status, 409);
  const r = await handle("Bearer ok", body(), fail("relation does not exist"));
  assertEquals([r.status, r.body.error], [500, "server_error"]);
});
