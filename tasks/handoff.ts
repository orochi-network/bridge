import { task, types } from 'hardhat/config'
import { HardhatRuntimeEnvironment } from 'hardhat/types'

import { EndpointId } from '@layerzerolabs/lz-definitions'

/**
 * `lz:oapp:handoff` — atomic ownership + delegate transfer to the production
 * multisig.
 *
 * The deploy scripts leave the deployer EOA as both `owner` and `delegate`
 * because `lz:oapp:wire` needs an EOA-callable signer. Until ownership is
 * handed off, that hot key can rewire peers, change DVNs, and forge
 * arbitrary inbound messages by pointing the local OApp at a malicious
 * peer. The post-deploy checklist required two manual transactions per
 * chain; this task collapses them into a single command per network so the
 * deploy → wire → handoff sequence is atomic from the operator's view.
 *
 * Pre-flight: refuses to proceed unless the OApp is already wired. Concretely
 *   - peers(remoteEid) on the OApp must be non-zero (proves `lz:oapp:wire`
 *     applied the BSC↔ETH peer set on this side); and
 *   - delegates(oapp) on the LayerZero endpoint must be non-zero (proves a
 *     delegate was set; otherwise transferring ownership would leave the
 *     OApp without anyone able to call setDelegate / setEnforcedOptions
 *     except via the multisig).
 * This protects against handing off a partially-wired OApp to the multisig,
 * which would force every remaining wire step through N-of-M signatures.
 *
 * Usage:
 *   OWNER_BSC=0x... npx hardhat lz:oapp:handoff --network bsc \
 *     --contract ONOFTAdapter
 *   OWNER_ETH=0x... npx hardhat lz:oapp:handoff --network ethereum \
 *     --contract WrappedON
 *
 * Order matters: `setDelegate(multisig)` is called first (still requires
 * `owner`), then `transferOwnership(multisig)`. Once the owner has been
 * transferred, the EOA can no longer call `setDelegate`, so reversing the
 * order would lock the EOA out before it has a chance to set the delegate.
 */

interface HandoffArgs {
    contract: string
    /** Override the multisig address; default is read from OWNER_BSC / OWNER_ETH. */
    multisig?: string
}

const ENV_KEY_BY_NETWORK: Record<string, string> = {
    bsc: 'OWNER_BSC',
    ethereum: 'OWNER_ETH',
}

// Mirror of the BSC↔ETH pathway declared in layerzero.config.ts. Used by the
// pre-flight check to assert that `peers(remoteEid)` was set on this side.
const REMOTE_EID_BY_NETWORK: Record<string, number> = {
    bsc: EndpointId.ETHEREUM_V2_MAINNET,
    ethereum: EndpointId.BSC_V2_MAINNET,
}

