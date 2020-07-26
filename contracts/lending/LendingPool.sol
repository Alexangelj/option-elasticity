pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Stateless Lending Pool
 * @author Primitive
 */

import { IERC20 } from "../interfaces/IERC20.sol";
import { IReserve } from "../interfaces/IReserve.sol";
import { ILendingComptroller } from "../interfaces/ILendingComptroller.sol";
import { SafeMath } from "../libraries/SafeMath.sol";
import { SafeERC20 } from "../libraries/SafeERC20.sol";
import { Ownable } from "../utils/Ownable.sol";
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";

contract LendingPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IReserve public reserve;
    IERC20 public reserveAsset;
    ILendingComptroller public lendingComptroller;

    event EnterLendingPool(address indexed from, address indexed asset, uint256 depositQuantity);
    event ExitLendingPool(address indexed from, address indexed asset, uint256 withdrawQuantity);
    event Borrowed(
        address indexed from,
        address indexed to,
        address indexed asset,
        uint256 borrowQuantity
    );

    event FlashBorrowed(
        address indexed from,
        address indexed to,
        address indexed asset,
        uint256 borrowQuantity
    );

    function initialize(address reserveAddress) public onlyOwner {
        reserve = IReserve(reserveAddress);
    }

    function enter(
        address depositor,
        address asset,
        uint256 enterQuantity
    ) public returns (bool) {
        // adds liquidity to a pool of reserve asset and receives liquidity shares
        // transfers tokens to reserve
        IERC20(asset).safeTransferFrom(depositor, address(reserve), enterQuantity);
        // calls reserve.deposit
        (bool success, uint256 depositQuantity) = reserve.updateStateWithDeposit(
            depositor,
            asset,
            enterQuantity
        );
        // reserve returns amount that was deposited
        // emits event
        emit EnterLendingPool(depositor, asset, depositQuantity);
        return success;
    }

    function exit(
        address withdrawer,
        address asset,
        uint256 exitQuantity
    ) public returns (bool) {
        // removes liquidity from a pool by burning liquidity shares
        IERC20(asset).safeTransferFrom(withdrawer, address(reserve), exitQuantity);

        (bool success, uint256 withdrawQuantity) = reserve.updateStateWithWithdraw(
            withdrawer,
            asset,
            exitQuantity
        );

        emit ExitLendingPool(withdrawer, asset, withdrawQuantity);
        return success;
    }

    function borrow(
        address borrower,
        address asset,
        uint256 borrowQuantity
    ) public {
        // initiates a lending agreement between the LendingPool and a party
        reserve.borrow(borrower, asset, borrowQuantity);
        emit Borrowed(msg.sender, borrower, asset, borrowQuantity);
    }

    function depositCollateral(
        address from,
        address to,
        address asset,
        uint256 enterQuantity
    ) public returns (bool) {
        // adds liquidity to a pool of reserve asset and receives liquidity shares
        // transfers tokens to reserve
        IERC20(asset).safeTransferFrom(from, address(reserve), enterQuantity);
        // calls reserve.deposit
        (bool success, uint256 depositQuantity) = reserve.updateStateWithDeposit(
            to,
            asset,
            enterQuantity
        );
        // reserve returns amount that was deposited
        // emits event
        emit EnterLendingPool(to, asset, depositQuantity);
        return success;
    }

    function flashBorrow() public {
        // initiates a flash lending transaction and expects all funds to be returned
    }
}
