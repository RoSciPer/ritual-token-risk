// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/// @title TokenRiskCheck
/// @notice Reads an ERC-20's owner and totalSupply on-chain, then asks Ritual's LLM
///         precompile (0x0802) for a risk assessment using a request encoded off-chain.
/// @dev LLM calls are short-running async (SPC): the block builder runs the call in a TEE
///      and replays this tx with the result, so the output is available in this same call.
///      Only one async precompile call is allowed per transaction.
contract TokenRiskCheck {
    /// @notice Ritual LLM inference precompile
    address public constant LLM_PRECOMPILE = address(0x0802);

    /// @dev Matches the LLM response format in Ritual's docs
    struct StorageRef {
        string platform;
        string path;
        string keyRef;
    }

    struct LLMResponse {
        bool hasError;
        bytes completionData;
        bytes modelMetadata;
        string errorMessage;
        StorageRef updatedConvoHistory;
    }

    struct Check {
        address owner; // address(0) if the token has no owner()
        bool hasOwner;
        uint256 totalSupply;
        bytes completion; // raw completionData from the LLM
        uint256 blockNumber;
    }

    /// @notice Latest check per token
    mapping(address => Check) internal _checks;

    event TokenChecked(address indexed token, address owner, bool hasOwner, uint256 totalSupply, bytes completion);

    error NotERC20(address token);
    error PrecompileCallFailed(bytes reason);
    error EmptyPrecompileOutput();
    error LLMError(string message);

    /// @param token ERC-20 to check
    /// @param llmInput 32-field LLM request, ABI-encoded off-chain (see scripts/encodeLlmRequest.ts)
    function checkToken(address token, bytes calldata llmInput) external {
        // 1. Deterministic on-chain reads (the trusted part of the record)
        (address owner, bool hasOwner) = _readOwner(token);
        uint256 supply = _readTotalSupply(token);

        // 2. Async LLM call; result arrives in this same tx on Ritual Chain
        LLMResponse memory r = decodeLLMResponse(_callLLM(llmInput));
        if (r.hasError) revert LLMError(r.errorMessage);

        _checks[token] = Check(owner, hasOwner, supply, r.completionData, block.number);
        emit TokenChecked(token, owner, hasOwner, supply, r.completionData);
    }

    function getCheck(address token) external view returns (Check memory) {
        return _checks[token];
    }

    /// @notice Unwrap the precompile envelope and decode the LLM response.
    /// @dev Envelope = abi.encode(bytes simmedInput, bytes actualOutput), per the docs'
    ///      description of PrecompileConsumer._executePrecompile (its source is not published).
    function decodeLLMResponse(bytes memory raw) public pure returns (LLMResponse memory) {
        if (raw.length == 0) revert EmptyPrecompileOutput();
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        return abi.decode(actualOutput, (LLMResponse));
    }

    function _callLLM(bytes calldata llmInput) internal returns (bytes memory raw) {
        bool ok;
        (ok, raw) = LLM_PRECOMPILE.call(llmInput);
        if (!ok) revert PrecompileCallFailed(raw);
    }

    /// @dev owner() is not part of ERC-20, so a missing/odd owner() is not an error.
    function _readOwner(address token) internal view returns (address, bool) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || data.length < 32) return (address(0), false);
        uint256 word = abi.decode(data, (uint256));
        if (word > type(uint160).max) return (address(0), false);
        return (address(uint160(word)), true);
    }

    function _readTotalSupply(address token) internal view returns (uint256) {
        if (token.code.length == 0) revert NotERC20(token);
        try IERC20Supply(token).totalSupply() returns (uint256 s) {
            return s;
        } catch {
            revert NotERC20(token);
        }
    }
}
