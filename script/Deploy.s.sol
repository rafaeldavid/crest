// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";

import {CrestFactory} from "../src/CrestFactory.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {HoldbackModule} from "../src/modules/holdback/HoldbackModule.sol";

/// @title Deploy
/// @notice Deploys Crest on a test network: the factory, whose constructor deploys the vault implementation, and the
///         Holdback module for one Holdback rules deployment, both through the public CREATE2 deployer so their
///         addresses follow from the code alone. Refuses any chain but Sepolia and a local chain. `run` deploys
///         whatever is not yet at its address and checks it all; `verify`, run without `--broadcast` once the deploy
///         is mined, checks the contracts the chain holds and only then writes `deployments/<chain id>.json`.
/// @dev The chain is the one the RPC answers for, which is where forge signs and sends. Forge's simulated
///      `block.chainid` reads `chain_id` from foundry.toml (31337) whatever the RPC, so the script never trusts it
///      [measured, 2026-11-19, forge 1.0.0]. On Sepolia the rules contract is the one in Holdback's own record at the
///      commit the submodule pins; on a local chain it is `HOLDBACK_RULES`. `CREST_RECORD`, optional, moves the
///      record, so a rehearsal never writes `deployments/11155111.json`.
contract Deploy is Script {
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant LOCAL = 31_337;
    bytes32 internal constant SALT = keccak256("crest v01");
    string internal constant HOLDBACK_SEPOLIA_RECORD = "lib/holdback/contracts/deployments/sepolia.json";

    error NotATestNetwork(uint256 chainId);
    error CheckFailed(string what);

    function run() external returns (CrestFactory factory, HoldbackModule module) {
        return deploy(rulesFor(rpcChainId()));
    }

    function verify() external returns (CrestFactory factory, HoldbackModule module) {
        uint256 chainId = _testNetwork();
        HoldbackRules rules = rulesFor(chainId);
        (factory, module) = addresses(rules);
        check(factory, module, rules);
        _record(factory, module, chainId);
    }

    /// @notice Deploys whatever is not yet at its address, so a rerun completes a partial deploy, then checks it all.
    function deploy(HoldbackRules rules) public returns (CrestFactory factory, HoldbackModule module) {
        uint256 chainId = _testNetwork();
        if (address(rules).code.length == 0) revert CheckFailed("no rules contract at HOLDBACK_RULES");
        if (chainId == SEPOLIA && address(rules) != address(rulesFor(SEPOLIA))) {
            revert CheckFailed("not the rules contract in Holdback's Sepolia record");
        }
        (factory, module) = addresses(rules);
        vm.startBroadcast();
        if (address(factory).code.length == 0 && address(new CrestFactory{salt: SALT}()) != address(factory)) {
            revert CheckFailed("the factory is not at its CREATE2 address");
        }
        if (address(module).code.length == 0 && address(new HoldbackModule{salt: SALT}(rules)) != address(module)) {
            revert CheckFailed("the module is not at its CREATE2 address");
        }
        vm.stopBroadcast();
        check(factory, module, rules);
    }

    /// @notice The chain ID the RPC answers. Reverts without an RPC, so a run with none deploys nothing.
    function rpcChainId() public virtual returns (uint256 id) {
        bytes memory answer = vm.rpc("eth_chainId", "[]");
        if (answer.length == 0 || answer.length > 32) revert NotATestNetwork(0);
        for (uint256 i; i < answer.length; ++i) {
            id = (id << 8) | uint8(answer[i]);
        }
    }

    function rulesFor(uint256 chainId) public view virtual returns (HoldbackRules) {
        if (chainId == SEPOLIA) {
            return HoldbackRules(vm.parseJsonAddress(vm.readFile(HOLDBACK_SEPOLIA_RECORD), ".rules"));
        }
        return HoldbackRules(vm.envOr("HOLDBACK_RULES", address(0)));
    }

    /// @notice Where the factory and the module for `rules` are, or will be.
    function addresses(HoldbackRules rules) public pure returns (CrestFactory factory, HoldbackModule module) {
        bytes memory moduleCode = abi.encodePacked(type(HoldbackModule).creationCode, abi.encode(rules));
        factory = CrestFactory(vm.computeCreate2Address(SALT, keccak256(type(CrestFactory).creationCode)));
        module = HoldbackModule(vm.computeCreate2Address(SALT, keccak256(moduleCode)));
    }

    /// @notice Reverts unless both contracts hold code, the factory's implementation is the uninitializable vault
    ///         code, and the module points at this rules deployment, its escrow and its ERC-3009 collector.
    function check(CrestFactory factory, HoldbackModule module, HoldbackRules rules) public view {
        if (address(factory).code.length == 0) revert CheckFailed("no factory at its address");
        if (address(module).code.length == 0) revert CheckFailed("no module at its address");
        CrestVault implementation = CrestVault(factory.IMPLEMENTATION());
        if (address(implementation).code.length == 0) revert CheckFailed("the implementation has no code");
        if (implementation.principal() != address(1)) revert CheckFailed("the implementation can be initialized");
        if (address(module.RULES()) != address(rules)) revert CheckFailed("the module names another rules contract");
        if (module.payee() != rules.ERC3009_COLLECTOR()) revert CheckFailed("the module pays another collector");
        if (module.escrow() != address(rules.ESCROW())) revert CheckFailed("the module names another escrow");
    }

    function recordPath(uint256 chainId) public view virtual returns (string memory) {
        return vm.envOr("CREST_RECORD", string.concat("deployments/", vm.toString(chainId), ".json"));
    }

    function _testNetwork() internal returns (uint256 chainId) {
        chainId = rpcChainId();
        if (chainId != SEPOLIA && chainId != LOCAL) revert NotATestNetwork(chainId);
    }

    function _record(CrestFactory factory, HoldbackModule module, uint256 chainId) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", chainId);
        vm.serializeAddress(o, "rules", address(module.RULES()));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "implementation", factory.IMPLEMENTATION());
        vm.serializeAddress(o, "holdbackModule", address(module));
        vm.serializeBytes32(o, "salt", SALT);
        string memory json = vm.serializeUint(o, "checkedAtBlock", block.number);
        vm.writeJson(json, recordPath(chainId));
        console2.log("chainId", chainId);
        console2.log("factory", address(factory));
        console2.log("implementation", factory.IMPLEMENTATION());
        console2.log("holdbackModule", address(module));
    }
}
