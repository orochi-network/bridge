import assert from 'assert'

import { type DeployFunction } from 'hardhat-deploy/types'

const contractName = 'WrappedON'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre

    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    const endpointV2Deployment = await hre.deployments.get('EndpointV2')

    // Skip on the adapter-side network. Only deploy WrappedON where wrappedOft
    // configuration is present (see hardhat.config.ts and type-extensions.ts).
    if (hre.network.config.oftAdapter != null) {
        console.warn(`oftAdapter configuration found, skipping WrappedON deployment on this network`)
        return
    }
    if (hre.network.config.wrappedOft == null) {
        console.warn(`wrappedOft not configured on network config, skipping WrappedON deployment`)
        return
    }

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            'Wrapped ON', // name
            'wON', // symbol
            endpointV2Deployment.address, // LayerZero's EndpointV2 address
            deployer, // owner — transferred to multisig after wiring (see README)
            hre.network.config.wrappedOft.reserveAddress, // pre-existing ETH ON used as the unwrap reserve
        ],
        log: true,
        // Idempotent on re-run: a redeploy would mint a fresh wON with an
        // empty reserve, no peer, and the EOA as owner — orphaning the
        // production instance plus any seeded reserve and outstanding wON.
        // Force redeploys on test networks by removing the artifact or
        // running `npx hardhat deploy --reset`.
        skipIfAlreadyDeployed: true,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName]

export default deploy
