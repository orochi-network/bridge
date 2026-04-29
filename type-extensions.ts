import 'hardhat/types/config'

interface OftAdapterConfig {
    tokenAddress: string
}

interface WrappedOftConfig {
    // Address of the pre-existing, non-mintable ON ERC20 on the wrapper-side chain.
    // Held by `WrappedON` as the reserve for auto-unwrap and the manual wrap/unwrap
    // swap. See contracts/WrappedON.sol.
    reserveAddress: string
}

declare module 'hardhat/types/config' {
    interface HardhatNetworkUserConfig {
        oftAdapter?: never
        wrappedOft?: never
    }

    interface HardhatNetworkConfig {
        oftAdapter?: never
        wrappedOft?: never
    }

    interface HttpNetworkUserConfig {
        oftAdapter?: OftAdapterConfig
        wrappedOft?: WrappedOftConfig
    }

    interface HttpNetworkConfig {
        oftAdapter?: OftAdapterConfig
        wrappedOft?: WrappedOftConfig
    }
}
