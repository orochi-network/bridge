import { task, types } from 'hardhat/config'
import { HardhatRuntimeEnvironment } from 'hardhat/types'

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
