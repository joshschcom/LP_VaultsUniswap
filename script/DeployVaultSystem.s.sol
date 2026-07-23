// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IAllowanceTransfer } from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";

import { RobinhoodBoostedVault } from "../src/RobinhoodBoostedVault.sol";
import { StockOracleGuard } from "../src/StockOracleGuard.sol";
import { StrategyLossReserve } from "../src/StrategyLossReserve.sol";
import { UniswapV4PairedAdapter } from "../src/UniswapV4PairedAdapter.sol";
import { IStockOracleGuard } from "../src/interfaces/IStockOracleGuard.sol";
import { IStrategyLossReserve } from "../src/interfaces/IStrategyLossReserve.sol";
import { IUniswapV4PairedAdapter } from "../src/interfaces/IUniswapV4PairedAdapter.sol";
import { PeridotTransparentProxy } from "../src/proxy/PeridotTransparentProxy.sol";

contract DeployVaultSystem is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external {
        if (block.chainid != ROBINHOOD_CHAIN_ID) revert("WRONG_CHAIN");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address timelock = vm.envAddress("TIMELOCK");
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envAddress("GUARDIAN");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address deployer = vm.addr(deployerKey);
        _requireContract(poolManager);
        _requireContract(positionManager);
        _requireContract(universalRouter);
        _requireContract(permit2);

        // Four implementations are created first, followed by the four proxies. Their
        // addresses are deterministic from the broadcaster nonce, so circular references
        // can be encoded into each proxy's constructor initializer without ever exposing
        // an uninitialized proxy between broadcast transactions.
        uint256 firstNonce = vm.getNonce(deployer);
        address expectedVaultProxy = vm.computeCreateAddress(deployer, firstNonce + 4);
        address expectedOracleProxy = vm.computeCreateAddress(deployer, firstNonce + 5);
        address expectedReserveProxy = vm.computeCreateAddress(deployer, firstNonce + 6);
        address expectedAdapterProxy = vm.computeCreateAddress(deployer, firstNonce + 7);

        vm.startBroadcast(deployerKey);
        RobinhoodBoostedVault vaultImpl = new RobinhoodBoostedVault();
        StockOracleGuard oracleImpl = new StockOracleGuard();
        StrategyLossReserve reserveImpl = new StrategyLossReserve();
        UniswapV4PairedAdapter adapterImpl = new UniswapV4PairedAdapter();

        bytes memory vaultInit = abi.encodeCall(
            RobinhoodBoostedVault.initialize,
            (
                timelock,
                keeper,
                guardian,
                IStockOracleGuard(expectedOracleProxy),
                IStrategyLossReserve(expectedReserveProxy),
                IUniswapV4PairedAdapter(expectedAdapterProxy)
            )
        );
        bytes memory oracleInit =
            abi.encodeCall(StockOracleGuard.initialize, (timelock, IPoolManager(poolManager)));
        bytes memory reserveInit =
            abi.encodeCall(StrategyLossReserve.initialize, (timelock, expectedVaultProxy));
        bytes memory adapterInit = abi.encodeCall(
            UniswapV4PairedAdapter.initialize,
            (
                expectedVaultProxy,
                IPoolManager(poolManager),
                IPositionManager(positionManager),
                IUniversalRouter(universalRouter),
                IAllowanceTransfer(permit2)
            )
        );

        PeridotTransparentProxy vaultProxy =
            new PeridotTransparentProxy(address(vaultImpl), timelock, vaultInit);
        PeridotTransparentProxy oracleProxy =
            new PeridotTransparentProxy(address(oracleImpl), timelock, oracleInit);
        PeridotTransparentProxy reserveProxy =
            new PeridotTransparentProxy(address(reserveImpl), timelock, reserveInit);
        PeridotTransparentProxy adapterProxy =
            new PeridotTransparentProxy(address(adapterImpl), timelock, adapterInit);
        vm.stopBroadcast();

        require(address(vaultProxy) == expectedVaultProxy, "VAULT_PROXY_ADDRESS");
        require(address(oracleProxy) == expectedOracleProxy, "ORACLE_PROXY_ADDRESS");
        require(address(reserveProxy) == expectedReserveProxy, "RESERVE_PROXY_ADDRESS");
        require(address(adapterProxy) == expectedAdapterProxy, "ADAPTER_PROXY_ADDRESS");

        console2.log("Vault implementation", address(vaultImpl));
        console2.log("Vault proxy", address(vaultProxy));
        console2.log("Oracle proxy", address(oracleProxy));
        console2.log("Reserve proxy", address(reserveProxy));
        console2.log("Adapter proxy", address(adapterProxy));
        console2.log("Proxy owner / timelock", timelock);
    }

    function _requireContract(address target) internal view {
        require(target != address(0) && target.code.length != 0, "MISSING_CODE");
    }
}
