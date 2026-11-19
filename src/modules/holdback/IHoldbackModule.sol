// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {ICrestBuyerModule} from "../../ICrestVault.sol";

/// @title IHoldbackModule
/// @notice Pays a hold in Holdback, the escrow behind Crow, from a Crest vault. One module serves one Holdback rules
///         deployment and every vault that enables it; it holds no tokens and no state.
///
///         A deal paid this way names the vault as `buyerPaymentAddress` and the agent's key as `buyer`. Anyone sends
///         the rules contract's own `agreeAndFund` call to this module instead, with the same arguments. The module has
///         the vault charge the agent's grant with the hold (price plus the adjudication fee), for the deal's payout
///         address and its three adjudicators, then forwards the call unchanged. The rules contract checks the
///         seller's, the adjudicator's and the agent's signatures as it always does; the token asks the vault, which
///         approves exactly that hold.
///
///         The vault as the buyer. A deal may name the vault as `buyer` too. The agent then signs the agreement for
///         the vault: its signature is the vault's buyer signature, `abi.encode(module, message, ecdsa)`, where
///         `message` is this module's `agreeMessage` call for the deal and `ecdsa` the agent's signature of the
///         agreement's digest. The module charges the grant of the key that `ecdsa` recovers, and the rules contract
///         then asks the vault through ERC-1271. The four message views below rebuild the digests of the buyer
///         messages: the terms, the agreement, an early accept, and the buyer's half of a settlement.
///
///         Why an approved merchant holds through the escrow: Holdback pays a hold out only to the terms' payout
///         address or back to the payment address. So a vault that lists a payout address knows the money can reach
///         only that merchant or come back.
/// @dev The principal enables this module on its vault with the escrow's ERC-3009 collector as the payee (`payee()`). The
///      module derives the escrow's expiry, the payment record and the collector's nonce exactly as the rules contract
///      does (`HoldbackRules._escrowExpiry`, `_paymentInfo`); a wrong derivation fails closed, as the token then refuses
///      the funding.
interface IHoldbackModule {
    error FundingSignatureNot65Bytes();
    error NotEnded();
    error NotABuyerMessage();
    error BadBuyerSignature();

    /// @notice The rules contract's own funding call, forwarded after the vault has charged the agent's grant. When
    ///         the terms name the payment address as the buyer too, the agent is the key that signed the agreement
    ///         inside the vault's buyer signature; otherwise it is `buyer`. Refuses with `BadBuyerSignature` when that
    ///         signature holds no 65-byte ECDSA signature a key recovers from.
    /// @param f Its signature is passed on untouched and must be exactly 65 bytes; the vault's approval does not read
    ///        it. Any 65 bytes work, which keeps the call in the API's shape and keeps ERC-6492 hooks out.
    /// @return id The commitment ID.
    function agreeAndFund(
        H.Terms calldata t,
        bytes calldata sellerSignature,
        H.Acceptance calldata acc,
        H.Agree calldata ag,
        H.Funding calldata f
    ) external returns (bytes32 id);

    /// @notice Anyone tells the paying vault that a deal has ended, so its open counts fall: the rules contract's stage
    ///         is Released, Refunded or Settled, or the escrow's expiry has passed, after which no capture can follow.
    function close(H.Terms calldata t) external;

    /// @notice The counterparty key a vault lists to approve a Holdback merchant: its payout address together with the
    ///         three adjudicators the principal accepts for it.
    function counterpartyOf(address payout, address adjudicator, address fallbackAdjudicator, address appealAdjudicator)
        external
        pure
        returns (bytes32);

    /// @notice The address the vault pays: the escrow's ERC-3009 collector.
    function payee() external view returns (address);

    /// @notice The Commerce Payments escrow behind the rules contract, for a vault's `reclaim`.
    function escrow() external view returns (address);

    /// @notice The buyer's signature on the terms, which Holdback's operators check: the digest of the commitment ID.
    function termsMessage(H.Terms calldata t) external view returns (ICrestBuyerModule.BuyerMessage memory);

    /// @notice The buyer's agreement, which the rules contract checks at funding.
    function agreeMessage(H.Terms calldata t, H.Agree calldata ag)
        external
        view
        returns (ICrestBuyerModule.BuyerMessage memory);

    /// @notice The buyer's early accept on commitment `id`, for `buyer`.
    function earlyAcceptMessage(bytes32 id, address buyer, H.EarlyAccept calldata m)
        external
        view
        returns (ICrestBuyerModule.BuyerMessage memory);

    /// @notice The buyer's half of a settlement on commitment `id`. Holdback's settlement digest does not name the
    ///         buyer; `buyer` says which vault is asked.
    function mutualMessage(bytes32 id, address buyer, H.Mutual calldata m)
        external
        view
        returns (ICrestBuyerModule.BuyerMessage memory);
}
