// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenRiskCheck} from "../src/TokenRiskCheck.sol";

/// @dev Minimal tokens for the on-chain reads (these work on a local EVM).
contract OwnedToken {
    address public owner = address(0xA11CE);
    uint256 public totalSupply = 1_000_000e18;
}

contract OwnerlessToken {
    uint256 public totalSupply = 42;
}

/// @notice UNIT TESTS ONLY. The LLM precompile does not exist locally: vm.mockCall fakes its
///         return bytes so we can test request forwarding and response decoding. A pass here
///         says nothing about whether a real Ritual executor accepts the request.
contract TokenRiskCheckTest is Test {
    event TokenChecked(address indexed token, address owner, bool hasOwner, uint256 totalSupply, bytes completion);

    address constant LLM = address(0x0802);
    bytes constant LLM_INPUT = hex"c0ffee"; // opaque to the contract; real bytes come from the TS script

    TokenRiskCheck checker;
    OwnedToken owned;
    OwnerlessToken ownerless;

    function setUp() public {
        checker = new TokenRiskCheck();
        owned = new OwnedToken();
        ownerless = new OwnerlessToken();
    }

    /// @dev Build what the precompile would return: abi.encode(simmedInput, actualOutput)
    function _envelope(bool hasError, bytes memory completion, string memory err) internal pure returns (bytes memory) {
        TokenRiskCheck.LLMResponse memory r = TokenRiskCheck.LLMResponse({
            hasError: hasError,
            completionData: completion,
            modelMetadata: "",
            errorMessage: err,
            updatedConvoHistory: TokenRiskCheck.StorageRef("", "", "")
        });
        return abi.encode(bytes(""), abi.encode(r));
    }

    function test_StoresOnChainReadsAndCompletion() public {
        bytes memory completion = bytes('{"riskScore":35,"summary":"Single owner; fixed supply"}');
        vm.mockCall(LLM, LLM_INPUT, _envelope(false, completion, ""));

        vm.expectEmit(true, false, false, true);
        emit TokenChecked(address(owned), address(0xA11CE), true, 1_000_000e18, completion);
        checker.checkToken(address(owned), LLM_INPUT);

        TokenRiskCheck.Check memory c = checker.getCheck(address(owned));
        assertEq(c.owner, address(0xA11CE));
        assertTrue(c.hasOwner);
        assertEq(c.totalSupply, 1_000_000e18);
        assertEq(c.completion, completion);
        assertEq(c.blockNumber, block.number);
    }

    function test_ForwardsPreEncodedInputVerbatim() public {
        vm.mockCall(LLM, LLM_INPUT, _envelope(false, "ok", ""));
        vm.expectCall(LLM, LLM_INPUT);
        checker.checkToken(address(owned), LLM_INPUT);
    }

    function test_TokenWithoutOwner() public {
        vm.mockCall(LLM, LLM_INPUT, _envelope(false, "ok", ""));
        checker.checkToken(address(ownerless), LLM_INPUT);

        TokenRiskCheck.Check memory c = checker.getCheck(address(ownerless));
        assertEq(c.owner, address(0));
        assertFalse(c.hasOwner);
        assertEq(c.totalSupply, 42);
    }

    function test_RevertWhen_LLMReturnsError() public {
        vm.mockCall(LLM, LLM_INPUT, _envelope(true, "", "model unavailable"));
        vm.expectRevert(abi.encodeWithSelector(TokenRiskCheck.LLMError.selector, "model unavailable"));
        checker.checkToken(address(owned), LLM_INPUT);
    }

    /// @dev Without a mock, a local EVM returns empty bytes for 0x0802 (as the docs warn).
    function test_RevertWhen_PrecompileMissing_LocalEVM() public {
        vm.expectRevert(TokenRiskCheck.EmptyPrecompileOutput.selector);
        checker.checkToken(address(owned), LLM_INPUT);
    }

    function test_RevertWhen_NotAContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(TokenRiskCheck.NotERC20.selector, eoa));
        checker.checkToken(eoa, LLM_INPUT);
    }

    function test_DecodeLLMResponse() public view {
        TokenRiskCheck.LLMResponse memory r = checker.decodeLLMResponse(_envelope(false, "hello", ""));
        assertFalse(r.hasError);
        assertEq(r.completionData, bytes("hello"));
    }
}
