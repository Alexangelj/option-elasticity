pragma solidity >=0.5.12 <=0.6.2;

interface IReserve {
    function updateStateWithDeposit(
        address depositor,
        address asset,
        uint256 enterQuantity
    ) external returns (bool success, uint256 depositQuantity);

    function updateStateWithWithdraw(
        address withdrawer,
        address asset,
        uint256 exitQuantity /* onlyLendingPool */
    ) external returns (bool success, uint256 withdrawQuantity);

    function borrow(
        address borrower,
        address receiver,
        address asset,
        uint256 borrowQuantity
    ) external;

    function updateStateWithBorrow(address to, address asset, uint quantity) external returns (bool);
}