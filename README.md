# ritual-token-risk

An ERC-20 risk check that runs on Ritual Chain. The contract reads a token's `owner()` and
`totalSupply()` on-chain, then calls Ritual's native LLM precompile (`0x0802`) with a request
encoded off-chain. It stores the on-chain facts together with the model's answer.

> ## ⚠️ Integration is untested
>
> **This has not run on Ritual Chain (chain ID 784).** The local tests use `vm.mockCall` to fake
> the precompile's return bytes. They only check that the contract forwards the request unchanged
> and decodes the response correctly. Ritual's docs say async precompiles don't exist on a local
> EVM ("a passing local test proves nothing"). The only proof of integration is a settled receipt
> on a real Ritual network. Until then, consider these unverified:
>
> - that an executor accepts the request encoded by `scripts/encodeLlmRequest.ts`;
> - the response envelope `abi.encode(bytes simmedInput, bytes actualOutput)`. The docs describe
>   it in one line, but `PrecompileConsumer`'s source isn't published, so the unwrapping in
>   `decodeLLMResponse` follows that description, not Ritual's code;
> - the format of `completionData`. The contract stores it as raw bytes and does not parse it.

## How it works

```
off-chain (TypeScript, viem)                on-chain (TokenRiskCheck)
────────────────────────────                ────────────────────────────────────────
read owner/totalSupply via RPC   ──►  checkToken(token, llmInput)
build prompt, encode 32-field              1. read owner() + totalSupply()  (EVM)
LLM request → llmInput bytes               2. call 0x0802 with llmInput     (TEE, async SPC)
                                           3. decode response, store, emit TokenChecked
```

The LLM call is "short-running async": the block builder sends it to a TEE executor and replays
the transaction with the signed result, so the answer arrives inside the same `checkToken` call.
Only one async precompile call is allowed per transaction.

**Design note:** the prompt is built off-chain, so the contract can't prove the prompt contained
the true owner and supply. That's why the contract reads both values itself and stores them next
to the completion. The on-chain values are the trusted record; the LLM text is commentary.

## Files

| File | Purpose |
|------|---------|
| `src/TokenRiskCheck.sol` | The contract: on-chain reads, `0x0802` call, envelope + `LLMResponse` decoding, storage. |
| `test/TokenRiskCheck.t.sol` | Unit tests (decoding/handler logic only, see warning above). |
| `scripts/encodeLlmRequest.ts` | Reads token facts from chain 784 and ABI-encodes the 32-field LLM request with viem. |
| `foundry.toml` | solc 0.8.24, `evm_version = "shanghai"` and a `ritual` RPC alias, per the docs. |
| `package.json`, `tsconfig.json` | viem + tsx for the script. |

## Run the tests

```bash
forge test -vv
```

7 tests cover:
- the input is forwarded verbatim to `0x0802`;
- owner and supply are stored, including tokens without `owner()`;
- the completion is stored and the event emitted;
- `hasError` reverts with the model's error message;
- non-contracts are rejected;
- calling `0x0802` without a mock reverts with `EmptyPrecompileOutput`, which is what a local EVM
  really returns.

## Encode a request

```bash
npm install
TOKEN=0x... \
EXECUTOR=0x...        `# TEE executor serving the model, from TEEServiceRegistry` \
SPONSOR=0x...         `# RitualWallet account billed for the job` \
CONVO_PLATFORM=gcs CONVO_PATH=convos/token-risk.jsonl CONVO_KEY_REF=GCS_CREDS \
npm run encode > llm-input.hex
```

`convoHistory` (field 31) is required by the precompile. The values above are the docs' example.
Replace them with a storage location you control. Defaults: model
`deepseek-ai/DeepSeek-V4-Flash-0731`, temperature 0, max 200 completion tokens, TTL 30 blocks.

## Deploy and run on Ritual Chain (not yet done)

1. Fund the signer with RITUAL for gas.
2. Fund the sponsor in RitualWallet (`0xF04076756d8129Baec46Dc0F1c526Baec490C393`) with
   `deposit()`. The contract (not the sponsor) is the precompile's caller, so the sponsor must
   also call `approve(<TokenRiskCheck address>, amount)`.
3. Deploy:
   `forge create src/TokenRiskCheck.sol:TokenRiskCheck --rpc-url ritual --private-key $PK --broadcast`
4. Call:
   `cast send <addr> "checkToken(address,bytes)" $TOKEN $(cat llm-input.hex) --rpc-url ritual --private-key $PK`
5. Check the receipt's `spcCalls` and the `TokenChecked` event, then read `getCheck(token)`.
   **Only once this succeeds can integration be called tested.**

Notes: each sender can only have one async job in flight (sender lock). Per the docs, a failed
LLM call settles with `hasError=true` and a fixed 0.01 RITUAL error fee. This contract then
reverts with `LLMError`. Whether the fee is still charged after that revert is not documented and
is untested.

Source: <https://docs.ritualfoundation.org> (Quick Start, LLM Inference, Consumer Patterns,
RitualWallet, Testing).
