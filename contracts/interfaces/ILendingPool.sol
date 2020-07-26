pragma solidity >=0.5.12 <=0.6.2;

interface ILendingPool {
    function borrow(
        address borrower,
        address asset,
        uint256 borrowQuantity
    ) external;

    function depositCollateral(
        address from,
        address to,
        address asset,
        uint256 enterQuantity
    ) external returns (bool);
}
