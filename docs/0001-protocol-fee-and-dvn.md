# 0001 — Protocol fees, OApp fees, and DVN/Executor sourcing

**Status:** Accepted — production deploy goes out with no OApp fee, two required DVNs (`LayerZero Labs` + `Google` — the DVN run by Google Cloud), default LZ Executor.

**Scope:** ON Bridge (BSC ↔ Ethereum) on LayerZero V2. Captures the fee model and message-delivery infrastructure decisions so reviewers don't have to re-derive them from the LZ source.

---

## 1. Two distinct fees in LayerZero V2

LayerZero V2 has two independent fee surfaces. Conflating them is the most common source of confusion:

| Surface | Charged in | Paid by | Goes to | Configurable by us? |
|---|---|---|---|---|
| **Protocol fee** (DVN + Executor) | Native gas (BNB / ETH), as `MessagingFee.nativeFee` | The end user, via `msg.value` on `send()` | DVN operators + Executor operators (split by the protocol) | Indirectly — by choosing which DVNs / Executor to require. The fee floor is set by those operators. |
| **OApp fee** (operator/treasury fee) | Bridged token itself (ON / wON) | The end user, deducted from the bridged amount | Wherever the OApp implementer routes it (treasury, accumulator, fee owner) | Yes — entirely our call to opt in or out. |

The protocol fee is paid on **every** message, regardless of OApp implementation. The OApp fee is opt-in.

---

## 2. The OApp fee — how LZ does it on EVM

LZ ships an abstract **`Fee`** mixin at `node_modules/@layerzerolabs/oft-evm/contracts/Fee.sol`. It is **not** wired into the default `OFT` or `OFTAdapter`; the implementer composes it in.

### Surface

```solidity
abstract contract Fee is IFee, Ownable {
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public defaultFeeBps;
    mapping(uint32 dstEid => FeeConfig config) public feeBps;

    function setDefaultFeeBps(uint16 _feeBps) external onlyOwner;
    function setFeeBps(uint32 _dstEid, uint16 _feeBps, bool _enabled) external onlyOwner;
    function getFee(uint32 _dstEid, uint256 _amount) public view returns (uint256);
}
```

### Wiring

To collect a fee, the OApp inherits `Fee` alongside `OFT` / `OFTAdapter` and overrides `_debitView` (the default at `OFTCore.sol:380` just returns `amountReceivedLD = amountSentLD`):

```solidity
function _debitView(uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
    internal view override returns (uint256 amountSentLD, uint256 amountReceivedLD)
{
    amountSentLD = _removeDust(_amountLD);
    uint256 fee = getFee(_dstEid, amountSentLD);
    amountReceivedLD = amountSentLD - fee;
    if (amountReceivedLD < _minAmountLD) revert SlippageExceeded(amountReceivedLD, _minAmountLD);
}
```

### Who pays — canonical pattern is "user pays, transparently"

- The fee is **deducted from the user's bridged amount**, never charged separately. `amountSentLD - amountReceivedLD == fee`.
- The user previews it via `quoteOFT(sendParam)` (returns `OFTFeeDetail[]`) before signing, and is protected at execution by `minAmountLD` slippage.
- LayerZero takes **no cut** of the OApp fee. It is purely operator revenue.

### Where the fee tokens live (depends on the side)

| Contract type | Where the fee accumulates |
|---|---|
| `OFTAdapter` (lock/unlock — our BSC side) | The user's full `amountSentLD` is `transferFrom`'d into the adapter (see `OFTAdapter.sol:74-83`); only `amountReceivedLD` is encoded into the LZ message. The fee sits in the adapter as excess locked ON, which the owner sweeps via a `withdrawFees` helper the implementer adds. |
| `OFT` (mint/burn — our ETH side) | The implementer chooses: mint the fee to a `feeOwner`, accumulate, or simply not debit it from the user. |

---

## 3. Our decision: no OApp fee at launch

We inherit plain `OFT` / `OFTAdapter`, no `Fee` mixin. Default `_debitView` returns `amountReceivedLD == amountSentLD`. Everything works:

- Bridge moves tokens 1:1, lossless in both directions.
- BSC adapter locks gross == net; ETH `WrappedON` credits the same amount it received in the message.
- Auto-unwrap / manual `wrap` / `unwrap` / `seedReserve` math is unchanged.
- Conservation invariant (`circulating wON == locked ON on BSC`, at rest) holds tightly.
- All 21 unit tests + 7 dry-run tests pass.

The only thing forgone is operator revenue from bridging. No flow is degraded, no UX is worse, no invariant is loosened.

### When to revisit

Adding a fee later requires extending **both** `ONOFTAdapter` and `WrappedON` to inherit `Fee`, override `_debitView` identically, decide direction (most bridges fee outbound from one side only), add a `withdrawFees(to, amount)` helper, and update:

- The conservation-invariant text in `CLAUDE.md`.
- The dry-run assertions in `test/foundry/DryRun.t.sol` to subtract the expected fee.
- The integrator-facing docs in `README.md` "End-user send flow".

A `WithFee` extension is ~50 lines + tests. Defer until there's a concrete fee policy (rate, direction, recipient).

---

## 4. DVN / Executor sourcing

### What we use

`layerzero.config.ts:59`:

```ts
const REQUIRED_DVNS = ['LayerZero Labs', 'Google']
```

| Component | Operator | Registry canonical name | Run by us? |
|---|---|---|---|
| DVN #1 | LayerZero Labs | `LayerZero Labs` | No |
| DVN #2 | Google Cloud | `Google` (id `google-cloud`) | No |
| Executor | Default LayerZero Executor | n/a | No |

`metadata-tools.generateConnectionsConfig` resolves the DVN names to per-chain addresses at `lz:oapp:wire` time via an exact match on the registry's `canonicalName`. The vendor we know as "Google Cloud" appears in the registry under canonical name `Google`; the `'Google Cloud'` string would not resolve. Pre-deploy verification: `npm run check:dvn`. The Executor is the LZ default; no `executor` override appears in the config.

### Why we don't self-operate

- **DVN**: running our own would require an off-chain attestation node, signing keys with hot custody, on-call uptime, and per-chain endpoint integrations. Two independent third-party DVNs (LZ Labs + the `Google` DVN run by Google Cloud) already cover the reasonable threat model: a malicious message has to compromise both operators simultaneously to be delivered.
- **Executor**: smaller ops burden than a DVN, but still continuous. The default LZ Executor has been reliable for established pathways; building redundancy here is rarely justified for a single-pair OApp.

### What the user pays vs. what we pay

The user pays the **full** protocol fee on `send()` as `MessagingFee.nativeFee`. That fee is split by the protocol among the two DVNs and the Executor. **We pay nothing per-message.** Our only ongoing cost is the off-chain monitoring + reserve refill that's already documented in CLAUDE.md "Reserve operations".

### When to revisit

Run a self-DVN only if a concrete threat model emerges where two independent third-party DVNs are insufficient. A self-Executor adds redundancy if the default Executor's reliability becomes a problem on either pathway. Both are reversible additions — you can configure them in for a single pathway without redeploying contracts (`lz:oapp:wire` re-applies config).

---

## 5. Summary

- **OApp fee**: not implemented; bridge works fully 1:1 lossless. Add only when there's a concrete fee policy.
- **DVN / Executor**: use the `LayerZero Labs` and `Google` (Google Cloud) DVNs and the default Executor. We operate no off-chain infrastructure for the bridge to run.
- **End-user fee**: only the LayerZero protocol fee in native gas, paid via `msg.value` on `send()`.
