pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Stateful Reserve Pool
 * @author Primitive
 */

import { IIOU } from "../interfaces/IIOU.sol";
import { ILendingPool } from "../interfaces/ILendingPool.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeERC20 } from "../libraries/SafeERC20.sol";
import { SafeMath } from "../libraries/SafeMath.sol";
import { Ownable } from "../utils/Ownable.sol";
import "@nomiclabs/buidler/console.sol";

contract Reserve is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IIOU;

    ILendingPool public lendingPool;

    struct ReserveData {
        IIOU debtToken;
        mapping(address => uint256) assetBalances;
        mapping(address => uint256) borrowBalances;
        mapping(address => uint256) collateralBalances;
        mapping(address => uint256) feeBalances;
        uint256 totalAssetBalance;
        bool isBorrowingEnabled;
        bool isActive;
        bool isFrozen;
    }

    mapping(address => ReserveData) internal _reserves;

    event Deposited(address indexed from, address indexed asset, uint256 depositQuantity);
    event Withdrawn(address indexed from, address indexed asset, uint256 withdrawQuantity);

    function initialize(address lendingPoolAddress) public onlyOwner {
        lendingPool = ILendingPool(lendingPoolAddress);
    }

    modifier onlyLendingPool {
        require(address(lendingPool) == msg.sender, "ERR_NOT_LENDING_POOL");
        _;
    }

    function updateStateWithDebtToken(address asset, address debtTokenAddress) public onlyOwner {
        ReserveData storage reserve = _reserves[asset];
        reserve.debtToken = IIOU(debtTokenAddress);
    }

    function updateStateWithDeposit(
        address depositor,
        address asset,
        uint256 enterQuantity /* onlyLendingPool */
    ) public returns (bool success, uint256 depositQuantity) {
        ReserveData storage reserve = _reserves[asset]; // the reserve data for the asset

        // calculate the tokens that were received
        uint256 actualAssetBalance = IERC20(asset).balanceOf(address(this)); // the actual balance
        uint256 storedAssetBalance = reserve.totalAssetBalance; // the stored total balance
        uint256 balanceDifference = actualAssetBalance.sub(storedAssetBalance); // the tokens sent in
        require(balanceDifference >= enterQuantity, "ERR_INSUFFICIENT_DEPOSIT"); // fail early

        // update the actual reserve state balance
        reserve.totalAssetBalance = actualAssetBalance;

        // update depositor's state balance with the difference
        reserve.assetBalances[depositor] = reserve.assetBalances[depositor].add(balanceDifference);

        // mint the debt tokens
        _mintDebt(reserve, storedAssetBalance, depositor, balanceDifference);

        emit Deposited(depositor, asset, balanceDifference);
        return (true, balanceDifference);
    }

    function updateStateWithWithdraw(
        address withdrawer,
        address asset,
        uint256 exitQuantity /* onlyLendingPool */
    ) public returns (bool success, uint256 withdrawQuantity) {
        ReserveData storage reserve = _reserves[asset]; // the reserve data for the asset

        // calculate the tokens that were received
        uint256 actualDebtBalance = reserve.debtToken.balanceOf(address(this)); // the actual balance
        require(actualDebtBalance >= uint256(0), "ERR_ZERO_BAL_DEBT"); // fail early

        // mint the debt tokens
        (withdrawQuantity) = _burnDebt(
            reserve,
            reserve.totalAssetBalance,
            withdrawer,
            actualDebtBalance
        );

        // transfer asset tokens
        _transferAsset(asset, withdrawer, withdrawQuantity);

        emit Withdrawn(withdrawer, asset, exitQuantity);
        return (true, actualDebtBalance);
    }

    function updateStateWithBorrow(address to, address asset, uint quantity) external returns (bool) {
        ReserveData storage reserve = _reserves[asset];

        reserve.borrowBalances[to] = reserve.borrowBalances[to].add(quantity);
        return true;
    }

    function getBorrowBalance(address account, address asset) public view returns (uint) {
        ReserveData storage reserve = _reserves[asset];
        return reserve.borrowBalances[account];
    }

    function borrow(
        address borrower,
        address asset,
        uint256 borrowQuantity
    ) public {
        ReserveData storage reserve = _reserves[asset];
        require(reserve.totalAssetBalance >= borrowQuantity, "ERR_INSUFFICIENT_LIQUIDITY");
        _transferAsset(asset, borrower, borrowQuantity);
    }

    function _transferAsset(
        address asset,
        address to,
        uint256 quantity
    ) internal {
        IERC20(asset).safeTransfer(to, quantity);
    }

    function _mintDebt(
        ReserveData storage reserve,
        uint256 totalAssetBalance,
        address to,
        uint256 mintQuantity
    ) internal {
        // Mint LP tokens proportional to the Total LP Supply and Total Pool Balance.
        uint256 totalSupply = reserve.debtToken.totalSupply();

        // If liquidity is not intiialized, mint the initial liquidity.
        if (totalSupply == 0 || totalAssetBalance == 0) {
            mintQuantity = mintQuantity;
        } else {
            mintQuantity = mintQuantity.mul(totalSupply).div(totalAssetBalance);
        }

        require(mintQuantity > uint256(0), "ERR_ZERO_LIQUIDITY");
        reserve.debtToken.mint(to, mintQuantity);
    }

    function _burnDebt(
        ReserveData storage reserve,
        uint256 totalAssetBalance,
        address to,
        uint256 burnQuantity
    ) internal returns (uint256 receiveQuantity) {
        require(reserve.debtToken.balanceOf(to) >= burnQuantity, "ERR_BURN_QUANTITY");
        uint256 totalSupply = reserve.debtToken.totalSupply();

        // Calculate output amounts.
        receiveQuantity = burnQuantity.mul(totalAssetBalance).div(totalSupply);
        require(receiveQuantity > uint256(0), "ERR_ZERO");
        // Burn tokenPULP.
        reserve.debtToken.burn(to, burnQuantity);
    }
}
