const bre = require("@nomiclabs/buidler");
const { parseEther } = bre.ethers.utils;
const LendingPool = require("../artifacts/LendingPool.json");
const Reserve = require("../artifacts/Reserve.json");
const PToken = require("../artifacts/PToken.json");
const IOU = require("../artifacts/IOU.json");
const BFactory = require("../artifacts/BFactory.json");
const BPool = require("../artifacts/BPool.json");
const BPoolTemplateLib = require("../artifacts/BPoolTemplateLib.json");
const { formatEther, parseUnits } = require("ethers/lib/utils");
const { deployContract, link } = require("ethereum-waffle");
const { setupTokens, setupMultipleContracts, batchApproval, setupLendingProtocol, setupDebtToken } = require("./setup.js");

const ethers = bre.ethers;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("Reserve/Lending Contract", () => {
    let wallets, Admin, Alice, lending, reserve, asset, trader, debtToken;
    let ether, dai, iou;
    let risky, riskFree, pricing, factory, pfi;
    let s, k, o, t;

    const DENOMINATOR = 2 ** 64;

    before(async () => {
        // get wallets
        wallets = await newWallets();
        Admin = wallets[0];
        Alice = Admin._address;
        let tokens = await setupTokens();
        ether = tokens.ether;
        dai = tokens.dai;
        iou = tokens.iou;

        [lending, reserve, trader] = await setupMultipleContracts(["LendingPool", "Reserve", "Trader"]);
        await setupLendingProtocol(lending, reserve, trader);
        await setupDebtToken(reserve, dai, iou);
        
        // pool stuff
        
        await dai.approve(lending.address, parseEther("100000000000000"));
        await dai.approve(lending.address, parseEther("100000000000000"));

        // get pricing contract, could be a library tbh
        pricing = await ethers.getContractFactory("Pricing");
        pricing = await pricing.deploy();

        // get parameters, s = spot = x, k = strike, o = sigma = volatility, t = T until expiry
        s = parseEther("101");
        k = parseEther("100");
        o = 100;
        t = 31449600; //one year

        // get balancer factory
        let templateLib = await deployContract(Admin, BPoolTemplateLib, [], {
            gasLimit: 9000000,
        });
        let factoryContract = Object.assign(BFactory, {
            evm: { bytecode: { object: BFactory.bytecode } },
        });
        link(
            factoryContract,
            "balancer-core/contracts/BPoolTemplateLib.sol:BPoolTemplateLib",
            templateLib.address
        );
        factory = await ethers.getContractFactory(
            factoryContract.abi,
            factoryContract.evm.bytecode,
            Admin
        );
        factory = await factory.deploy();
        await factory.deployBPoolTemplate();

        // get primitive wrapper
        pfi = await ethers.getContractFactory("PFactory");
        pfi = await pfi.deploy();
        await pfi.initialize(factory.address, ether.address, dai.address);
    });

    describe("Test Reserve Functions", () => {
        it("initializes with enter()", async () => {
            await lending.enter(Alice, dai.address, parseEther("1"));
        });

        it("calls enter() after initialized 2", async () => {
            await lending.enter(Alice, dai.address, parseEther("1"));
            await lending.enter(Alice, dai.address, parseEther("1"));
            await lending.enter(Alice, dai.address, parseEther("1"));
            await lending.enter(Alice, dai.address, parseEther("1"));
            await lending.enter(Alice, dai.address, parseEther("1"));
            await lending.enter(Alice, dai.address, parseEther("1"));
        });

        it("calls updateState() directly", async () => {
            await dai.transfer(reserve.address, parseEther("10"));
            await reserve.updateStateWithDeposit(Alice, dai.address, parseEther("5"));
        });
    });

    describe("buyOption", () => {
        it("should buy an option", async () => {
            // deploys then initializes pool
            await pfi.deployPool();
            await pfi.approvePool();
            // approves assets to be transferred into pool
            await ether.approve(pfi.address, parseEther("1000000000"));
            await dai.approve(pfi.address, parseEther("1000000000"));
            await ether.approve(trader.address, parseEther("1000000000"));
            await dai.approve(trader.address, parseEther("1000000000"));
            // gets the pool instance
            let address = await pfi.bPool();
            pool = new ethers.Contract(address, BPool.abi, Admin);
            // gets the weights and amounts then transfers them into the pool
            let weights = await pricing.getWeights(s, k, o, t);
            let amounts = await pfi.getAmounts(weights.riskyW, weights.riskFW);
            await ether.transfer(pfi.address, amounts.riskyAmount);
            await dai.transfer(pfi.address, amounts.riskFreeAmount);
            // initializes with weights and finalizes it
            await pfi.connect(Admin).updateWeights(s, k, o, t, { from: Alice });
            await pfi.finalizePool(pool.address);
            // adds a debtToken for the risky asset
            await reserve.updateStateWithDebtToken(ether.address, iou.address);
            // transfers assets to the reserve so we can borrow them
            await ether.transfer(reserve.address, parseEther("10"));
            await reserve.updateStateWithDeposit(Alice, ether.address, parseEther("5"));
            // updates reserve with a debt token for the risky asset
            let optionBal = await pool.balanceOf(trader.address);
            let riskyBal = await ether.balanceOf(Alice);
            let riskFreeBal = await dai.balanceOf(Alice);
            console.log(optionBal.toString(), formatEther(await pool.balanceOf(Alice)));
            console.log(formatEther(riskyBal), formatEther(riskFreeBal));
            await trader.buyOption(pool.address, parseEther("1"));
            

            await pool.exitPool(await pool.balanceOf(Alice), [0,0]);
            riskyBal = (await ether.balanceOf(Alice)).sub((riskyBal));
            riskFreeBal = (await dai.balanceOf(Alice)).sub((riskFreeBal));
            console.log(formatEther(await pool.balanceOf(Alice)));
            console.log(formatEther(riskyBal), formatEther(riskFreeBal));
        });
    });
});
