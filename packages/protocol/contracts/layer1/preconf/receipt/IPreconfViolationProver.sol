// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPreconfViolationProver
/// @custom:security-contact security@taiko.xyz
interface IPreconfViolationProver {
    /// @notice Validates the integrity and authenticity of a receipt.
    /// @param _receipt The serialized receipt data to validate.
    /// @return Returns true if the receipt is valid, otherwise false.
    function isReceiptValid(bytes calldata _receipt) external view returns (bool);

    /// @notice Validates if a preconfer breached a preconfirmation commitment.
    /// This function must revert if the validation fails, and it should not return a null address.
    /// @param _receipt Serialized receipt suspected to be in breach.
    /// @param _proof Proof supporting the violiation.
    /// @return The address of the preconfer responsible for the violiation.
    function provePreconfViolation(
        bytes calldata _receipt,
        bytes calldata _proof
    )
        external
        view
        returns (address);
}