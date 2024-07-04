pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

interface IWeightedPool2Tokens {
    function getLatest(uint8) external view returns (uint256);
}
