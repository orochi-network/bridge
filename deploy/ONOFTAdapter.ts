import assert from 'assert'

import { type DeployFunction } from 'hardhat-deploy/types'

const contractName = 'ONOFTAdapter'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre

    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    // This is an external deployment pulled in from @layerzerolabs/lz-evm-sdk-v2
    //
    // @layerzerolabs/toolbox-hardhat takes care of plugging in the external deployments
    // from @layerzerolabs packages based on the configuration in your hardhat config
    //
    // For this to work correctly, your network config must define an eid property
    // set to `EndpointId` as defined in @layerzerolabs/lz-definitions
    //
    // For example:
    //
    // networks: {
    //   fuji: {
    //     ...
    //     eid: EndpointId.AVALANCHE_V2_TESTNET
    //   }
    // }
    const endpointV2Deployment = await hre.deployments.get('EndpointV2')

    // The token address must be defined in hardhat.config.ts
    // If the token address is not defined, the deployment will log a warning and skip the deployment
    if (hre.network.config.oftAdapter == null) {
        console.warn(`oftAdapter not configured on network config, skipping OFTWrapper deployment`)

        return
    }

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            hre.network.config.oftAdapter.tokenAddress, // token address
            endpointV2Deployment.address, // LayerZero's EndpointV2 address
            deployer, // owner
        ],
        log: true,
        // Idempotent on re-run: if a deployment artifact already records a
        // contract for this name on this network, do NOT issue a fresh CREATE.
        // An OFTAdapter is a singleton in the global mesh — a redeploy would
        // orphan locked supply on-chain and silently corrupt the canonical
        // address recorded in deployments/<network>/. To force a redeploy on
        // test networks, delete the artifact (`rm deployments/<network>/<Name>.json`)
        // or run with `npx hardhat deploy --reset`.
        skipIfAlreadyDeployed: true,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName]

export default deploy
