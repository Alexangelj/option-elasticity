pragma solidity >=0.5.12 <=0.6.2;

import { IBPool } from "../../pool/interfaces/IBPool.sol";

interface ISecuredLoanReceiver {
    function secureLoan(
        IBPool optionPool,
        uint256 loanedQuantity,
        uint256 fee,
        bytes calldata params
    ) external returns (bool);
}
