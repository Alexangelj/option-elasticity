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
} = require("./setup.js");

const ethers = bre.ethers;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("Reserve/Lending Contract", () => {
    let wallets, Admin, Alice, lending, reserve, asset, trader, debtToken;
    let ether, dai, iEther, iDai, iPool;
    let risky, riskFree, pricing, poolFactory, pfi;
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
        [ether, dai, iEther, iDai] = await setupTokens();

        // gets contract factory for the contract names then calls deploy() on them
        [lending, reserve, trader, pricing, pfi] = await setupMultipleContracts([
            "LendingPool",
            "Reserve",
            "Trader",
            "Pricing",
            "PFactory",
        ]);
        // calls initialize() on each of the contracts, passing their addresses to eachother
        await setupLendingProtocol(lending, reserve, trader);
        // links an asset to a debt token with a 1:1 mapping.
        await linkDebtToken(reserve, dai, iDai);
        await linkDebtToken(reserve, ether, iEther);

        // get parameters, s = spot = x, k = strike, o = sigma = volatility, t = T until expiry
        s = parseEther("101");
        k = parseEther("100");
        o = 100;
        t = 31449600; //one year

        // get the actual pool factory
        poolFactory = await setupOptionProtocol(Admin);

        // get the first pool that was deployed
        pool = await setupOptionPool(pfi, poolFactory, ether, dai, Admin);
        iPool = await setupDebtToken();
        await linkDebtToken(reserve, pool, iPool);

        // approve tokens
        let contractsToApprove = [lending, reserve, trader, pfi];
        let tokensToBeApproved = [ether, dai, iEther, iDai, pool];
        let ownersToApprove = [Admin];
        await batchApproval(contractsToApprove, tokensToBeApproved, ownersToApprove);

        // initial balances
        [etherBalance, daiBalance, iEtherBalance, iDaiBalance] = await getMultipleBalances(
            tokensToBeApproved,
            Alice
        );
    });

    describe("Test Reserve Functions", () => {
        it("initializes with enter()", async () => {
            await lending.enter(Alice, dai.address, parseEther("1"));
        });

        it("calls enter() multiple times in a row", async () => {
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
            // gets the weights and amounts then transfers them into the pool
            // initializes with weights and finalize the pool
            await calibratePool(Admin, pool, pricing, pfi, ether, dai, s, k, o, t);
            // transfers assets to the reserve so we can borrow them
            await lending.enter(Alice, ether.address, parseEther("10"));

            // gets balances
            let optionBal = await pool.balanceOf(trader.address);
            let riskyBal = await ether.balanceOf(Alice);
            let riskFreeBal = await dai.balanceOf(Alice);

            // purchases an option using borrowed ether + premium
            await trader.buyOption(pool.address, parseEther("1"));
            console.log(
                formatEther(await pool.balanceOf(reserve.address)),
                formatEther(await iPool.balanceOf(Alice))
            );

            const debtArray = [
                ["Alice", Alice],
                ["Reserve", reserve.address],
                ["Lending", lending.address],
                ["Trader", trader.address],
            ];
            async function getDebtBalances(array) {
                for (i = 0; i < array.length; i++) {
                    let name = array[i][0];
                    let account = array[i][1];
                    let bal = await iPool.balanceOf(account);
                    console.log(name, await iPool.symbol(), formatEther(bal));
                }
            }

            await getDebtBalances(debtArray);

            let borrowed = await reserve.getBorrowBalance(Alice, ether.address);
            console.log(formatEther(borrowed));
        });
    });
});
