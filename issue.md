# Issue: 3 fork test suites fail under forge 1.7.1 (self-skip broken)

**Status:** Open
**Severity:** Low (tooling / DX — no contract impact)
**Found:** 2026-06-14, during mainnet pre-flight verification
**Toolchain:** forge 1.7.1 (commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`)

## Summary

`make test` (`forge test -vvv`) exits non-zero when `ETH_RPC` / `BSC_RPC` are unset.
Three fork suites fail in `setUp()` instead of self-skipping:

- `test/fork/Fork_ETH.t.sol` — `Fork_ETH`
- `test/fork/Fork_BSC.t.sol` — `Fork_BSC`
- `test/fork/Fork_Bridge.t.sol` — `Fork_Bridge`

This is a **toolchain regression, not a contract or test-logic defect**. Every non-fork
test passes:

```
forge test --no-match-path 'test/fork/**'
=> 141 tests passed, 0 failed, 0 skipped (10 suites)
```

## Observed output

```
make test
...
[FAIL: call to non-contract address 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48] setUp() (gas: 0)
Suite result: FAILED. 0 passed; 1 failed; 0 skipped   # Fork_BSC
[FAIL: Contract 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d does not exist and is not marked as persistent] setUp() (gas: 0)
Suite result: FAILED. 0 passed; 1 failed; 0 skipped   # Fork_ETH
[FAIL: call to non-contract address 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d] setUp() (gas: 0)
Suite result: FAILED. 0 passed; 1 failed; 0 skipped   # Fork_Bridge

Ran 13 test suites: 141 tests passed, 3 failed, 0 skipped (144 total tests)
```

Reproduce a single suite:

```
unset ETH_RPC BSC_RPC
forge test --match-path 'test/fork/Fork_ETH.t.sol'
=> [FAIL: EvmError: Revert] setUp() (gas: 0)
```

## Root cause

The fork suites gate themselves with `vm.skip(true)` inside `setUp()`:

```solidity
function setUp() public {
    string memory rpc = vm.envOr("ETH_RPC", string(""));
    if (bytes(rpc).length == 0) {
        vm.skip(true);
        return;
    }
    ...
}
```

Under forge 1.7.1, `vm.skip(true)` called from `setUp()` no longer suppresses the
suite — execution continues, and with no fork the live mainnet token addresses
(`0x33f6…59d` ETH ON, `0x0e4F…1D48` BSC ON) are non-contract, so the first
staticcall in `setUp` reverts. The intended "skip when RPC unset" behaviour
(documented in each fork file's `Skipped automatically when ETH_RPC is not set`
header and in `RUNBOOK.md` §0.4) is broken.

## Impact

- `make test` is no longer green on a clean checkout without fork RPCs, contradicting
  RUNBOOK §0.4 ("all … non-fork tests must pass") and the CLAUDE.md "fork tests
  self-skip when ETH_RPC/BSC_RPC unset" claim.
- CI / pre-flight gates that shell out to `make test` will report a false failure.
- No effect on deployed contracts, deploy scripts, or the actual fork coverage when
  RPCs *are* provided (`make test-fork ETH_RPC=… BSC_RPC=…` runs normally).

## Doc drift noticed alongside

- Non-fork test count is now **141**, not the **130** quoted in CLAUDE.md / RUNBOOK §0.4.
  Total with fork suites = 144.

## Proposed fixes (pick one)

1. **Preferred — exclude fork tests from the `test` target** so `make test` covers only
   the mock/integration suite and fork runs stay explicit under `make test-fork`:

   ```make
   test:
   	forge test --no-match-path 'test/fork/**' -vvv
   ```

   Matches the documented "non-fork tests" intent; deterministic offline; no reliance on
   `vm.skip` semantics.

2. **Keep the skip but make it effective under 1.7.1** — move the gate out of `setUp`
   (e.g. guard each test body, or use a `modifier`/early `return` pattern that the
   installed forge honours), and re-verify `0 failed, N skipped` with RPCs unset.

3. Pin / document a forge version where `vm.skip()` in `setUp` still self-skips
   (least preferred — freezes the toolchain to work around a tooling change).

When fixed, also refresh the **130 → 141** non-fork count in CLAUDE.md and RUNBOOK §0.4.

## Verification after fix

```
unset ETH_RPC BSC_RPC
make test            # expect: 0 failed (fork suites excluded or cleanly skipped)
make test-fork ETH_RPC=<url> BSC_RPC=<url>   # expect: fork suites still run and pass
```
