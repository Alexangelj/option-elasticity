pragma solidity >=0.5.12 <=0.6.2;

interface IReserve {
    function updateStateWithDeposit(
        address depositor,
        address asset,
        uint256 enterQuantity
    ) external returns (bool success, uint256 depositQuantity);
}
