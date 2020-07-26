pragma solidity >=0.5.12 <=0.6.2;

import { IBPool } from "./IBPool.sol";

interface ISecuredLoanReceiver {
    function secureLoan(IBPool optionPool, uint loanedQuantity, uint fee, bytes calldata params) external;
}