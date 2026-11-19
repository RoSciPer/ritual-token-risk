/**
 * Encodes the 32-field Ritual LLM precompile (0x0802) request for TokenRiskCheck.checkToken.
 *
 * Reads owner/totalSupply from the token on Ritual Chain, puts them in the prompt, and prints
 * the ABI-encoded bytes. Field order/types follow docs.ritualfoundation.org > LLM Inference.
 *
 * Usage:
 *   TOKEN=0x... EXECUTOR=0x... SPONSOR=0x... \
 *   CONVO_PLATFORM=gcs CONVO_PATH=convos/token-risk.jsonl CONVO_KEY_REF=GCS_CREDS \
 *   npm run encode
 */
import {
  createPublicClient,
  defineChain,
  encodeAbiParameters,
  formatUnits,
  getAddress,
  http,
  parseAbi,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";

export const ritualChain = defineChain({
  id: 784,
  name: "Ritual Chain",
  nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.ritualfoundation.org"] } },
  blockExplorers: { default: { name: "Explorer", url: "https://explorer.ritualfoundation.org" } },
});

/** Exactly the 32 types from the docs' 32-Field ABI Reference (indices in comments below). */
export const LLM_REQUEST_ABI = parseAbiParameters(
  "address, address, address[], bytes[], uint256, bytes[], bytes, string, string, int256, string, bool, int256, string, string, uint256, bool, int256, string, bytes, int256, string, string, bool, int256, bytes, bytes, int256, int256, string, bool, (string,string,string)",
);

export const DEFAULT_MODEL = "deepseek-ai/DeepSeek-V4-Flash-0731";

export type TokenInfo = {
  token: Address;
  owner: Address | null; // null = token has no owner()
  totalSupply: bigint;
  decimals: number;
  symbol: string;
};

export type LlmRequestParams = {
  executor: Address;
  sponsor: Address;
  messagesJson: string;
  convoHistory: readonly [platform: string, path: string, keyRef: string];
  model?: string;
  ttl?: bigint; // blocks, 1-500
  maxCompletionTokens?: bigint; // -1 = model default
};

export function buildMessages(info: TokenInfo): string {
  const facts = [
    `Token: ${info.token} (${info.symbol})`,
    `Owner: ${info.owner ?? "none (no owner() function)"}`,
    `Total supply: ${formatUnits(info.totalSupply, info.decimals)} ${info.symbol}`,
  ].join("\n");
  return JSON.stringify([
    {
      role: "system",
      content:
        'You assess ERC-20 token risk. Reply with JSON only: {"riskScore": <0-100>, "summary": "<one sentence>"}.',
    },
    { role: "user", content: facts },
  ]);
}

export function encodeLlmRequest(p: LlmRequestParams): Hex {
  const ttl = p.ttl ?? 30n;
  if (ttl < 1n || ttl > 500n) throw new Error("ttl must be 1-500 blocks");
  return encodeAbiParameters(LLM_REQUEST_ABI, [
    p.executor, //            0 executor
    p.sponsor, //             1 sponsor (RitualWallet account billed)
    [], //                    2 secretOwners
    [], //                    3 encryptedSecrets
    ttl, //                   4 ttl
    [], //                    5 secretSignatures
    "0x", //                  6 userPublicKey (empty = plaintext)
    p.messagesJson, //        7 messagesJson
    p.model ?? DEFAULT_MODEL, // 8 model
    0n, //                    9 frequencyPenalty (x1000)
    "", //                   10 logitBiasJson
    false, //                11 logprobs
    p.maxCompletionTokens ?? 200n, // 12 maxCompletionTokens (caps cost)
    "", //                   13 metadataJson
    "", //                   14 modalitiesJson
    1n, //                   15 n
    false, //                16 parallelToolCalls
    0n, //                   17 presencePenalty (x1000)
    "", //                   18 reasoningEffort
    "0x", //                 19 responseFormatData
    -1n, //                  20 seed (-1 = null)
    "", //                   21 serviceTier
    "", //                   22 stopJson
    false, //                23 stream
    0n, //                   24 temperature (x1000) -> 0.0 for consistent scoring
    "0x", //                 25 toolChoiceData
    "0x", //                 26 toolsData
    -1n, //                  27 topLogprobs (-1 = null)
    1000n, //                28 topP (x1000)
    "", //                   29 user
    false, //                30 piiEnabled
    p.convoHistory, //       31 convoHistory (required)
  ]);
}

const erc20Abi = parseAbi([
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function owner() view returns (address)",
]);

export async function readTokenInfo(token: Address, rpcUrl?: string): Promise<TokenInfo> {
  const client = createPublicClient({ chain: ritualChain, transport: http(rpcUrl) });
  const read = <T>(functionName: "totalSupply" | "decimals" | "symbol" | "owner") =>
    client.readContract({ address: token, abi: erc20Abi, functionName }) as Promise<T>;

  const totalSupply = await read<bigint>("totalSupply"); // must succeed: it's the ERC-20 check
  const [decimals, symbol, owner] = await Promise.all([
    read<number>("decimals").catch(() => 18),
    read<string>("symbol").catch(() => "?"),
    read<Address>("owner").catch(() => null), // owner() is optional
  ]);
  return { token, owner, totalSupply, decimals, symbol };
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var ${name}`);
  return v;
}

async function main() {
  const token = getAddress(requireEnv("TOKEN"));
  const info = await readTokenInfo(token, process.env.RPC_URL);
  const encoded = encodeLlmRequest({
    executor: getAddress(requireEnv("EXECUTOR")),
    sponsor: getAddress(requireEnv("SPONSOR")),
    messagesJson: buildMessages(info),
    convoHistory: [requireEnv("CONVO_PLATFORM"), requireEnv("CONVO_PATH"), requireEnv("CONVO_KEY_REF")],
    model: process.env.MODEL,
  });
  console.error(`Read on chain 784: owner=${info.owner ?? "none"} totalSupply=${info.totalSupply}`);
  console.log(encoded); // stdout = just the hex, so it can be piped into cast
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exit(1);
  });
}
