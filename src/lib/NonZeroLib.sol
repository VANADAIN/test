// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library NonZeroLib {
    error ZeroAddress();
    error ZeroValue();
    error ZeroLength();

    function _nonZeroA(address addr) internal pure {
        if (addr == address(0)) {
            revert ZeroAddress();
        }
    }

    function _nonZeroV(uint256 value) internal pure {
        if (value == 0) {
            revert ZeroValue();
        }
    }

    function _nonZeroB(bytes memory b) internal pure {
        if (b.length == 0) {
            revert ZeroLength();
        }
    }
}
