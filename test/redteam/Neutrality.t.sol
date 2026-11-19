// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {ICrestVault} from "../../src/ICrestVault.sol";
import {RedTeamBase} from "./RedTeamBase.sol";

/// A module the principal never enabled, naming an escrow of its choosing for `reclaim`.
contract FakeEscrowModule {
    address public immutable escrow;

    constructor(address escrow_) {
        escrow = escrow_;
    }
}

/// Red team: money in a hold, and a funded Holdback deal settling by its terms whatever the vault's side does.
///
/// Every `test_attack_*` passes when the defence holds and fails when the attack works.
contract RedTeamNeutralityTest is RedTeamBase {
    /// The principal stops the agent every way it can after a funding: closes its grant, unlists its merchant, disables the
    /// module and empties the vault. The agent's key still holds the buyer's role on the funded deal. It tries a mutual
    /// settlement that pays its own key, which Holdback refuses. Then it accepts early, which ADR-0041 (section 4) states
    /// as the first version's residual: the hold goes only to the payout address listed when it was funded, and the
    /// agent's key gets nothing.
    function test_attack_closedAgentSendsAFundedHoldToAnAddressNoOneListed_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        vm.startPrank(principal);
        vault.close(agentGrant, "");
        vault.allow(agentGrant, _merchant(), false, "");
        vault.setModule(address(module), address(0), "");
        vault.withdraw(principal, usdc.balanceOf(address(vault)), "");
        vm.stopPrank();
        uint256 agentBefore = usdc.balanceOf(buyer);

        H.Payout[] memory toAgent = new H.Payout[](1);
        toAgent[0] = H.Payout(buyer, PRICE);
        H.Mutual memory m = _mutualAsAgent(t, id, toAgent);
        H.KeyProof memory none;
        vm.expectRevert(IHoldbackRules.InvalidMessage.selector);
        rules.mutualSettle(t, m, _noDelivery(), none);

        uint256 sellerBefore = usdc.balanceOf(seller);
        _earlyAcceptAsAgent(t, id);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "residual: the listed payout address is paid");
        assertEq(usdc.balanceOf(address(vault)), FEE, "the unused fee came back to the vault");
        assertEq(usdc.balanceOf(buyer), agentBefore, "the agent's key got nothing");
    }

    /// The principal pauses the root, closes the agent, disables the module and empties the vault after a funding. The
    /// adjudicator rejects the work, and the refund still reaches the vault: a refund runs no code on the payer.
    function test_attack_ownerStopsEverythingAfterFunding_refundStillReachesTheVault() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        vm.startPrank(principal);
        vault.setPaused(ROOT, true, "");
        vault.close(agentGrant, "");
        vault.setModule(address(module), address(0), "");
        vault.withdraw(principal, usdc.balanceOf(address(vault)), "");
        vm.stopPrank();

        _deliver(t, id);
        rules.decide(t, _primary(t, id, H.OUTCOME_REJECT), _noDelivery(), "");
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(usdc.balanceOf(address(vault)), PRICE, "the price came back to the vault");
        module.close(t); // a disabled module still ends the commitment it opened
        assertEq(_grantOf(vault, agentGrant).open, 0);
    }

    /// Once the escrow's expiry has passed, a stranger has the vault reclaim a delivered deal's hold. The money goes
    /// only to the vault, and Holdback's own timeouts still close the deal with nothing left to move.
    function test_attack_strangerReclaimsAfterExpiry_moneyOnlyToTheVault_andTheDealStillCloses() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        _deliver(t, id);
        vm.warp(uint256(t.timing.fallbackBy) + t.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 strangerBefore = usdc.balanceOf(stranger);

        vm.prank(stranger);
        vault.reclaim(address(module), _pi(t));
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, HOLD);
        assertEq(usdc.balanceOf(stranger), strangerBefore);

        rules.triggerFallback(t);
        rules.triggerDefault(t);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Refunded), "the deal still closed by its terms");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, HOLD, "nothing moved twice");
        module.close(t);
        assertEq(_grantOf(vault, agentGrant).open, 0);
    }

    /// `reclaim` before the escrow's expiry, for a payment record the vault never made, or through a module the principal
    /// never enabled, moves nothing.
    function test_attack_reclaimEarlyOrForACraftedRecordOrThroughAnUnknownModule_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        _fundVia(t, BUYER_PK);
        AuthCaptureEscrow.PaymentInfo memory pi = _pi(t);

        vm.expectRevert(
            abi.encodeWithSelector(
                AuthCaptureEscrow.BeforeAuthorizationExpiry.selector, uint48(block.timestamp), pi.authorizationExpiry
            )
        );
        vault.reclaim(address(module), pi);

        vm.warp(pi.authorizationExpiry);
        AuthCaptureEscrow.PaymentInfo memory crafted = _pi(t);
        crafted.receiver = stranger;
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureEscrow.ZeroAuthorization.selector, escrow.getHash(crafted)));
        vault.reclaim(address(module), crafted);

        FakeEscrowModule fake = new FakeEscrowModule(stranger);
        vm.expectRevert(ICrestVault.ModuleNotEnabled.selector);
        vault.reclaim(address(fake), pi);
    }

    /// The principal disables the module, which closes the vault's own `reclaim` for its holds (ADR-0041 names this narrower
    /// backstop). The hold is not stranded: Holdback's timeout, which anyone may send, returns it.
    function test_attack_ownerDisablesTheModule_holdStillComesBackByTheTimeout() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        vm.prank(principal);
        vault.setModule(address(module), address(0), "");
        vm.warp(uint256(t.timing.fallbackBy) + t.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        AuthCaptureEscrow.PaymentInfo memory pi = _pi(t);
        vm.expectRevert(ICrestVault.ModuleNotEnabled.selector);
        vault.reclaim(address(module), pi);

        vm.prank(stranger);
        rules.reclaim(t);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, HOLD, "the timeout returned the whole hold");
    }
}
