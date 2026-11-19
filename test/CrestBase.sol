// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Base} from "holdback-test/unit/Base.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestFactory} from "../src/CrestFactory.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {HoldbackModule} from "../src/modules/holdback/HoldbackModule.sol";

/// Holdback's own test world (its unchanged rules contract, Commerce Payments' escrow and ERC-3009 collector, and a
/// token that asks a contract payer through ERC-1271), with a Crest factory, the Holdback module, and one principal's
/// vault in which the deal's buyer key (Holdback's `buyer`) holds an agent grant: one hold per deal, three a day, two
/// open at once, the test seller's payout address with Holdback's three test adjudicators as its only merchant.
abstract contract CrestBase is Base {
    uint256 internal constant PRINCIPAL_PK = 0x0A11CE5;
    uint256 internal constant SUB_PK = 0x5AB;
    uint256 internal constant SUB2_PK = 0x5AB2;
    uint256 internal constant HOLD = PRICE + FEE;
    /// The root grant's ID in every vault (`CrestVault.ROOT`), as a constant so a prank or an expected revert is not
    /// spent on reading it.
    uint256 internal constant ROOT = 1;

    address internal principal;
    address internal sub;
    address internal sub2;
    address internal stranger;
    CrestFactory internal factory;
    HoldbackModule internal module;
    CrestVault internal vault;
    uint256 internal agentGrant;

    function setUp() public virtual override {
        super.setUp();
        principal = vm.addr(PRINCIPAL_PK);
        sub = vm.addr(SUB_PK);
        sub2 = vm.addr(SUB2_PK);
        stranger = makeAddr("stranger");
        factory = new CrestFactory(0, address(0));
        module = new HoldbackModule(rules);
        vault = CrestVault(factory.create(principal, address(usdc), bytes32(0)));
        vm.startPrank(principal);
        vault.setModule(address(module), module.payee(), "");
        agentGrant = vault.grant(ROOT, buyer, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true), 0, "");
        vault.allow(agentGrant, _merchant(), true, "");
        vm.stopPrank();
        usdc.mint(address(vault), 1_000 * HOLD);
    }

    function _caps(
        uint256 perSpend,
        uint256 perPeriod,
        uint256 lifetime,
        uint32 maxOpen,
        bool restricted,
        bool mayDelegate
    ) internal pure returns (ICrestVault.Caps memory) {
        return ICrestVault.Caps({
            perSpend: uint128(perSpend),
            perPeriod: uint128(perPeriod),
            lifetime: uint128(lifetime),
            maxOpen: maxOpen,
            period: 1 days,
            expiresAt: 0,
            restricted: restricted,
            mayDelegate: mayDelegate
        });
    }

    function _wide() internal pure returns (ICrestVault.Caps memory) {
        return _caps(type(uint128).max, type(uint128).max, type(uint128).max, type(uint32).max, false, true);
    }

    /// The test seller's payout address with Holdback's three test adjudicators.
    function _merchant() internal view returns (bytes32) {
        return module.counterpartyOf(seller, adjudicator, fallbackAdj, appealAdj);
    }

    /// Terms paid from `payer`, agreed by the key `buyerKey`.
    function _vterms(address payer, address buyerKey) internal returns (H.Terms memory t) {
        t = _terms();
        t.buyerPaymentAddress = payer;
        t.buyer = buyerKey;
    }

    function _fundVia(H.Terms memory t, uint256 buyerPk) internal returns (bytes32) {
        return module.agreeAndFund(
            t,
            _sellerSig(t, SELLER_PK),
            _acceptance(t, ADJ_PK),
            _agree(t, buyerPk),
            H.Funding({signature: new bytes(65)})
        );
    }

    /// Builds every signature first, so the expected revert applies to the funding call alone.
    function _expectRefused(H.Terms memory t, uint256 buyerPk, bytes memory err) internal {
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, buyerPk);
        vm.expectRevert(err);
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
    }

    function _release(H.Terms memory t, bytes32 id) internal {
        _deliver(t, id);
        rules.decide(t, _primary(t, id, H.OUTCOME_ACCEPT), _noDelivery(), "");
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
    }

    function _grantOf(CrestVault v, uint256 id) internal view returns (ICrestVault.Grant memory) {
        return v.getGrant(id);
    }

    function _setAgentCaps(ICrestVault.Caps memory c) internal {
        vm.prank(principal);
        vault.setCaps(agentGrant, c, "");
    }
}
