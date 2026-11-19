// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {CrestFactory} from "../src/CrestFactory.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {HoldbackModule} from "../src/modules/holdback/HoldbackModule.sol";
import {CrestBase} from "./CrestBase.sol";

/// The deploy script with the RPC's answer, the local rules contract and the record's path set by the test, so no
/// test here reads an RPC or an environment variable another suite sets.
contract DeployHarness is Deploy {
    uint256 public chain = 31_337;
    HoldbackRules public localRules;

    function set(uint256 chain_, HoldbackRules localRules_) external {
        (chain, localRules) = (chain_, localRules_);
    }

    /// In a test it answers with `chain`; run any other way, as a script, it asks the RPC as `Deploy` does.
    function rpcChainId() public override returns (uint256) {
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) return super.rpcChainId();
        return chain;
    }

    function rulesFor(uint256 chainId) public view override returns (HoldbackRules) {
        return chainId == 11_155_111 ? super.rulesFor(chainId) : localRules;
    }

    function recordPath(uint256) public pure override returns (string memory) {
        return "deployments/rehearsal-harness.json";
    }
}

/// The deploy script on Holdback's test world: it deploys at the CREATE2 addresses its code gives, checks itself,
/// completes a partial deploy on a rerun, records only what is on chain, refuses every chain but Sepolia and a local
/// one on every public path, and what it deploys pays a deal.
contract DeployTest is CrestBase {
    DeployHarness internal script;

    function setUp() public override {
        super.setUp();
        script = new DeployHarness();
        script.set(31_337, rules);
    }

    function test_theScriptDeploysAndChecks_andAVaultFromItPaysADeal() public {
        (CrestFactory f, HoldbackModule m) = script.run();
        (CrestFactory pf, HoldbackModule pm) = script.addresses(rules);
        assertEq(address(f), address(pf));
        assertEq(address(m), address(pm));
        CrestVault v = CrestVault(f.create(principal, address(usdc), bytes32("deployed")));
        vm.startPrank(principal);
        v.setModule(address(m), m.payee(), "the deployed module");
        uint256 g = v.grant(ROOT, buyer, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true), 0, "");
        v.allow(g, m.counterpartyOf(seller, adjudicator, fallbackAdj, appealAdj), true, "");
        vm.stopPrank();
        usdc.mint(address(v), HOLD);
        H.Terms memory t = _vterms(address(v), buyer);
        bytes32 id = m.agreeAndFund(
            t,
            _sellerSig(t, SELLER_PK),
            _acceptance(t, ADJ_PK),
            _agree(t, BUYER_PK),
            H.Funding({signature: new bytes(65)})
        );
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
    }

    /// A deploy that stopped after the factory: the rerun creates only the module.
    function test_aRerunAfterAPartialDeploy_createsOnlyWhatIsMissing() public {
        (CrestFactory pf, HoldbackModule pm) = script.addresses(rules);
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(keccak256("crest v01"), type(CrestFactory).creationCode));
        assertTrue(ok);
        assertGt(address(pf).code.length, 0);
        assertEq(address(pm).code.length, 0);
        (CrestFactory f, HoldbackModule m) = script.run();
        assertEq(address(f), address(pf));
        assertEq(address(m), address(pm));
        assertGt(address(pm).code.length, 0);
    }

    function test_aRerunDeploysNothingAgain_andReturnsTheSameContracts() public {
        (CrestFactory f, HoldbackModule m) = script.run();
        (CrestFactory f2, HoldbackModule m2) = script.run();
        assertEq(address(f2), address(f));
        assertEq(address(m2), address(m));
    }

    function test_verify_refusesBeforeTheDeploy_andRecordsAfterIt() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.CheckFailed.selector, "no factory at its address"));
        script.verify();
        (CrestFactory f, HoldbackModule m) = script.run();
        script.verify();
        string memory path = script.recordPath(31_337);
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 31_337);
        assertEq(vm.parseJsonAddress(json, ".rules"), address(rules));
        assertEq(vm.parseJsonAddress(json, ".factory"), address(f));
        assertEq(vm.parseJsonAddress(json, ".implementation"), f.IMPLEMENTATION());
        assertEq(vm.parseJsonAddress(json, ".holdbackModule"), address(m));
        vm.removeFile(path);
    }

    /// With no RPC the script cannot learn the chain, so neither public path deploys.
    function test_attack_withoutAnRpc_refused() public {
        Deploy real = new Deploy();
        vm.expectRevert();
        real.run();
        vm.expectRevert();
        real.deploy(rules);
    }

    function test_attack_onMainnet_everyPathRefused() public {
        script.set(1, rules);
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.run();
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.deploy(rules);
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.verify();
    }

    function test_attack_onSepolia_aRulesContractOutsideHoldbacksRecord_refused() public {
        script.set(11_155_111, rules);
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.CheckFailed.selector, "not the rules contract in Holdback's Sepolia record")
        );
        script.deploy(rules);
    }

    function test_attack_deployAgainstAnAddressWithNoCode_refused() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.CheckFailed.selector, "no rules contract at HOLDBACK_RULES"));
        script.deploy(HoldbackRules(makeAddr("not a rules contract")));
    }
}
