// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Declared at file level, not nested in the vault, so `SettlementLib` can take storage
///      pointers to them. Field order and types are byte-identical to the layout deployed
///      behind the live proxy and must not be reordered. Append only.
struct PairConfig {
    address stockToken;
    address usdg;
    address stockAccount;
    address usdgAccount;
    uint128 maxPairValueUSDG;
    uint128 maxSettlementSwapUSDG;
    uint64 maxCheckpointAge;
    // Retained only to preserve the proxy storage layout. Must remain zero.
    uint32 deprecatedMinDeadlineDelay;
    uint32 maxDeadlineDelay;
    uint16 reserveFeeBps;
    uint16 maxSwapSlippageBps;
    uint16 withdrawOverUnwindBps;
    uint8 stockDecimals;
    uint8 usdgDecimals;
    bool allocationPaused;
    bool swapsPaused;
    bool emergencyMode;
    bool exists;
}

struct PairLedger {
    uint256 stockPrincipal;
    uint256 usdgPrincipal;
    uint256 stockIdle;
    uint256 usdgIdle;
    uint256 cumulativeLossUSDG;
    uint64 lastCheckpoint;
}
