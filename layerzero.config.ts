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
 *   Users on Ethereum hold wON directly — there is no on-chain unwrap path
 *   to the pre-existing ETH ON token. See CLAUDE.md for the rationale.
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
//   - ETH side (WrappedON): mints wON to the recipient — ~60-80k.
//   - BSC side (ONOFTAdapter): transfers ON from escrow — ~50-80k assuming ON is a vanilla ERC20.
// 200k gives generous headroom; unused gas is refunded by the executor.
//
// To learn more, see https://docs.layerzero.network/v2/concepts/applications/oapp-standard#execution-options-and-enforced-settings
const EVM_ENFORCED_OPTIONS: OAppEnforcedOption[] = [
    {
        msgType: 1,
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 200000,
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
        [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS], // [Chain B enforcedOptions (recv on B), Chain A enforcedOptions (recv on A)]
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
