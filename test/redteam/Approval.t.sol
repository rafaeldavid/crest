// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {HoldbackModule} from "../../src/modules/holdback/HoldbackModule.sol";
import {RedTeamBase, RogueOperator} from "./RedTeamBase.sol";

/// Red team: reusing or widening the vault's one ERC-3009 approval inside one transaction.
///
/// Forge runs a test function as one transaction, so transient storage written by `charge` stays set for the rest of
/// the test: these tests model "the rest of the transaction" exactly. Every `test_attack_*` passes when the defence
/// holds and fails when the attack works.
contract RedTeamApprovalTest is RedTeamBase {
    RogueOperator internal rogue;

    function setUp() public override {
        super.setUp();
        vm.prank(buyer); // the agent deploys its own operator contract
        rogue = new RogueOperator(escrow);
    }

    /// In one transaction the agent's operator relays an honest funding through the module, then presents its own
    /// payment record naming the vault as payer and the agent's key as receiver, with the deal's amount, deadline,
    /// expiries and salt. It tries it as an authorization and as a one-step charge.
    function test_attack_agentsOwnOperatorPaysTheAgentFromTheVaultInTheSameTransaction_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory relayed = _fundCall(t, BUYER_PK);
        AuthCaptureEscrow.PaymentInfo memory pi = _piAs(t, address(rogue), buyer);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 agentBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        bool paid = rogue.relayThenPay(address(module), relayed, pi, address(collector3009), new bytes(65));

        assertFalse(paid, "another operator's payment record drew on the vault");
        assertEq(vaultBefore - usdc.balanceOf(address(vault)), HOLD, "only the agent's hold left the vault");
        assertEq(usdc.balanceOf(buyer), agentBefore, "the agent's key received nothing");
        assertEq(uint8(_stage(hx.id(t))), uint8(IHoldbackRules.Stage.Held), "the honest funding landed");
    }

    /// The approval outlives the funding until the transaction ends. Spending it again needs the same ERC-3009 nonce,
    /// which the token marked used; and a payment record that hashes to that nonce names the rules contract as its
    /// operator, which only the rules contract can present.
    function test_attack_spendTheLingeringApprovalASecondTime_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        _fundVia(t, BUYER_PK);
        AuthCaptureEscrow.PaymentInfo memory pi = _pi(t);
        bytes32 digest = _collectorDigest(pi);

        vm.prank(address(usdc));
        assertEq(vault.isValidSignature(digest, ""), MAGIC_1271, "observed: the approval lasts for the transaction");

        // Even the collector itself cannot pull the same authorization twice.
        bytes32 nonce = _nonceOf(pi);
        vm.prank(address(collector3009));
        vm.expectRevert(bytes("MockERC3009: authorization is used"));
        usdc.receiveWithAuthorization(address(vault), address(collector3009), HOLD, 0, t.timing.fundBy, nonce, "");

        // Another operator cannot present the rules contract's record.
        vm.expectRevert(
            abi.encodeWithSelector(AuthCaptureEscrow.InvalidSender.selector, address(rogue), address(rules))
        );
        rogue.authorize(pi, address(collector3009), new bytes(65));
        assertEq(_grantOf(vault, agentGrant).spent, HOLD);
    }

    /// A direct rules-contract funding for a vault-paid deal, with an ERC-6492 funding signature whose prepare hook
    /// calls the module's `agreeAndFund` for the same deal. The hook runs inside the escrow's `authorize`, after the
    /// vault answered nothing yet, hoping the nested charge approves the digest the outer collection then asks for.
    function test_attack_erc6492HookNestsTheModuleInsideADirectFunding_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        bytes memory nested = abi.encodeCall(module.agreeAndFund, (t, s, a, ag, H.Funding({signature: new bytes(65)})));
        bytes memory sig = _erc6492(address(module), nested, new bytes(65));

        vm.prank(stranger);
        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        rules.agreeAndFund(t, s, a, ag, H.Funding({signature: sig}));

        assertEq(_grantOf(vault, agentGrant).spent, 0, "nothing counted");
        assertEq(uint8(_stage(hx.id(t))), uint8(IHoldbackRules.Stage.None), "nothing funded");
    }

    /// The agent's operator presents its own payment record naming the vault, with an ERC-6492 signature whose hook
    /// runs an honest module funding of a real deal first, hoping the approval it leaves covers the outer record.
    function test_attack_erc6492HookNestsTheModuleInsideAnotherOperatorsPayment_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory sig = _erc6492(address(module), _fundCall(t, BUYER_PK), new bytes(65));
        AuthCaptureEscrow.PaymentInfo memory pi = _piAs(t, address(rogue), buyer);

        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        rogue.authorize(pi, address(collector3009), sig);

        assertEq(_grantOf(vault, agentGrant).spent, 0, "nothing counted");
        assertEq(uint8(_stage(hx.id(t))), uint8(IHoldbackRules.Stage.None), "the nested funding did not land either");
    }

    /// The module takes only 65-byte funding signatures to keep ERC-6492 hooks out. 65 bytes that end in the ERC-6492
    /// suffix still reach the collector's parser.
    function test_attack_a65ByteFundingSignatureEndingInTheErc6492Suffix_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        bytes memory sig = abi.encodePacked(bytes1(0x01), bytes32(0), ERC6492_MAGIC);
        assertEq(sig.length, 65);

        vm.expectRevert();
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: sig}));
        assertEq(_grantOf(vault, agentGrant).spent, 0, "nothing counted");
    }

    /// Terms whose hold does not fit the escrow's 120 bits: the module's nonce truncates the amount, so the vault's
    /// digest and the collector's would differ. The charge must not land without the funding. Paid from the root, which
    /// has no limits, so no limit refuses it first.
    function test_attack_termsWhoseHoldTheModuleTruncates_failClosed() public {
        H.Terms memory t = _vterms(address(vault), principal);
        t.price = type(uint120).max;
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, PRINCIPAL_PK);

        vm.expectRevert(IHoldbackRules.Unrepresentable.selector);
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        assertEq(_grantOf(vault, ROOT).spent, 0, "nothing counted");
        assertEq(_grantOf(vault, ROOT).open, 0);
    }

    /// The principal enables a second module on the same rules contract (a redeploy left both enabled). It cannot open the
    /// same deal a second time, nor release the first module's commitment.
    function test_attack_aSecondModuleOnTheSameRulesOpensOrReleasesTheSameDeal_refused() public {
        HoldbackModule second = new HoldbackModule(rules);
        address payee = second.payee();
        vm.prank(principal);
        vault.setModule(address(second), payee, "");
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);

        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        vm.expectRevert(ICrestVault.CommitmentOpen.selector);
        second.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));

        _release(t, id);
        vm.expectRevert(ICrestVault.NotOpen.selector);
        second.close(t);
        module.close(t);
        assertEq(_grantOf(vault, agentGrant).open, 0);
        assertEq(_grantOf(vault, agentGrant).spent, HOLD, "counted once");
    }

    /// A second vault of the same principal, with the same module and the same agent: an approval in one vault never makes
    /// the other answer, for the same digest or for the same payment from the other vault.
    function test_attack_oneVaultsApprovalAnswersForAnotherVault_refused() public {
        CrestVault second = CrestVault(factory.create(principal, address(usdc), bytes32("second")));
        vm.startPrank(principal);
        second.setModule(address(module), module.payee(), "");
        second.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        usdc.mint(address(second), 10 * HOLD);

        H.Terms memory t = _vterms(address(vault), buyer);
        _fundVia(t, BUYER_PK);
        AuthCaptureEscrow.PaymentInfo memory pi = _pi(t);
        bytes32 here = _collectorDigest(pi);
        pi.payer = address(second);
        bytes32 there = _collectorDigest(pi);

        vm.startPrank(address(usdc));
        assertEq(second.isValidSignature(here, ""), NO_1271, "the second vault answered the first vault's digest");
        assertEq(second.isValidSignature(there, ""), NO_1271, "the second vault answered a payment it never charged");
        vm.stopPrank();
    }
}
