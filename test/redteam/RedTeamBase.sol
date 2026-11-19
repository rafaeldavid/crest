// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {IMulticall3} from "commerce-payments/interfaces/IMulticall3.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {CrestBase} from "../CrestBase.sol";

/// Multicall3's `tryAggregate`, the one call the ERC-3009 collector's ERC-6492 hook makes. Holdback's test world names
/// the canonical Multicall3 address but puts no code there, so without this the hook would revert before it ran the
/// attacker's call, and an ERC-6492 attack would look refused for the wrong reason.
contract RedTeamMulticall3 {
    function tryAggregate(bool requireSuccess, IMulticall3.Call[] calldata calls)
        external
        payable
        returns (IMulticall3.Result[] memory results)
    {
        results = new IMulticall3.Result[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (requireSuccess) require(ok, "Multicall3: call failed");
            results[i] = IMulticall3.Result(ok, ret);
        }
    }
}

/// Any contract can be an operator of the shared Commerce Payments escrow. This one presents payment records that name
/// a Crest vault as the payer and whoever it likes as the receiver.
contract RogueOperator {
    AuthCaptureEscrow public immutable ESCROW;

    constructor(AuthCaptureEscrow escrow_) {
        ESCROW = escrow_;
    }

    function authorize(AuthCaptureEscrow.PaymentInfo calldata pi, address collector, bytes calldata data) external {
        ESCROW.authorize(pi, pi.maxAmount, collector, data);
    }

    function charge(AuthCaptureEscrow.PaymentInfo calldata pi, address collector, bytes calldata data) external {
        ESCROW.charge(pi, pi.maxAmount, collector, data, 0, address(0));
    }

    /// One transaction: relay an honest call to `target` (it must succeed), then present a payment of its own from the
    /// same vault, first as an authorization and then as a one-step charge. Returns whether either one landed.
    function relayThenPay(
        address target,
        bytes calldata relayed,
        AuthCaptureEscrow.PaymentInfo calldata pi,
        address collector,
        bytes calldata data
    ) external returns (bool paid) {
        (bool ok, bytes memory ret) = target.call(relayed);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        try this.authorize(pi, collector, data) {
            paid = true;
        } catch {}
        try this.charge(pi, collector, data) {
            paid = true;
        } catch {}
    }
}

/// The red team's world: Crest's test world (`CrestBase`) with code at Multicall3's address, plus helpers for
/// presenting payments, settling deals as the agent, and attempting a funding without stopping the test.
abstract contract RedTeamBase is CrestBase {
    bytes32 internal constant ERC6492_MAGIC = 0x6492649264926492649264926492649264926492649264926492649264926492;
    bytes4 internal constant MAGIC_1271 = 0x1626ba7e;
    bytes4 internal constant NO_1271 = 0xffffffff;

    function setUp() public virtual override {
        super.setUp();
        vm.etch(MULTICALL3, address(new RedTeamMulticall3()).code);
    }

    /// The calldata of an honest funding through the module, with every signature the deal needs.
    function _fundCall(H.Terms memory t, uint256 buyerPk) internal view returns (bytes memory) {
        return abi.encodeCall(
            module.agreeAndFund,
            (
                t,
                _sellerSig(t, SELLER_PK),
                _acceptance(t, ADJ_PK),
                _agree(t, buyerPk),
                H.Funding({signature: new bytes(65)})
            )
        );
    }

    /// Attempts a funding through the module and reports whether it landed, so a test can go on to check the state.
    function _tryFundVia(H.Terms memory t, uint256 buyerPk) internal returns (bool landed) {
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, buyerPk);
        try module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)})) {
            landed = true;
        } catch {}
    }

    /// The payment record the rules contract derives for `t`, with another operator and receiver.
    function _piAs(H.Terms memory t, address operator, address receiver)
        internal
        view
        returns (AuthCaptureEscrow.PaymentInfo memory pi)
    {
        pi = _pi(t);
        pi.operator = operator;
        pi.receiver = receiver;
    }

    /// The collector's ERC-3009 nonce for a payment record: its payer-agnostic hash. Leaves `pi` unchanged.
    function _nonceOf(AuthCaptureEscrow.PaymentInfo memory pi) internal view returns (bytes32 nonce) {
        address payer = pi.payer;
        nonce = _payerAgnosticHash(pi);
        pi.payer = payer;
    }

    /// The ERC-3009 digest the token asks the payer to approve when the ERC-3009 collector collects `pi`.
    function _collectorDigest(AuthCaptureEscrow.PaymentInfo memory pi) internal view returns (bytes32) {
        bytes32 nonce = _nonceOf(pi);
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                pi.payer,
                address(collector3009),
                uint256(pi.maxAmount),
                uint256(0),
                uint256(pi.preApprovalExpiry),
                nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }

    /// An ERC-6492 signature: the collector calls `target` with `data` through Multicall3, then passes `inner` on.
    function _erc6492(address target, bytes memory data, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodePacked(abi.encode(target, data, inner), ERC6492_MAGIC);
    }

    /// The agent (Holdback's `buyer`, `BUYER_PK`) accepts the work early, carrying the seller's delivery.
    function _earlyAcceptAsAgent(H.Terms memory t, bytes32 id) internal {
        (H.Delivery memory d, H.KeyProof memory k) = _delivery();
        bytes memory dsig = _deliverySig(id, d, SELLER_PK);
        H.EarlyAccept memory m = _early(t, id, BUYER_PK);
        rules.earlyAccept(t, m, d, dsig, k);
    }

    /// A mutual settlement before delivery, signed by the agent and the seller.
    function _mutualAsAgent(H.Terms memory t, bytes32 id, H.Payout[] memory payouts)
        internal
        view
        returns (H.Mutual memory m)
    {
        m.payouts = payouts;
        m.nonce = keccak256("mutual");
        m.expiresAt = type(uint64).max;
        bytes32 h = hx.mutual(id, t.token, m);
        m.buyerSignature = _sign(BUYER_PK, h);
        m.sellerSignature = _sign(SELLER_PK, h);
    }

    /// The agent creates its sub-agent's child vault under its grant, fills it with `amount`, and grants `sub` a
    /// grant with no limits of its own inside it.
    function _agentChild(uint256 amount) internal returns (CrestVault child, uint256 subInChild) {
        vm.prank(buyer);
        child = CrestVault(vault.createChild(agentGrant, 0, ""));
        if (amount > 0) {
            vm.prank(buyer);
            vault.fundChild(address(child), amount, "");
        }
        vm.prank(buyer);
        subInChild = child.grant(ROOT, sub, _wide(), 0, "");
    }
}
