import { EndpointId } from '@layerzerolabs/lz-definitions'
import { ExecutorOptionType } from '@layerzerolabs/lz-v2-utilities'
import { TwoWayConfig, generateConnectionsConfig } from '@layerzerolabs/metadata-tools'
import { OAppEnforcedOption } from '@layerzerolabs/toolbox-hardhat'

import type { OmniPointHardhat } from '@layerzerolabs/toolbox-hardhat'

/**
 * ON Bridge — Solution 3
 *
 *   BSC (canonical):  ONOFTAdapter wraps the existing ON token at
 *                     0x0e4F6209eD984b21EDEA43acE6e09559eD051D48 (lock/unlock).
 *   ETH (bridged):    WrappedON mints/burns wON ("Wrapped ON").
 *
 *   On inbound (BSC -> ETH), WrappedON either auto-unwraps to real ON when its
 *   reserve covers the amount or falls back to minting wON. Composed messages
 *   are forced to the mint path. See CLAUDE.md for the rationale.
 *
 *   WARNING: ONLY 1 OFTAdapter should exist for this mesh (BSC).
 */
const bscContract: OmniPointHardhat = {
    eid: EndpointId.BSC_V2_MAINNET,
    contractName: 'ONOFTAdapter',
}

const ethContract: OmniPointHardhat = {
    eid: EndpointId.ETHEREUM_V2_MAINNET,
    contractName: 'WrappedON',
}

// Enforced executor options applied automatically to every send().
// Integrators that forget to pass options will still get reliable destination delivery.
//
// gas budget for _lzReceive on the destination:
//   - ETH (WrappedON, plain msg, mint fallback):      ~60-80k
//   - ETH (WrappedON, plain msg, auto-unwrap path):   ~50-90k (vanilla ERC20)
//                                                    higher if the ON token has hooks
//   - ETH (WrappedON, composed msg):                  mint + endpoint.sendCompose ~120-220k
//   - BSC (ONOFTAdapter, plain msg):                  ~50-80k
//   - LayerZero plumbing overhead:                    ~40-60k
//
// The two sides have asymmetric worst cases, so the enforced options are split:
//   - ETH inbound: 300k. Headroom for the composed-mint path under realistic
//                 plumbing overhead. The previous 250k left only ~30k slack on
//                 the worst case, risking stuck high-value messages.
//   - BSC inbound: 250k. Plain `safeTransfer` unlock; no compose dispatch.
// Unused gas is refunded by the executor; over-budgeting is a safety knob, not a cost.
//
// msgType 1 = SEND (plain transfer); msgType 2 = SEND_AND_CALL (composed transfer).
// Both message types get the same minimum LZ_RECEIVE gas so that integrators who
// send a SEND_AND_CALL without remembering to add lzReceive options still land
// in a correctly-gassed _lzReceive. The lzCompose gas budget is NOT enforced
// here because it is fully application-specific; integrators must supply their
// own addExecutorLzComposeOption when using composeMsg.
//
// To learn more, see https://docs.layerzero.network/v2/concepts/applications/oapp-standard#execution-options-and-enforced-settings
const ETH_ENFORCED_OPTIONS: OAppEnforcedOption[] = [
    {
        msgType: 1,
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 300000,
        value: 0,
    },
    {
        msgType: 2, // SEND_AND_CALL
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 300000,
        value: 0,
    },
]

const BSC_ENFORCED_OPTIONS: OAppEnforcedOption[] = [
    {
        msgType: 1,
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 250000,
        value: 0,
    },
    {
        msgType: 2, // SEND_AND_CALL
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 250000,
        value: 0,
    },
]

// Two required DVNs for production defense-in-depth:
//   - LayerZero Labs (default DVN, run by LayerZero)
//   - Google Cloud   (independent operator)
// Both must attest to a message before it can be executed on the destination.
// `metadata-tools` resolves these names to per-chain DVN addresses at wire time.
const REQUIRED_DVNS = ['LayerZero Labs', 'Google Cloud']

// Block confirmations before the source DVN attests.
// BSC: ~3s blocks → 20 confs ≈ 60s
// ETH: ~12s blocks → 15 confs ≈ 3 min
const BSC_TO_ETH_CONFIRMATIONS = 20
const ETH_TO_BSC_CONFIRMATIONS = 15

// With the config generator, pathways declared are automatically bidirectional
// i.e. if you declare A,B there's no need to declare B,A
const pathways: TwoWayConfig[] = [
    [
        bscContract, // Chain A (BSC, ONOFTAdapter)
        ethContract, // Chain B (ETH, WrappedON / wON)
        [REQUIRED_DVNS, []], // [ requiredDVN[], [ optionalDVN[], threshold ] ]
        [BSC_TO_ETH_CONFIRMATIONS, ETH_TO_BSC_CONFIRMATIONS], // [A->B confirmations, B->A confirmations]
        [ETH_ENFORCED_OPTIONS, BSC_ENFORCED_OPTIONS], // [Chain B enforcedOptions (recv on B = ETH), Chain A enforcedOptions (recv on A = BSC)]
    ],
]

export default async function () {
    // Generate the connections config based on the pathways
    const connections = await generateConnectionsConfig(pathways)
    return {
        contracts: [{ contract: bscContract }, { contract: ethContract }],
        connections,
    }
}
