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
    event Lend(
        address indexed from,
        address indexed to,
        address indexed asset,
        uint256 lendQuantity
    );

    event FlashLend(
        address indexed from,
        address indexed to,
        address indexed asset,
        uint256 lendQuantity
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

    function exit() public {
        // removes liquidity from a pool by burning liquidity shares
    }

    function lend() public {
        // initiates a lending agreement between the LendingPool and a party
    }

    function flashLend() public {
        // initiates a flash lending transaction and expects all funds to be returned
    }
}
