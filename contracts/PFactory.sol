pragma solidity >=0.5.12 <=0.6.2;

import { Pricing } from "./Pricing.sol";
import { IBFactory } from "./interfaces/IBFactory.sol";
import { IBPool } from "./interfaces/IBPool.sol";
import { IERC20 } from "./tokens/ERC20.sol";
import { SafeMath } from "./libraries/SafeMath.sol";
import "@nomiclabs/buidler/console.sol";

contract PFactory {
    using SafeMath for uint;
    IBFactory public bFactory;
    IBPool public bPool;
    IERC20 public risky;
    IERC20 public riskFree;

    constructor() public {}

    function initialize(
        address _bFactory,
        address _risky,
        address _riskFree
    ) public {
        bFactory = IBFactory(_bFactory);
        risky = IERC20(_risky);
        riskFree = IERC20(_riskFree);
    }

    function deployPool() public returns (IBPool pool) {
        pool = bFactory.newBPool(1);
        bPool = pool;
    }

    function setController(address newController) public {
        bPool.setController(newController);
    }

    function finalizePool(address poolAddress) public {
        IBPool(poolAddress).finalize();
    }

    function approvePool() public {
        risky.approve(address(bPool), uint256(-1));
        riskFree.approve(address(bPool), uint256(-1));
    }

    function getAmounts(uint256 riskyWeight, uint256 riskFreeWeight)
        public
        pure
        returns (uint256 riskyAmount, uint256 riskFreeAmount)
    {
        uint256 riskyPrice = 100 ether; // 1 per 100
        uint256 riskFreePrice = 10000 ether; //
        // 100 * 10 ^ 18, 5.6 * 10 ^ 18. 100 / 5.6 = 17.85
        riskyAmount = riskyPrice.mul(riskyWeight).div(1 ether);
        riskFreeAmount = riskFreePrice.mul(riskFreeWeight).div(1 ether);
    }

    function initializePool(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public {
        (uint256 riskyW, uint256 riskFW) = Pricing.getWeights(s, k, o, t);
        (uint256 riskyAmount, uint256 riskFreeAmount) = getAmounts(riskyW, riskFW);
        risky.transferFrom(msg.sender, address(this), riskyAmount);
        riskFree.transferFrom(msg.sender, address(this), riskFreeAmount);
        bPool.bind(address(risky), riskyAmount, riskyW.mul(25));
        bPool.bind(
            address(riskFree),
            riskFreeAmount,
            riskFW.mul(25) // bone == 50, 25 == half
        );
    }

    function updateWeights(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public {
        (uint256 riskyW, uint256 riskFW) = Pricing.getWeights(s, k, o, t);
        (uint256 riskyAmount, uint256 riskFreeAmount) = getAmounts(riskyW, riskFW);
        bPool.bind(address(risky), riskyAmount, riskyW.mul(25));
        bPool.bind(
            address(riskFree),
            riskFreeAmount,
            riskFW.mul(25) // bone == 50, 25 == half
        );
    }
}
