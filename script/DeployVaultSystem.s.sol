// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
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
    bytes32 internal constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

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
        _requireContract(timelock);
        _validateTimelock(TimelockController(payable(timelock)));
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

        address vaultProxyAdmin = _validateProxyAdmin(address(vaultProxy), timelock);
        address oracleProxyAdmin = _validateProxyAdmin(address(oracleProxy), timelock);
        address reserveProxyAdmin = _validateProxyAdmin(address(reserveProxy), timelock);
        address adapterProxyAdmin = _validateProxyAdmin(address(adapterProxy), timelock);

        console2.log("Vault implementation", address(vaultImpl));
        console2.log("Oracle implementation", address(oracleImpl));
        console2.log("Reserve implementation", address(reserveImpl));
        console2.log("Adapter implementation", address(adapterImpl));
        console2.log("Vault proxy", address(vaultProxy));
        console2.log("Oracle proxy", address(oracleProxy));
        console2.log("Reserve proxy", address(reserveProxy));
        console2.log("Adapter proxy", address(adapterProxy));
        console2.log("Vault ProxyAdmin", vaultProxyAdmin);
        console2.log("Oracle ProxyAdmin", oracleProxyAdmin);
        console2.log("Reserve ProxyAdmin", reserveProxyAdmin);
        console2.log("Adapter ProxyAdmin", adapterProxyAdmin);
        console2.log("Proxy owner / timelock", timelock);
    }

    function _requireContract(address target) internal view {
        require(target != address(0) && target.code.length != 0, "MISSING_CODE");
    }

    function _validateTimelock(TimelockController timelock) internal view {
        uint256 expectedDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        require(expectedDelay >= 1 hours, "TIMELOCK_DELAY_TOO_SHORT");
        require(timelock.getMinDelay() == expectedDelay, "TIMELOCK_DELAY_MISMATCH");
        require(timelock.hasRole(adminRole, address(timelock)), "TIMELOCK_NOT_SELF_ADMIN");
    }

    function _validateProxyAdmin(address proxy, address expectedOwner)
        internal
        view
        returns (address proxyAdmin)
    {
        proxyAdmin = address(uint160(uint256(vm.load(proxy, ERC1967_ADMIN_SLOT))));
        _requireContract(proxyAdmin);
        require(ProxyAdmin(proxyAdmin).owner() == expectedOwner, "PROXY_ADMIN_OWNER");
    }
}
