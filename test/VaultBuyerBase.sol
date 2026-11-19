// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../src/CrestVault.sol";
import {RedTeamBase} from "./redteam/RedTeamBase.sol";

/// The vault as the deal's buyer (design record, section 12): helpers that build the vault's buyer signature,
/// `abi.encode(module, message, ecdsa)`, where `message` is the calldata of one of the Holdback module's message views
/// and `ecdsa` is a key's 65-byte signature of the message's EIP-712 digest under Holdback's domain.
abstract contract VaultBuyerBase is RedTeamBase {
    /// A seller's delivery and the buyer's key envelope in it, for the early accepts below.
    struct Early {
        H.EarlyAccept m;
        H.Delivery d;
        bytes dsig;
        H.KeyProof k;
    }

    /// Terms that `v` both buys and pays.
    function _bterms(CrestVault v) internal returns (H.Terms memory t) {
        t = _vterms(address(v), address(v));
    }

    function _ecdsa(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The vault's buyer signature for `message`, signed by `pk` over `digest`.
    function _wrap(bytes memory message, bytes32 digest, uint256 pk) internal view returns (bytes memory) {
        return abi.encode(address(module), message, _ecdsa(pk, digest));
    }

    function _agreeDigest(H.Terms memory t, H.Agree memory a) internal view returns (bytes32) {
        return rules.typedDataHash(hx.agree(hx.id(t), t.buyer, a));
    }

    /// The agreement, signed for the vault by `pk`.
    function _agreeAs(H.Terms memory t, uint256 pk) internal view returns (H.Agree memory a) {
        a = H.Agree({nonce: keccak256("agree"), expiresAt: t.timing.offerExpiresAt, signature: ""});
        a.signature = _wrap(abi.encodeCall(module.agreeMessage, (t, a)), _agreeDigest(t, a), pk);
    }

    /// The buyer's signature on the terms themselves, which Holdback's operators check before they relay a funding.
    function _termsSig(H.Terms memory t, uint256 pk) internal view returns (bytes memory) {
        return _wrap(abi.encodeCall(module.termsMessage, (t)), rules.typedDataHash(hx.id(t)), pk);
    }

    function _fundAs(H.Terms memory t, uint256 pk) internal returns (bytes32) {
        return module.agreeAndFund(
            t, _sellerSig(t, SELLER_PK), _acceptance(t, ADJ_PK), _agreeAs(t, pk), H.Funding({signature: new bytes(65)})
        );
    }

    /// Builds every signature first, so the expected revert applies to the funding call alone.
    function _expectFundRefused(H.Terms memory t, H.Agree memory a, bytes memory err) internal {
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory acc = _acceptance(t, ADJ_PK);
        vm.expectRevert(err);
        module.agreeAndFund(t, s, acc, a, H.Funding({signature: new bytes(65)}));
    }

    /// A delivery whose buyer envelope is addressed to `recipient`, the deal's buyer, as Holdback's key proof asks.
    function _deliveryTo(address recipient) internal view returns (H.Delivery memory d, H.KeyProof memory k) {
        k = _buyerKey();
        k.keyHashes[1] = hx.key(recipient, k);
        d = H.Delivery({
            attempt: 1,
            ciphertextHash: keccak256("ciphertext"),
            plaintextSha256Hash: keccak256("sha256:plain"),
            plaintextMimeHash: keccak256("text/csv"),
            encryptedKeysHash: keccak256(abi.encodePacked(k.keyHashes)),
            submittedAt: 1_790_000_000
        });
    }

    function _earlyDigest(H.Terms memory t, bytes32 id, H.EarlyAccept memory m) internal view returns (bytes32) {
        return rules.typedDataHash(hx.early(id, t.buyer, m));
    }

    /// An early accept of the seller's delivery, signed for the vault by `pk`.
    function _earlyAs(H.Terms memory t, bytes32 id, uint256 pk) internal view returns (Early memory e) {
        (e.d, e.k) = _deliveryTo(t.buyer);
        e.dsig = _deliverySig(id, e.d, SELLER_PK);
        e.m = H.EarlyAccept({
            attempt: 1,
            deliveryHash: hx.delivery(id, e.d),
            nonce: keccak256("early"),
            expiresAt: type(uint64).max,
            signature: ""
        });
        e.m.signature =
            _wrap(abi.encodeCall(module.earlyAcceptMessage, (id, t.buyer, e.m)), _earlyDigest(t, id, e.m), pk);
    }

    function _acceptEarly(H.Terms memory t, Early memory e) internal {
        rules.earlyAccept(t, e.m, e.d, e.dsig, e.k);
    }

    function _expectEarlyRefused(H.Terms memory t, Early memory e) internal {
        vm.expectRevert(IHoldbackRules.BadSignature.selector);
        rules.earlyAccept(t, e.m, e.d, e.dsig, e.k);
    }

    function _mutualDigest(H.Terms memory t, bytes32 id, H.Mutual memory m) internal view returns (bytes32) {
        return rules.typedDataHash(hx.mutual(id, t.token, m));
    }

    /// A settlement before delivery that the seller signs and `pk` signs for the vault.
    function _mutualAs(H.Terms memory t, bytes32 id, H.Payout[] memory payouts, uint256 pk)
        internal
        view
        returns (H.Mutual memory m)
    {
        m.payouts = payouts;
        m.nonce = keccak256("mutual");
        m.expiresAt = type(uint64).max;
        bytes32 digest = _mutualDigest(t, id, m);
        m.buyerSignature = _wrap(abi.encodeCall(module.mutualMessage, (id, t.buyer, m)), digest, pk);
        m.sellerSignature = _sign(SELLER_PK, hx.mutual(id, t.token, m));
    }

    /// The whole price back to the payment address.
    function _fullRefund(H.Terms memory t) internal pure returns (H.Payout[] memory p) {
        p = new H.Payout[](1);
        p[0] = H.Payout(t.buyerPaymentAddress, t.price);
    }

    function _settle(H.Terms memory t, H.Mutual memory m) internal {
        H.KeyProof memory none;
        rules.mutualSettle(t, m, _noDelivery(), none);
    }

    function _expectSettleRefused(H.Terms memory t, H.Mutual memory m, bytes4 err) internal {
        H.KeyProof memory none;
        H.Delivery memory nod = _noDelivery();
        vm.expectRevert(err);
        rules.mutualSettle(t, m, nod, none);
    }

    /// One level down: the key `pk` (controller of `grantId` in `v`) creates a child vault, fills it with enough for
    /// one deal at each level below, and grants a new key there.
    function _deeper(CrestVault v, uint256 pk, uint256 grantId, uint256 depth)
        internal
        returns (CrestVault child, uint256 childPk, uint256 childGrant)
    {
        address key = vm.addr(pk);
        vm.startPrank(key);
        child = CrestVault(v.createChild(grantId, bytes32(depth), ""));
        v.fundChild(address(child), (6 - depth) * HOLD, "");
        childPk = 0xD000 + depth;
        childGrant = child.grant(ROOT, vm.addr(childPk), _wide(), 0, "");
        vm.stopPrank();
    }
}
