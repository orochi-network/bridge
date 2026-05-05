#!/usr/bin/env node
// scripts/check-bytecode.js
//
// Cross-toolchain bytecode determinism check.
//
// Both Hardhat and Foundry must produce identical *runtime* bytecode for the
// production contracts. The CBOR metadata trailer at the tail of each artifact
// embeds an IPFS hash of the compiler metadata JSON, which legitimately
// differs between the two toolchains because they resolve source paths and
// remappings differently. The runtime semantics (everything before the
// trailer) MUST match exactly — that is what gets executed on chain.
//
// This script:
//   1. Loads the `deployedBytecode` for each production contract from both
//      `artifacts/` (Hardhat) and `out/` (Foundry).
//   2. Strips the CBOR metadata trailer using its self-describing length
//      (last 2 bytes, big-endian).
//   3. Asserts the stripped bytecode is byte-identical between toolchains.
//   4. Reports the metadata-hash divergence informationally — that is
//      expected and not a failure, but a sudden change is worth knowing
//      about because it may indicate a settings drift.
//
// Exit code 0 on success, 1 on any runtime mismatch.

const fs = require('fs')
const path = require('path')

const ROOT = path.resolve(__dirname, '..')

// Production contracts. Add new entries here when shipping more contracts.
const CONTRACTS = ['ONOFTAdapter', 'WrappedON']

function readJson(p) {
    return JSON.parse(fs.readFileSync(p, 'utf8'))
}

function loadHardhat(contract) {
    const p = path.join(ROOT, 'artifacts/contracts', `${contract}.sol`, `${contract}.json`)
    if (!fs.existsSync(p)) throw new Error(`Hardhat artifact missing: ${p}. Run \`yarn compile:hardhat\` first.`)
    const j = readJson(p)
    return j.deployedBytecode
}

function loadFoundry(contract) {
    const p = path.join(ROOT, 'out', `${contract}.sol`, `${contract}.json`)
    if (!fs.existsSync(p)) throw new Error(`Foundry artifact missing: ${p}. Run \`yarn compile:forge\` first.`)
    const j = readJson(p)
    // Foundry wraps deployedBytecode in `{ object, sourceMap, ... }`.
    return j.deployedBytecode.object || j.deployedBytecode
}

// Strip the Solidity CBOR metadata trailer.
// Layout: `... <metadata_bytes> <2-byte big-endian metadata length>`
// The last 2 bytes (4 hex chars) are the length of the metadata blob.
function stripMetadata(hex) {
    const h = hex.startsWith('0x') ? hex.slice(2) : hex
    if (h.length < 4) return h
    const metaLen = parseInt(h.slice(-4), 16)
    if (!Number.isFinite(metaLen) || metaLen <= 0) return h
    const stripChars = (metaLen + 2) * 2
    if (stripChars > h.length) return h
    return h.slice(0, h.length - stripChars)
}

// Extract the IPFS hash from the CBOR trailer for diagnostic reporting.
// CBOR map entry for ipfs is: `64 69 70 66 73` (text "ipfs"), then `58 22` (bytes(34)),
// then a 34-byte multihash whose first 2 bytes are `12 20` (sha2-256, 32 bytes), then 32 bytes of digest.
function extractIpfsHash(hex) {
    const h = hex.startsWith('0x') ? hex.slice(2) : hex
    const marker = '64697066735822' // "ipfs" + bytes(34)
    const idx = h.lastIndexOf(marker)
    if (idx < 0) return null
    return h.slice(idx + marker.length, idx + marker.length + 68) // 34 bytes
}

function main() {
    let failed = 0
    for (const c of CONTRACTS) {
        const hh = loadHardhat(c)
        const ff = loadFoundry(c)
        const hhStripped = stripMetadata(hh)
        const ffStripped = stripMetadata(ff)
        const runtimeMatch = hhStripped === ffStripped
        const hhHash = extractIpfsHash(hh)
        const ffHash = extractIpfsHash(ff)

        console.log(`=== ${c} ===`)
        console.log(`  hardhat runtime: ${hhStripped.length / 2} bytes`)
        console.log(`  foundry runtime: ${ffStripped.length / 2} bytes`)
        if (runtimeMatch) {
            console.log(`  ✓ runtime bytecode IDENTICAL`)
        } else {
            console.log(`  ✗ runtime bytecode MISMATCH`)
            failed++
        }
        if (hhHash && ffHash) {
            const tag = hhHash === ffHash ? '✓ identical' : 'differs (expected — path-dependent metadata)'
            console.log(`  ipfs metadata hash: ${tag}`)
            console.log(`    hardhat: ${hhHash}`)
            console.log(`    foundry: ${ffHash}`)
        }
        console.log('')
    }

    if (failed > 0) {
        console.error(`FAILED: ${failed} contract(s) have divergent runtime bytecode.`)
        console.error('Toolchain settings have drifted. Re-check optimizer runs, evmVersion, and solc version.')
        process.exit(1)
    }
    console.log('All contracts: runtime bytecode matches across Hardhat and Foundry.')
}

main()
