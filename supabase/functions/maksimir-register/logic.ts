// maksimir-register — logika bez mreže i baze (ovisnosti se ubrizgavaju; v. logic_test.ts).
//
// Registrar glasanja na lancu (MaksimirGlasanjeV1): nakon eOsobne potpiše EIP-712
// Register(commitment, deadline) za ugovor iz maksimir_chains. Jedna osoba = jedan
// commitment po ugovoru; to pravilo i „prijenos” listića faze 1 provodi baza
// (_maksimir_chain_register_for) u jednoj transakciji. Registrar ne šalje transakciju
// i ne vidi listić: potpis vraća pregledniku, a on ga šalje relayeru ili sam.
//
// Plan: stadion-maksimir-natjecaj-2026 docs/blockchain/08-integracija-s-fazom-1.md

export type Hex = `0x${string}`;

export type Chain = { chainId: number; contract: string; rpcUrl: string; counts: boolean };

export type DbResult =
  | { status: "ok"; commitment: string; existing: boolean; transfer_seq: number | null; transferred?: Record<string, number> }
  | { status: "already_registered"; commitment: string }
  | { status: "commitment_taken" };

export type Signer = {
  address: string;
  signTypedData(td: ReturnType<typeof registerTypedData>): Promise<Hex>;
};

export type Deps = {
  userId(authorization: string): Promise<string | null>;
  chain(chainId: number, contract: string): Promise<Chain | null>;
  /** Adresa registrara zapisana u ugovoru (eth_call registrar()). */
  registrarOf(chain: Chain): Promise<string>;
  register(userId: string, chain: Chain, commitment: string): Promise<DbResult>;
  signer(chainId: number): Signer | null;
  now(): number; // ms
};

export const DEADLINE_SECONDS = 3600;

/** = chain/client/ballot.ts registerTypedData (isti domain, tipovi i poruka). */
export function registerTypedData(w: { chainId: number; contract: string; commitment: bigint; deadline: bigint }) {
  return {
    domain: { name: "MaksimirGlasanje", version: "1", chainId: w.chainId, verifyingContract: w.contract as Hex },
    types: { Register: [{ name: "commitment", type: "uint256" }, { name: "deadline", type: "uint256" }] },
    primaryType: "Register" as const,
    message: { commitment: w.commitment, deadline: w.deadline },
  };
}

const FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

// Greške baze (raise exception) → HTTP status. Ostalo je 500.
const DB_ERRORS: Record<string, number> = {
  not_verified: 403,
  chain_terms_not_accepted: 403,
  unknown_chain: 400,
  invalid_commitment: 400,
  weak_commitment: 400, // javno poznat ključ (npr. same nule), nalaz I-09
  voting_closed: 409,
};

export type Reply = { status: number; body: Record<string, unknown> };
const reply = (status: number, body: Record<string, unknown>): Reply => ({ status, body });

export async function handle(authorization: string, input: unknown, deps: Deps): Promise<Reply> {
  const uid = authorization ? await deps.userId(authorization) : null;
  if (!uid) return reply(401, { error: "not_signed_in" });

  const b = (input ?? {}) as Record<string, unknown>;
  const chainId = Number(b.chainId);
  const contract = typeof b.contract === "string" ? b.contract.toLowerCase() : "";
  const commitment = typeof b.commitment === "string" ? b.commitment : "";
  if (!Number.isSafeInteger(chainId) || chainId <= 0 || !/^0x[0-9a-f]{40}$/.test(contract)) {
    return reply(400, { error: "unknown_chain" });
  }
  if (!/^[0-9]{1,78}$/.test(commitment) || BigInt(commitment) === 0n || BigInt(commitment) >= FIELD) {
    return reply(400, { error: "invalid_commitment" });
  }

  const chain = await deps.chain(chainId, contract);
  if (!chain) return reply(400, { error: "unknown_chain" });
  // Ključ i adresa u ugovoru moraju se slagati PRIJE upisa u bazu: inače bi prijenos
  // listića faze 1 prošao, a potpis ne bi vrijedio na lancu.
  const signer = deps.signer(chainId);
  if (!signer) return reply(503, { error: "registrar_unavailable" });
  const onChain = (await deps.registrarOf(chain)).toLowerCase();
  if (onChain !== signer.address.toLowerCase()) return reply(503, { error: "registrar_mismatch" });

  let r: DbResult;
  try {
    r = await deps.register(uid, chain, commitment);
  } catch (e) {
    const code = (e as Error).message;
    return reply(DB_ERRORS[code] ?? 500, { error: DB_ERRORS[code] ? code : "server_error" });
  }
  if (r.status === "already_registered") return reply(409, { error: "already_registered", commitment: r.commitment });
  if (r.status === "commitment_taken") return reply(409, { error: "commitment_taken" });

  const deadline = BigInt(Math.floor(deps.now() / 1000) + DEADLINE_SECONDS);
  const signature = await signer.signTypedData(
    registerTypedData({ chainId, contract: chain.contract, commitment: BigInt(r.commitment), deadline })
  );
  return reply(200, {
    chainId,
    contract: chain.contract,
    commitment: r.commitment,
    deadline: deadline.toString(),
    signature,
    existing: r.existing,
    transferSeq: r.transfer_seq,
    transferred: r.transferred ?? {},
  });
}
