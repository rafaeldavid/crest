// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {CrestFactory} from "../../src/CrestFactory.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {HoldbackModule} from "../../src/modules/holdback/HoldbackModule.sol";

/// Which chain the deploy script deploys to. Forge simulates a script with `block.chainid` 31337 from foundry.toml
/// whatever the RPC, and signs for the chain the RPC answers, so the script asks the RPC. Each suite runs only when
/// its RPC variable is set; skipped otherwise, as in CI. No suite sets an environment variable another one reads.
abstract contract ChainGuardBase is Test {
    function _forkOrSkip(string memory variable) internal {
        string memory url = vm.envOr(variable, string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // A public Sepolia node can lag at its head; `CREST_FORK_BLOCK` forks its suites at a block behind it.
        uint256 at =
            keccak256(bytes(variable)) == keccak256("CREST_FORK_URL") ? vm.envOr("CREST_FORK_BLOCK", uint256(0)) : 0;
        if (at == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, at);
        vm.chainId(31_337);
    }
}

/// `CREST_FORK_URL`: a fork of Sepolia. The script runs as forge runs it: `run` deploys against the rules contract in
/// Holdback's pinned record, a rerun deploys nothing, and `verify` records Sepolia and the CREATE2 addresses.
contract DeployOnSepoliaTest is ChainGuardBase {
    HoldbackRules internal RULES;

    function setUp() public {
        _forkOrSkip("CREST_FORK_URL");
        RULES =
            HoldbackRules(vm.parseJsonAddress(vm.readFile("lib/holdback/contracts/deployments/sepolia.json"), ".rules"));
    }

    function test_onSepolia_runDeploys_rerunIsANoop_andVerifyRecordsIt() public {
        string memory path = "deployments/rehearsal-11155111.json";
        vm.setEnv("CREST_RECORD", path);
        Deploy script = new Deploy();
        (CrestFactory f, HoldbackModule m) = script.run();
        (CrestFactory f2, HoldbackModule m2) = script.run();
        assertEq(address(f2), address(f));
        assertEq(address(m2), address(m));
        script.verify();
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 11_155_111);
        assertEq(vm.parseJsonAddress(json, ".rules"), address(RULES));
        assertEq(vm.parseJsonAddress(json, ".factory"), address(f));
        assertEq(vm.parseJsonAddress(json, ".implementation"), f.IMPLEMENTATION());
        assertEq(vm.parseJsonAddress(json, ".holdbackModule"), address(m));
        assertEq(vm.parseJsonAddress(json, ".allowList"), address(script.allowListAddress()));
        assertGt(address(script.allowListAddress()).code.length, 0, "the default list is deployed");
        vm.removeFile(path);
        bytes32 salt = keccak256("crest v01");
        bytes memory moduleCode = abi.encodePacked(type(HoldbackModule).creationCode, abi.encode(RULES, true));
        // The fee the script reads from `CREST_FEE_BPS` and `CREST_FEE_SWEEPER`, so the rehearsal runs with the real
        // deploy's settings when they are set.
        (uint256 feeBps, address feeSweeper) = script.feeOf();
        assertEq(ICrestVault(f.IMPLEMENTATION()).FEE_BPS(), feeBps);
        assertEq(ICrestVault(f.IMPLEMENTATION()).FEE_SWEEPER(), feeSweeper);
        bytes memory factoryInit = abi.encodePacked(type(CrestFactory).creationCode, abi.encode(feeBps, feeSweeper));
        assertEq(address(f), vm.computeCreate2Address(salt, keccak256(factoryInit)));
        assertEq(address(m), vm.computeCreate2Address(salt, keccak256(moduleCode)));
    }
}

/// `CREST_CHAIN1_URL`: an RPC that answers chain ID 1, as mainnet does (`anvil --chain-id 1` stands in). Every public
/// path refuses before anything is sent, a direct `deploy` with Sepolia's rules contract included.
contract DeployOnChainOneTest is ChainGuardBase {
    function setUp() public {
        _forkOrSkip("CREST_CHAIN1_URL");
    }

    function test_attack_everyPathAgainstChainOne_refused() public {
        Deploy script = new Deploy();
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.run();
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.deploy(HoldbackRules(makeAddr("Sepolia's rules contract")));
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.verify();
    }
}
