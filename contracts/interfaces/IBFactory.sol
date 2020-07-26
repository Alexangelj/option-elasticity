pragma solidity >=0.5.12 <=0.6.2;

import {IBPool} from "./IBPool.sol";

interface IBFactory {
    function newBPool(uint extraSalt) external returns (IBPool);
}