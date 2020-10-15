const bre = require("@nomiclabs/buidler");
const { assert, expect } = require("chai");
const chai = require("chai");
const { solidity } = require("ethereum-waffle");
chai.use(solidity);
const { parseEther } = bre.ethers.utils;
const setup = require("./setup.js");
const {
    setupTokens,
    setupMultipleContracts,
    batchApproval,
    setupLendingProtocol,
    linkDebtToken,
    setupOptionProtocol,
    setupOptionPool,
    calibratePool,
    getMultipleBalances,
    setupDebtToken,
    getStateOfPool,
} = setup;

const ethers = bre.ethers;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("OptionPool.sol", () => {
    let wallets, Admin, Alice, lending, reserve, asset, trader, debtToken, pool, priceProvider;
    let ether, dai, iEther, iDai, iPool;
    let risky, riskFree, pricing, poolFactory, primitiveFactory;
    let s, k, o, t;
    let etherBalance, daiBalance, iEtherBalance, iDaiBalance;

    const DENOMINATOR = 2 ** 64;

    before(async () => {
        // get wallets
        wallets = await newWallets();
        Admin = wallets[0];
        Alice = Admin._address;
        // standard erc20s with mint functions
        // iou mappings at a 1:1 ratio with undelying asset. Deposit 1 ether => get 1 iEther
        [ether, dai] = await setupTokens();

        // pricing is the black-scholes library, primitiveFactory deploys the option pools
        [pricing, primitiveFactory, priceProvider] = await setupMultipleContracts([
            "Pricing",
            "OptionsController",
            "ProxyPriceProvider",
        ]);

        // get parameters, s = spot = x, k  = strike, o = sigma = volatility, t = T until expiry
        s = parseEther("101");
        k = parseEther("100");
        o = 100;
        t = 31449600; //one year

        // get the actual Bpool factory
        poolFactory = await setupOptionProtocol(Admin);
        await priceProvider.setTestPrice(parseEther("105"));

        // get the first pool that was deployed
        pool = await setupOptionPool(
            primitiveFactory,
            priceProvider,
            poolFactory,
            ether,
            dai,
            Admin
        );

        // approve tokens
        let contractsToApprove = [primitiveFactory];
        let tokensToBeApproved = [ether, dai, pool];
        let ownersToApprove = [Admin];
        await batchApproval(contractsToApprove, tokensToBeApproved, ownersToApprove);

        // initial balances
        [etherBalance, daiBalance, poolBalance] = await getMultipleBalances(
            tokensToBeApproved,
            Alice
        );
    });

    describe("joinPool", () => {
        it("should join the pool", async () => {
            let state1 = await setup.getRawStateOfPool(pool, priceProvider, pricing, Alice);
            await pool.joinPool(parseEther("1"), [parseEther("10000"), parseEther("100000")]);
            let state2 = await setup.getRawStateOfPool(pool, priceProvider, pricing, Alice);
            let stateChange = await setup.getStateChangeOfPool(state1, state2);
            console.log("initial state then join with 1", stateChange);

            let state5 = await setup.getStateOfPool(pool, priceProvider, pricing, Alice);
            console.log(state5);

            await priceProvider.setTestPrice(parseEther("103"));

            let state3 = await setup.getRawStateOfPool(pool, priceProvider, pricing, Alice);
            await pool.joinPool(parseEther("1"), [parseEther("10000"), parseEther("100000")]);
            let state4 = await setup.getRawStateOfPool(pool, priceProvider, pricing, Alice);
            let stateChange2 = await setup.getStateChangeOfPool(state3, state4);
            console.log("change asset spot price to 103 then add 1", stateChange2);
            let stateChange3 = await setup.getStateChangeOfPool(state1, state4);
            console.log("big change", stateChange3);
        });
    });
});
