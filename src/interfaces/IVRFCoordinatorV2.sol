// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVRFCoordinatorV2 {
    function requestRandomWords(
        bytes32 keyHash,
        uint64  subId,
        uint16  minimumRequestConfirmations,
        uint32  callbackGasLimit,
        uint32  numWords
    ) external returns (uint256 requestId);
}
