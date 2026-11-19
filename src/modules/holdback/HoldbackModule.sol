// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {ICrestBuyerModule, ICrestEscrowModule, ICrestVault} from "../../ICrestVault.sol";
import {IHoldbackModule} from "./IHoldbackModule.sol";

/// @title HoldbackModule
/// @notice Pays a Holdback hold from a Crest vault. `IHoldbackModule` describes every function and error.
contract HoldbackModule is IHoldbackModule, ICrestEscrowModule, ICrestBuyerModule {
    HoldbackRules public immutable RULES;
    AuthCaptureEscrow internal immutable ESCROW;
    address internal immutable COLLECTOR;
    address internal immutable TOKEN;
    uint64 internal immutable EXPIRY_MARGIN;

    constructor(HoldbackRules rules) {
        RULES = rules;
        ESCROW = rules.ESCROW();
        COLLECTOR = rules.ERC3009_COLLECTOR();
        TOKEN = rules.TOKEN();
        EXPIRY_MARGIN = rules.EXPIRY_MARGIN();
    }

    /// @inheritdoc IHoldbackModule
    function agreeAndFund(
        H.Terms calldata t,
        bytes calldata sellerSignature,
        H.Acceptance calldata acc,
        H.Agree calldata ag,
        H.Funding calldata f
    ) external returns (bytes32 id) {
        if (f.signature.length != 65) revert FundingSignatureNot65Bytes();
        bytes32 commitment = H.commitmentId(t);
        ICrestVault(t.buyerPaymentAddress).charge(
            t.buyer == t.buyerPaymentAddress ? _agentOf(t, commitment, ag) : t.buyer,
            t.price + t.fee,
            counterpartyOf(t.sellerPayoutAddress, t.adjudicator, t.fallbackAdjudicator, t.appealAdjudicator),
            commitment,
            t.timing.fundBy,
            _nonce(t, commitment)
        );
        id = RULES.agreeAndFund(t, sellerSignature, acc, ag, f);
    }

    /// @inheritdoc IHoldbackModule
    function close(H.Terms calldata t) external {
        bytes32 id = H.commitmentId(t);
        IHoldbackRules.Stage s = RULES.dealOf(id).stage;
        bool ended = s == IHoldbackRules.Stage.Released || s == IHoldbackRules.Stage.Refunded
            || s == IHoldbackRules.Stage.Settled;
        if (!ended && block.timestamp < _expiry(t)) revert NotEnded();
        ICrestVault(t.buyerPaymentAddress).endCommitment(id);
    }

    /// @inheritdoc IHoldbackModule
    function counterpartyOf(address payout, address adjudicator, address fallbackAdjudicator, address appealAdjudicator)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(payout, adjudicator, fallbackAdjudicator, appealAdjudicator));
    }

    /// @inheritdoc IHoldbackModule
    function payee() external view returns (address) {
        return COLLECTOR;
    }

    /// @inheritdoc IHoldbackModule
    function escrow() external view override(IHoldbackModule, ICrestEscrowModule) returns (address) {
        return address(ESCROW);
    }

    /// @inheritdoc ICrestBuyerModule
    function buyerMessage(bytes calldata message) external view returns (BuyerMessage memory) {
        bytes4 view_ = bytes4(message);
        if (
            view_ != IHoldbackModule.termsMessage.selector && view_ != IHoldbackModule.agreeMessage.selector
                && view_ != IHoldbackModule.earlyAcceptMessage.selector && view_ != IHoldbackModule.mutualMessage.selector
        ) revert NotABuyerMessage();
        (bool ok, bytes memory ret) = address(this).staticcall(message);
        if (!ok) revert NotABuyerMessage();
        return abi.decode(ret, (BuyerMessage));
    }

    /// @inheritdoc IHoldbackModule
    function termsMessage(H.Terms calldata t) external view returns (BuyerMessage memory) {
        bytes32 id = H.commitmentId(t);
        return _beforeFunding(t, id, RULES.typedDataHash(id));
    }

    /// @inheritdoc IHoldbackModule
    function agreeMessage(H.Terms calldata t, H.Agree calldata ag) external view returns (BuyerMessage memory) {
        bytes32 id = H.commitmentId(t);
        return _beforeFunding(t, id, RULES.typedDataHash(H.agreeHash(id, t.buyer, ag)));
    }

    /// @inheritdoc IHoldbackModule
    function earlyAcceptMessage(bytes32 id, address buyer, H.EarlyAccept calldata m)
        external
        view
        returns (BuyerMessage memory b)
    {
        (b.digest, b.commitment, b.buyer) = (RULES.typedDataHash(H.earlyAcceptHash(id, buyer, m)), id, buyer);
    }

    /// @inheritdoc IHoldbackModule
    function mutualMessage(bytes32 id, address buyer, H.Mutual calldata m)
        external
        view
        returns (BuyerMessage memory b)
    {
        (b.digest, b.commitment, b.buyer) = (RULES.typedDataHash(H.mutualHash(id, H.tokenIdHash(TOKEN), m)), id, buyer);
    }

    function _beforeFunding(H.Terms calldata t, bytes32 id, bytes32 digest)
        internal
        pure
        returns (BuyerMessage memory)
    {
        return BuyerMessage({
            digest: digest,
            commitment: id,
            buyer: t.buyer,
            beforeFunding: true,
            payer: t.buyerPaymentAddress,
            amount: t.price + t.fee,
            counterparty: counterpartyOf(t.sellerPayoutAddress, t.adjudicator, t.fallbackAdjudicator, t.appealAdjudicator)
        });
    }

    /// The key that signed the agreement inside a vault's buyer signature, whose grant the vault charges.
    function _agentOf(H.Terms calldata t, bytes32 id, H.Agree calldata ag) internal view returns (address key) {
        (,, bytes memory ecdsa) = abi.decode(ag.signature, (address, bytes, bytes));
        if (ecdsa.length == 65) key = ECDSA.tryRecover(RULES.typedDataHash(H.agreeHash(id, t.buyer, ag)), ecdsa);
        if (key == address(0)) revert BadBuyerSignature();
    }

    function _expiry(H.Terms calldata t) internal view returns (uint256) {
        return uint256(t.timing.fallbackBy) + t.timing.appealDecideSec + EXPIRY_MARGIN;
    }

    function _nonce(H.Terms calldata t, bytes32 id) internal view returns (bytes32) {
        uint48 expiry = uint48(_expiry(t));
        return ESCROW.getHash(
            AuthCaptureEscrow.PaymentInfo({
                operator: address(RULES),
                payer: address(0),
                receiver: t.sellerPayoutAddress,
                token: TOKEN,
                maxAmount: uint120(t.price + t.fee),
                preApprovalExpiry: uint48(t.timing.fundBy),
                authorizationExpiry: expiry,
                refundExpiry: expiry,
                minFeeBps: 0,
                maxFeeBps: 10_000,
                feeReceiver: address(0),
                salt: uint256(id)
            })
        );
    }
}
