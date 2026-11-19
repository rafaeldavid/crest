// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackRules} from "holdback/HoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {CrestFactory} from "../src/CrestFactory.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {HoldbackModule} from "../src/modules/holdback/HoldbackModule.sol";
import {CrestBase} from "./CrestBase.sol";

/// The deploy script on Holdback's test world: it deploys, checks itself, refuses a mainnet chain, and what it deploys
/// pays a deal.
contract DeployTest is CrestBase {
    Deploy internal script;

    function setUp() public override {
        super.setUp();
        script = new Deploy();
    }

    function test_theScriptDeploysAndChecks_andAVaultFromItPaysADeal() public {
        (CrestFactory f, HoldbackModule m) = script.deploy(rules, 31_337);
        script.check(f, m, rules);
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

    /// With no RPC the script cannot learn the chain, so it deploys nothing.
    function test_attack_runWithoutAnRpc_refused() public {
        vm.setEnv("HOLDBACK_RULES", vm.toString(address(rules)));
        vm.expectRevert();
        script.run();
    }

    function test_attack_deployOnMainnet_refused() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.deploy(rules, 1);
    }

    function test_attack_deployAgainstAnAddressWithNoCode_refused() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.CheckFailed.selector, "no rules contract at HOLDBACK_RULES"));
        script.deploy(HoldbackRules(makeAddr("not a rules contract")), 31_337);
    }
}
