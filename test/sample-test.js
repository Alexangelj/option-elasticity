const bre = require("@nomiclabs/buidler");
const { expect } = require("chai");
const Pricing = require("../artifacts/Pricing.json");
const { parseEther } = bre.ethers.utils;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("Greeter", function () {
    it("Should return the new greeting once it's changed", async function () {
        const pricing = await ethers.getContractFactory("Pricing");
        const _pricing = await pricing.deploy();
        let ATM = await _pricing.calculateATM(100, 1, 1);
        console.log(ATM);
    });
});

describe("Pricing Contract", () => {
    let pricing;
    let s, k, o, t;

    let wallets, Admin, Alice;

    before(async () => {
        wallets = await newWallets();
        Admin = wallets[0];
        Alice = Admin._address;
        const _pricing = await ethers.getContractFactory("Pricing");
        pricing = await _pricing.deploy();
        s = parseEther("101");
        k = parseEther("100");
        o = 100;
        t = 31449600; //one year
    });

    describe("Test ATM", () => {
        it("Tests the ATM function", async () => {
            let atm = await pricing.calculateATM(s, o, t);
            console.log("ATM", atm.toString());
        });

        it("Tests the sq function", async () => {
            let sq = await pricing.square(2);
            console.log("sq", sq.toString());
        });

        it("Tests the ndnumerator function", async () => {
            let d1 = await pricing.auxiliary(s, k, o, t);
            let ndnumerator = await pricing.ndnumerator(d1);
            ndnumerator = await pricing._fromInt(ndnumerator);
            console.log("ndnumerator", ndnumerator.toString());
        });

        it("Tests the nddenominator function", async () => {
            let d1 = await pricing.auxiliary(s, k, o, t);
            let nddenominator = await pricing.nddenominator(d1);
            nddenominator = await pricing._fromInt(nddenominator);
            console.log("nddenominator", nddenominator.toString());
        });

        it("Tests the d1 function", async () => {
            let d1 = await pricing.auxiliary(s, k, o, t);
            d1 = await pricing._fromInt(d1);
            console.log("d1", d1.toString());
            let moneyness = await pricing.getMoneyness(s, k);
            moneyness = await pricing._fromInt(moneyness);
            console.log("moneyness", moneyness.toString());
        });

        it("Tests the d2 function", async () => {
            let d2 = await pricing.auxiliary2(s, k, o, t);
            d2 = await pricing._fromInt(d2);
            console.log("d2", d2.toString());
        });

        it("Tests the normdist function", async () => {
            let z = await pricing.auxiliary(s, k, o, t);
            let normdist = await pricing.normdist(z);
            normdist = await pricing._fromInt(normdist);
            let z2 = await pricing.auxiliary2(s, k, o, t);
            let normdist2 = await pricing.normdist(z2);
            normdist2 = await pricing._fromInt(normdist2);
            console.log("normdist", normdist.toString());
            console.log("normdist2", normdist2.toString());
        });

        it("Tests the bs function", async () => {
            let bs = await pricing.bs(s, k, o, t);
            bs = await pricing._fromInt(bs);
            console.log("bs", bs.toString());
        });

        it("Tests the price function", async () => {
            let extrinsic = await pricing.extrinsic(s, k, o, t);
            console.log("PRICE", extrinsic.toString());
        });
    });

    describe("Test SQRT", () => {
        it("Tests the sqrt function branches", async () => {});
    });
});
