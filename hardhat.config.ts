// Get the environment configuration from .env file
//
// To make use of automatic environment setup:
// - Duplicate .env.example file and name it .env
// - Fill in the environment variables
import 'dotenv/config'

import 'hardhat-deploy'
import 'hardhat-contract-sizer'
import '@nomiclabs/hardhat-ethers'
import '@nomicfoundation/hardhat-verify'
import '@layerzerolabs/toolbox-hardhat'
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from 'hardhat/types'

import { EndpointId } from '@layerzerolabs/lz-definitions'

import './type-extensions'
import './tasks/sendOFT'

// Set your preferred authentication method
//
// If you prefer using a mnemonic, set a MNEMONIC environment variable
// to a valid mnemonic
const MNEMONIC = process.env.MNEMONIC

// If you prefer to be authenticated using a private key, set a PRIVATE_KEY environment variable
const PRIVATE_KEY = process.env.PRIVATE_KEY

const accounts: HttpNetworkAccountsUserConfig | undefined = MNEMONIC
    ? { mnemonic: MNEMONIC }
    : PRIVATE_KEY
      ? [PRIVATE_KEY]
      : undefined

if (accounts == null) {
    console.warn(
        'Could not find MNEMONIC or PRIVATE_KEY environment variables. It will not be possible to execute transactions in your example.'
    )
}

// Address of the canonical ON token on BSC mainnet (locked by ONOFTAdapter).
// https://bscscan.com/address/0x0e4F6209eD984b21EDEA43acE6e09559eD051D48
const ON_TOKEN_BSC = '0x0e4F6209eD984b21EDEA43acE6e09559eD051D48'

// Address of the pre-existing, non-mintable ON token on Ethereum mainnet.
// Held in WrappedON as the reserve for auto-unwrap and the manual wrap/unwrap swap.
// https://etherscan.io/address/0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d
const ON_TOKEN_ETH = '0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d'

const config: HardhatUserConfig = {
    paths: {
        cache: 'cache/hardhat',
    },
    solidity: {
        compilers: [
            {
                version: '0.8.34',
                settings: {
                    optimizer: {
                        enabled: true,
                        // Matches optimizer_runs in foundry.toml.
                        // Higher runs → cheaper per-call gas, slightly larger bytecode.
                        // OFT contracts are called many times after deploy, so we bias
                        // toward per-call efficiency over deploy cost.
                        runs: 20_000,
                    },
                    // Pinned so Hardhat and Foundry produce identical bytecode.
                    // Both fields must match across toolchains for Etherscan source
                    // verification to succeed. 'shanghai' is a deliberately
                    // conservative target — solc 0.8.34 supports newer EVM versions,
                    // but shanghai is the floor for both Ethereum and BSC mainnet
                    // (PUSH0 included) so we stay there to keep BSC bytecode portable.
                    evmVersion: 'shanghai',
                    metadata: {
                        bytecodeHash: 'ipfs',
                    },
                },
            },
        ],
    },
    networks: {
        // BSC mainnet — deploys ONOFTAdapter on top of the existing ON token.
        bsc: {
            eid: EndpointId.BSC_V2_MAINNET,
            url: process.env.RPC_URL_BSC || 'https://bsc-dataseed.bnbchain.org',
            accounts,
            oftAdapter: {
                tokenAddress: ON_TOKEN_BSC,
            },
        },
        // Ethereum mainnet — deploys WrappedON (wON), the bridged representation.
        ethereum: {
            eid: EndpointId.ETHEREUM_V2_MAINNET,
            // Dummy public RPC; replace with Alchemy/Infura/your own provider for production.
            // RPC_URL_ETH=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
            url: process.env.RPC_URL_ETH || 'https://eth.llamarpc.com',
            accounts,
            wrappedOft: {
                reserveAddress: ON_TOKEN_ETH,
            },
        },
        hardhat: {
            // Need this for testing because TestHelperOz5.sol is exceeding the compiled contract size limit
            allowUnlimitedContractSize: true,
        },
    },
    namedAccounts: {
        deployer: {
            default: 0, // wallet address of index[0], of the mnemonic in .env
        },
    },
    // Source-code verification on Etherscan + BSCScan.
    // Hardhat-verify maps API keys by chain name (chainId-resolved internally),
    // not by the network name above — so `mainnet` here = Ethereum mainnet.
    etherscan: {
        apiKey: {
            bsc: process.env.BSCSCAN_API_KEY || '',
            mainnet: process.env.ETHERSCAN_API_KEY || '',
        },
    },
    sourcify: {
        // Disable sourcify-by-default warning; we verify via etherscan/bscscan.
        enabled: false,
    },
}

export default config
