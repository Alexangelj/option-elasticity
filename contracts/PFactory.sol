pragma solidity >=0.5.12 <=0.6.2;

import { Pricing } from "./Pricing.sol";
import { BFactory } from "../balancer-core/contracts/BFactory.sol";
import { BPool } from "../balancer-core/contracts/BPool.sol";
import { ERC20, IERC20 } from "./tokens/ERC20.sol";
import "@nomiclabs/buidler/console.sol";

contract PFactory is Pricing {
    BFactory public bFactory;
    BPool public bPool;
    IERC20 public risky;
    IERC20 public riskFree;

    constructor() public {}

    function initialize(
        address _bFactory,
        address _risky,
        address _riskFree
    ) public {
        bFactory = BFactory(_bFactory);
        risky = IERC20(_risky);
        riskFree = IERC20(_riskFree);
    }

    function deployPool() public returns (BPool pool) {
        pool = bFactory.newBPool();
        bPool = pool;
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
        uint256 riskyPrice = 100 ether; // $100
        uint256 riskFreePrice = 1 ether; // $1
        // 100 * 10 ^ 18, 5.6 * 10 ^ 18. 100 / 5.6 = 17.85
        riskyAmount = riskyPrice.mul(riskyWeight).div(1 ether);
        riskFreeAmount = riskFreePrice.mul(riskFreeWeight).mul(riskyPrice).div(10**36);
    }

    function initializePool(
        uint256 s,
        uint256 k,
        uint256 o,
        uint256 t
    ) public {
        (uint256 riskyW, uint256 riskFW) = getWeights(s, k, o, t);
        (uint256 riskyAmount, uint256 riskFreeAmount) = getAmounts(riskyW, riskFW);
        //console.log(riskyAmount, riskFreeAmount, riskyW, riskFW);
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
        (uint256 riskyW, uint256 riskFW) = getWeights(s, k, o, t);
        (uint256 riskyAmount, uint256 riskFreeAmount) = getAmounts(riskyW, riskFW);
        bPool.bind(address(risky), riskyAmount, riskyW.mul(25));
        bPool.bind(
            address(riskFree),
            riskFreeAmount,
            riskFW.mul(25) // bone == 50, 25 == half
        );
    }
}
