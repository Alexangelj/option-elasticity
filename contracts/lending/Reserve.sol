pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Stateful Reserve Pool
 * @author Primitive
 */

import { ILendingPool } from "../interfaces/ILendingPool.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeMath } from "../libraries/SafeMath.sol";
import { ABDKMath64x64 } from "../libraries/ABDKMath64x64.sol";
import { Ownable } from "../utils/Ownable.sol";
import "@nomiclabs/buidler/console.sol";

contract Reserve is Ownable {
    using SafeMath for uint256;
    using ABDKMath64x64 for *;

    int128 public constant MANTISSA = 2**64;
    uint128 public constant DENOMINATOR = 10**18;

    ILendingPool public lendingPool;

    struct ReserveData {
        mapping(address => int128) assetBalances;
        mapping(address => int128) borrowBalances;
        mapping(address => int128) collateralBalances;
        int128 totalAssetBalance;
        bool isBorrowingEnabled;
        bool isActive;
        bool isFrozen;
    }

    mapping(address => ReserveData) internal _reserves;

    event Deposited(address indexed from, address indexed asset, uint256 depositQuantity);

    function initialize(address lendingPoolAddress) public onlyOwner {
        lendingPool = ILendingPool(lendingPoolAddress);
    }

    modifier onlyLendingPool {
        require(address(lendingPool) == msg.sender, "ERR_NOT_LENDING_POOL");
        _;
    }

    function updateStateWithDeposit(
        address depositor,
        address asset,
        uint256 enterQuantity
    ) public onlyLendingPool returns (bool success, uint256 depositQuantity) {
        ReserveData storage reserve = _reserves[asset]; // the reserve data for the asset
        uint256 actualAssetBalance = IERC20(asset).balanceOf(address(this)); // the actual balance
        // the actual balance less the stored balance
        uint256 balanceDifference = actualAssetBalance.sub(_fromInt(reserve.totalAssetBalance));
        //require(balanceDifference >= enterQuantity, "ERR_INSUFFICIENT_DEPOSIT"); // fail early

        // update the actual reserve balance
        reserve.totalAssetBalance = fromWeiToInt128(actualAssetBalance);

        // update depositors balance with the difference
        reserve.assetBalances[depositor] = reserve.assetBalances[depositor].add(
            fromWeiToInt128(uint256(2**128 - 1))
        );

        emit Deposited(depositor, asset, balanceDifference);
        return (true, balanceDifference);
    }

    function balanceOf(address account, address asset) public view returns (uint256) {
        ReserveData storage reserve = _reserves[asset];
        int128 balance = reserve.assetBalances[account];
        return fromIntToWei(balance);
    }

    function _fromInt(int128 x) public pure returns (uint256 y) {
        x = x.mul(MANTISSA);
        y = x > 0 ? ABDKMath64x64.toUInt(x) : uint256(0);
    }

    function fromIntToWei(int128 x) public pure returns (uint256 y) {
        y = _fromInt(x).mul(DENOMINATOR);
    }

    function fromWeiToInt128(uint256 x) public pure returns (int128) {
        return x.divu(DENOMINATOR);
    }
}
