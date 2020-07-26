pragma solidity >=0.5.12 <=0.6.2;

import { IBPool } from "./IBPool.sol";

interface ILendingPool {
    /* function borrow(
        address borrower,
        address asset,
        uint256 borrowQuantity
    ) external; */

    function borrow(
        IBPool optionPool,
        address borrower,
        address asset,
        uint256 borrowQuantity,
        bytes calldata params
    ) external returns (bool);
    function depositCollateral(
        address from,
        address to,
        address asset,
        uint256 enterQuantity
    ) external returns (bool);
}