task('lz:oapp:handoff', 'Transfer delegate then ownership of an OApp to the production multisig')
    .addParam('contract', 'Deployed contract name (ONOFTAdapter or WrappedON)', undefined, types.string)
    .addOptionalParam('multisig', 'Override the multisig address (default: OWNER_BSC / OWNER_ETH from env)', undefined, types.string)
    .setAction(async (args: HandoffArgs, hre: HardhatRuntimeEnvironment) => {
        const { ethers, network, deployments, getNamedAccounts } = hre

        const envKey = ENV_KEY_BY_NETWORK[network.name]
        if (!envKey && !args.multisig) {
            throw new Error(
                `Unknown network "${network.name}" — provide --multisig explicitly or run on bsc/ethereum.`
            )
        }
        const multisig = args.multisig ?? process.env[envKey]
        if (!multisig) {
            throw new Error(`Multisig address not set. Pass --multisig or set ${envKey} in .env.`)
        }
        if (!ethers.utils.isAddress(multisig)) {
            throw new Error(`Multisig "${multisig}" is not a valid address.`)
        }
        if (multisig === ethers.constants.AddressZero) {
            throw new Error(`Refusing to hand off to the zero address.`)
        }

        const deployment = await deployments.get(args.contract)
        const { deployer } = await getNamedAccounts()
        const signer = await ethers.getSigner(deployer)

        const oapp = new ethers.Contract(
            deployment.address,
            [
                'function owner() view returns (address)',
                'function endpoint() view returns (address)',
                'function peers(uint32) view returns (bytes32)',
                'function setDelegate(address)',
                'function transferOwnership(address)',
            ],
            signer
        )

        const currentOwner: string = await oapp.owner()
        // Idempotency: if the handoff already completed, exit cleanly so the
        // task is safe to re-run from operator automation. This must run
        // before the deployer-ownership guard, which would otherwise throw
        // for the (correct) post-handoff state where owner is the multisig.
        if (currentOwner.toLowerCase() === multisig.toLowerCase()) {
            console.log(`Owner already equals multisig (${multisig}); nothing to do.`)
            return
        }
        if (currentOwner.toLowerCase() !== deployer.toLowerCase()) {
            throw new Error(
                `Refusing to hand off: ${args.contract} owner is ${currentOwner}, expected deployer ${deployer} or multisig ${multisig}. ` +
                    `The contract is owned by an unexpected address — investigate before proceeding.`
            )
        }

        // Pre-flight: refuse to hand off an OApp that has not been wired.
        // After ownership transfers to the multisig, every remaining wire
        // step (setPeer, setDelegate, setEnforcedOptions, setSendLibrary,
        // setReceiveLibrary, setConfig) requires N-of-M multisig signatures.
        // Catching the unwired state here keeps the deploy → wire → handoff
        // sequence operator-recoverable.
        const remoteEid = REMOTE_EID_BY_NETWORK[network.name]
        if (remoteEid === undefined) {
            throw new Error(
                `Unknown network "${network.name}": cannot determine remote EID for the peer pre-flight check. ` +
                    `Update REMOTE_EID_BY_NETWORK in tasks/handoff.ts if you have added a new network.`
            )
        }
        const peer: string = await oapp.peers(remoteEid)
        if (ethers.BigNumber.from(peer).isZero()) {
            throw new Error(
                `Refusing to hand off: peers(${remoteEid}) is bytes32(0) on ${args.contract}. ` +
                    `Run \`npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts\` first; the multisig is not the right party to set peers.`
            )
        }

        const endpointAddress: string = await oapp.endpoint()
        const endpoint = new ethers.Contract(
            endpointAddress,
            ['function delegates(address) view returns (address)'],
            signer
        )
        const delegate: string = await endpoint.delegates(deployment.address)
        if (delegate === ethers.constants.AddressZero) {
            throw new Error(
                `Refusing to hand off: endpoint.delegates(${deployment.address}) is address(0). ` +
                    `Run \`npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts\` first to set a delegate; ` +
                    `transferring ownership now would leave the OApp with no delegate to call setEnforcedOptions / setConfig.`
            )
        }
        if (delegate.toLowerCase() !== deployer.toLowerCase()) {
            console.warn(
                `WARNING: current delegate (${delegate}) is not the deployer (${deployer}). ` +
                    `Proceeding will overwrite it with the multisig.`
            )
        }

        console.log(`Network:        ${network.name}`)
        console.log(`Contract:       ${args.contract} @ ${deployment.address}`)
        console.log(`Current owner:  ${currentOwner}`)
        console.log(`Multisig:       ${multisig}`)
        console.log()
        console.log(`Step 1/2: setDelegate(${multisig})`)
        const txDelegate = await oapp.setDelegate(multisig)
        const rcDelegate = await txDelegate.wait()
        console.log(`  ✓ tx: ${rcDelegate.transactionHash}`)

        console.log(`Step 2/2: transferOwnership(${multisig})`)
        const txOwner = await oapp.transferOwnership(multisig)
        const rcOwner = await txOwner.wait()
        console.log(`  ✓ tx: ${rcOwner.transactionHash}`)

        const finalOwner: string = await oapp.owner()
        if (finalOwner.toLowerCase() !== multisig.toLowerCase()) {
            throw new Error(
                `Post-condition failed: owner is ${finalOwner}, expected ${multisig}. ` +
                    `Investigate before declaring the handoff complete.`
            )
        }
        console.log()
        console.log(`Handoff complete. Owner is now ${finalOwner}.`)
        console.log(`Verify on-chain that the multisig can call setPeer / setDelegate before going live.`)
    })
