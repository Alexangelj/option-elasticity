pragma solidity >=0.5.12 <=0.6.2;

import { IBPool } from "../../pool/interfaces/IBPool.sol";

interface ILendingPool {
    function borrow(
        IBPool optionPool,
        address borrower,
        address receiver,
        address asset,
        uint256 borrowQuantity,
        bytes calldata params
    ) external returns (bool);

    function depositCollateral(
        address from,
        address to,
        address asset,
        address borrowedAsset,
        uint256 debt,
        uint256 enterQuantity
    ) external returns (bool);
}
