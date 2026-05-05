#!/usr/bin/env node
// scripts/check-dvn.js
//
// Pre-deploy verification that the production DVNs are live on BSC and
// Ethereum mainnet. Mirrors the operator obligation called out in
// SECURITY.md and the post-deploy checklist in CLAUDE.md.
//
// What this script does:
//   1. Pulls the LayerZero metadata registry (the same source of truth used
//      by `metadata-tools` at `lz:oapp:wire` time).
//   2. Resolves each required DVN's address on BSC and Ethereum by exact
//      (`===`) `canonicalName` match — the same exact-match rule
//      `metadata-tools` applies to both DVN names AND executor names.
//   3. Verifies the resolved address has bytecode and responds to a view
//      call (`quorum()` exists on every LZ V2 DVN implementation).
//   4. Reports the chain head's age so a stale RPC is obvious.
//
// What it does NOT do:
//   - Verify that the DVN has attested to a recent message. That requires
//      knowing the DVN's exact event topic across versions; for pre-deploy
//      "is the DVN reachable" the bytecode + view-call probe is enough.
//
// Usage:
//   RPC_URL_BSC=... RPC_URL_ETH=... node scripts/check-dvn.js
//   (or rely on .env via dotenv — `yarn check:dvn`)
//
// Exit code 0 if every required DVN passes on every chain, 1 otherwise.

require('dotenv/config')
const { ethers } = require('ethers')

const METADATA_URL = 'https://metadata.layerzero-api.com/v1/metadata'

// Must match REQUIRED_DVNS in layerzero.config.ts. These are the canonical
// names from the LayerZero metadata registry, NOT vendor brand names. The
// DVN run by Google Cloud is registered under canonicalName "Google".
const REQUIRED_DVN_NAMES = ['LayerZero Labs', 'Google']

const TARGETS = [
    { chainKey: 'bsc', label: 'BSC mainnet', envRpc: 'RPC_URL_BSC' },
    { chainKey: 'ethereum', label: 'Ethereum mainnet', envRpc: 'RPC_URL_ETH' },
]

const DVN_ABI = ['function quorum() view returns (uint64)']

async function fetchMetadata() {
    const res = await fetch(METADATA_URL)
    if (!res.ok) throw new Error(`metadata fetch failed: HTTP ${res.status}`)
    return res.json()
}

// Resolve a DVN canonical name to its address on a given chain. Mirrors the
// rule used by `metadata-tools/DVNsToAddresses`: not deprecated, version 2,
// not lzRead-only.
function resolveDvnAddress(metadata, chainKey, dvnName) {
    const chain = metadata[chainKey]
    if (!chain || !chain.dvns) throw new Error(`metadata has no DVN registry for chainKey "${chainKey}"`)
    for (const [addr, info] of Object.entries(chain.dvns)) {
        if (
            info.canonicalName === dvnName &&
            info.version === 2 &&
            !info.deprecated &&
            !info.lzReadCompatible
        ) {
            return addr
        }
    }
    return null
}

async function probeDvn(provider, addr) {
    const code = await provider.getCode(addr)
    if (!code || code === '0x') return { ok: false, error: 'no bytecode at address' }
    const dvn = new ethers.Contract(addr, DVN_ABI, provider)
    try {
        const q = await dvn.quorum()
        return { ok: true, codeBytes: (code.length - 2) / 2, quorum: q.toString() }
    } catch (e) {
        return { ok: false, error: `quorum() reverted: ${e.message}` }
    }
}

async function checkChain(target, metadata) {
    console.log(`\n=== ${target.label} (chainKey "${target.chainKey}") ===`)

    const rpc = process.env[target.envRpc]
    if (!rpc) {
        console.log(`  ✗ ${target.envRpc} is not set in env — cannot probe`)
        return false
    }

    const provider = new ethers.providers.JsonRpcProvider(rpc)
    let head
    try {
        head = await provider.getBlock('latest')
    } catch (e) {
        console.log(`  ✗ ${target.envRpc} unreachable: ${e.message}`)
        return false
    }
    const ageSec = Math.floor(Date.now() / 1000) - head.timestamp
    const ageWarn = ageSec > 60 ? ' (WARNING: stale)' : ''
    console.log(`  RPC head: block ${head.number}, age ${ageSec}s${ageWarn}`)

    let allOk = true
    for (const name of REQUIRED_DVN_NAMES) {
        const addr = resolveDvnAddress(metadata, target.chainKey, name)
        if (!addr) {
            console.log(`  ✗ DVN "${name}" not found in LZ metadata for ${target.chainKey}`)
            allOk = false
            continue
        }
        const r = await probeDvn(provider, addr)
        if (r.ok) {
            console.log(`  ✓ DVN "${name}" @ ${addr}: ${r.codeBytes} bytes, quorum=${r.quorum}`)
        } else {
            console.log(`  ✗ DVN "${name}" @ ${addr}: ${r.error}`)
            allOk = false
        }
    }
    return allOk
}

;(async () => {
    console.log(`Fetching LayerZero DVN metadata: ${METADATA_URL}`)
    let md
    try {
        md = await fetchMetadata()
    } catch (e) {
        console.error(`FATAL: ${e.message}`)
        process.exit(1)
    }

    let allOk = true
    for (const t of TARGETS) {
        const ok = await checkChain(t, md)
        allOk = allOk && ok
    }

    console.log('')
    if (!allOk) {
        console.error('FAILED: one or more required DVNs are not reachable. Do not proceed with deploy.')
        process.exit(1)
    }
    console.log('All required DVNs are reachable on BSC and Ethereum mainnet.')
})()
