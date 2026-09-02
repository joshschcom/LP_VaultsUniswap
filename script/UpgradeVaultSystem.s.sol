// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { RobinhoodBoostedVault } from "../src/RobinhoodBoostedVault.sol";
import { StockOracleGuard } from "../src/StockOracleGuard.sol";
import { UniswapV4PairedAdapter } from "../src/UniswapV4PairedAdapter.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";

/**
 * @notice Deploys the replacement implementations and prints the ordered timelock payloads
 *         for the settlement-library, oracle-priced-valuation and split-deviation upgrade.
 * @dev Ordering is not cosmetic. The new vault calls `positionStateAt` on the adapter and
 *      `validateRemovalPrice` on the guard, so both must already be live when it goes in, or
 *      every checkpoint and withdrawal reverts. The old vault only calls functions that
 *      survive those two upgrades, so the intermediate states are safe in both directions.
 *
 *      Set `NEW_ADAPTER_IMPL`, `NEW_ORACLE_IMPL` and `NEW_VAULT_IMPL` to skip deployment and
 *      only reprint the payloads for an already-reviewed set of implementations.
 */
contract UpgradeVaultSystem is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    bytes32 internal constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    uint256 internal constant REMOVAL_OPERATIONAL_BUFFER_BPS = 100;

    /// @dev The `FeedConfig` shape deployed before the split-deviation upgrade.
    struct LegacyFeedConfig {
        address stockToken;
        address usdg;
        IAggregatorV3 stockFeed;
        IAggregatorV3 usdgFeed;
        IAggregatorV3 sequencerFeed;
        bytes32 poolId;
        uint64 maxStaleness;
        uint64 sequencerGracePeriod;
        uint16 maxPriceDeviationBps;
        uint8 stockDecimals;
        uint8 usdgDecimals;
        uint8 stockFeedDecimals;
        uint8 usdgFeedDecimals;
        bool usdgFixedOne;
        bool enabled;
    }

    struct Proxies {
        address vault;
        address oracle;
        address adapter;
    }

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "WRONG_CHAIN");
        address timelock = vm.envAddress("TIMELOCK");
        require(timelock.code.length != 0, "TIMELOCK_NOT_CONTRACT");

        Proxies memory p = Proxies({
            vault: vm.envAddress("VAULT_PROXY"),
            oracle: vm.envAddress("ORACLE_PROXY"),
            adapter: vm.envAddress("ADAPTER_PROXY")
        });
        require(p.vault.code.length != 0, "VAULT_NOT_CONTRACT");
        require(p.oracle.code.length != 0, "ORACLE_NOT_CONTRACT");
        require(p.adapter.code.length != 0, "ADAPTER_NOT_CONTRACT");

        // Every upgrade in this batch is authorized by the timelock through the proxy's own
        // ProxyAdmin. Read each admin from the proxy rather than trusting an env var.
        address vaultAdmin = _proxyAdmin(p.vault, timelock);
        address oracleAdmin = _proxyAdmin(p.oracle, timelock);
        address adapterAdmin = _proxyAdmin(p.adapter, timelock);

        (address adapterImpl, address oracleImpl, address vaultImpl) = _implementations();
        _assertRemovalBoundIsCoverable(p.oracle);

        console2.log("--- replacement implementations ---");
        console2.log("adapter implementation", adapterImpl);
        console2.log("oracle implementation", oracleImpl);
        console2.log("vault implementation", vaultImpl);
        console2.log("");
        console2.log("Schedule in this order, chaining each TIMELOCK_PREDECESSOR to the");
        console2.log("previous operation id. The vault must go last.");
        console2.log("");

        _printPayload(
            "1. upgrade adapter (adds positionStateAt)",
            adapterAdmin,
            abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(p.adapter), adapterImpl, "")
            )
        );
        _printPayload(
            "2. upgrade oracle guard (adds validateRemovalPrice)",
            oracleAdmin,
            abi.encodeCall(
                ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(p.oracle), oracleImpl, "")
            )
        );
        _printPayload(
            "3. upgrade vault (linked library, oracle-priced loss, split bound)",
            vaultAdmin,
            abi.encodeCall(
                ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(p.vault), vaultImpl, "")
            )
        );
        _printRemovalBoundPayload(p.oracle);
    }

    /// @dev Deploys the three replacements unless pinned implementations were supplied.
    function _implementations()
        internal
        returns (address adapterImpl, address oracleImpl, address vaultImpl)
    {
        adapterImpl = vm.envOr("NEW_ADAPTER_IMPL", address(0));
        oracleImpl = vm.envOr("NEW_ORACLE_IMPL", address(0));
        vaultImpl = vm.envOr("NEW_VAULT_IMPL", address(0));
        if (adapterImpl != address(0) || oracleImpl != address(0) || vaultImpl != address(0)) {
            require(
                adapterImpl.code.length != 0 && oracleImpl.code.length != 0
                    && vaultImpl.code.length != 0,
                "PINNED_IMPL_MISSING_CODE"
            );
            return (adapterImpl, oracleImpl, vaultImpl);
        }

        address deployer = vm.envAddress("DEPLOYER");
        require(deployer != address(0), "ZERO_DEPLOYER");
        // SettlementLib is unlinked here, so the broadcast deploys it ahead of the vault.
        // Nothing in this script depends on the deployer nonce, so that is safe.
        vm.startBroadcast(deployer);
        adapterImpl = address(new UniswapV4PairedAdapter());
        oracleImpl = address(new StockOracleGuard());
        vaultImpl = address(new RobinhoodBoostedVault());
        vm.stopBroadcast();
    }

    /**
     * @dev The removal bound is only checked against the adapter's removal tolerance at
     *      `registerPair`, and `removalToleranceBps` has no setter afterwards. Refuse to
     *      print a bound the already-registered pair's tolerance cannot absorb.
     */
    function _assertRemovalBoundIsCoverable(address oracleProxy) internal view {
        uint256 removalBound = vm.envOr("MAX_REMOVAL_DEVIATION_BPS", uint256(600));
        uint256 removalTolerance = vm.envUint("REGISTERED_REMOVAL_TOLERANCE_BPS");
        require(removalBound != 0, "ZERO_REMOVAL_BOUND");
        require(
            removalTolerance >= removalBound / 2 + REMOVAL_OPERATIONAL_BUFFER_BPS,
            "REMOVAL_TOLERANCE_TOO_TIGHT"
        );
        oracleProxy;
    }

    /// @dev Reads the live feed config and changes only the removal bound, so the reviewed
    ///      payload cannot silently restate staleness, deviation or sequencer policy.
    function _printRemovalBoundPayload(address oracleProxy) internal view {
        bytes32 pairId = vm.envBytes32("PAIR_ID");
        StockOracleGuard.FeedConfig memory config = _readFeedConfig(oracleProxy, pairId);
        require(config.stockToken != address(0), "PAIR_NOT_CONFIGURED");
        uint16 previous = config.maxRemovalDeviationBps;
        config.maxRemovalDeviationBps = uint16(vm.envOr("MAX_REMOVAL_DEVIATION_BPS", uint256(600)));
        console2.log("   previous removal bound bps", uint256(previous));
        console2.log("   new removal bound bps", uint256(config.maxRemovalDeviationBps));
        _printPayload(
            "4. set the exit deviation bound (allocation bound unchanged)",
            oracleProxy,
            abi.encodeCall(StockOracleGuard.configurePair, (pairId, config))
        );
    }

    /**
     * @dev The live guard still returns the pre-upgrade 15-field `FeedConfig`, so decoding it
     *      as the 16-field struct reverts. Dispatch on the returned length and widen the old
     *      shape, so all four payloads can be reviewed before any of them is scheduled rather
     *      than having to wait for operation 2 to execute before building operation 4.
     */
    function _readFeedConfig(address oracleProxy, bytes32 pairId)
        internal
        view
        returns (StockOracleGuard.FeedConfig memory config)
    {
        (bool ok, bytes memory data) =
            oracleProxy.staticcall(abi.encodeCall(StockOracleGuard.feedConfig, (pairId)));
        require(ok, "FEED_CONFIG_READ_FAILED");
        if (data.length == 16 * 32) return abi.decode(data, (StockOracleGuard.FeedConfig));
        require(data.length == 15 * 32, "UNEXPECTED_FEED_CONFIG_SHAPE");

        LegacyFeedConfig memory legacy = abi.decode(data, (LegacyFeedConfig));
        config.stockToken = legacy.stockToken;
        config.usdg = legacy.usdg;
        config.stockFeed = legacy.stockFeed;
        config.usdgFeed = legacy.usdgFeed;
        config.sequencerFeed = legacy.sequencerFeed;
        config.poolId = legacy.poolId;
        config.maxStaleness = legacy.maxStaleness;
        config.sequencerGracePeriod = legacy.sequencerGracePeriod;
        config.maxPriceDeviationBps = legacy.maxPriceDeviationBps;
        config.stockDecimals = legacy.stockDecimals;
        config.usdgDecimals = legacy.usdgDecimals;
        config.stockFeedDecimals = legacy.stockFeedDecimals;
        config.usdgFeedDecimals = legacy.usdgFeedDecimals;
        config.usdgFixedOne = legacy.usdgFixedOne;
        config.enabled = legacy.enabled;
        // maxRemovalDeviationBps is absent pre-upgrade and reads as the fallback zero.
    }

    function _proxyAdmin(address proxy, address expectedOwner) internal view returns (address) {
        address admin = address(uint160(uint256(vm.load(proxy, ERC1967_ADMIN_SLOT))));
        require(admin.code.length != 0, "PROXY_ADMIN_MISSING_CODE");
        require(ProxyAdmin(admin).owner() == expectedOwner, "PROXY_ADMIN_NOT_TIMELOCK");
        return admin;
    }

    function _printPayload(string memory label, address target, bytes memory data) internal pure {
        console2.log(label);
        console2.log("   target", target);
        console2.log("   value", uint256(0));
        console2.log("   calldata");
        console2.logBytes(data);
        console2.log("");
    }
}
