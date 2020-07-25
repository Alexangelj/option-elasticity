const bre = require("@nomiclabs/buidler");
const { parseEther } = bre.ethers.utils;
const LendingPool = require("../artifacts/LendingPool.json");
const Reserve = require("../artifacts/Reserve.json");
const PToken = require("../artifacts/PToken.json");
const IOU = require("../artifacts/IOU.json");
const { formatEther } = require("ethers/lib/utils");
const ethers = bre.ethers;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("Reserve/Lending Contract", () => {
    let pricing;
    let s, k, o, t;

    let wallets, Admin, Alice, lending, reserve, asset, iou;

    const DENOMINATOR = 2 ** 64;

    before(async () => {
        // get wallets
        wallets = await newWallets();
        Admin = wallets[0];
        Alice = Admin._address;
        asset = await ethers.getContractFactory("PToken");
        asset = await asset.deploy("Test Asset", "ASSET", parseEther("1000"));
        lending = await ethers.getContractFactory("LendingPool");
        lending = await lending.deploy();
        reserve = await ethers.getContractFactory("Reserve");
        reserve = await reserve.deploy();
        iou = await ethers.getContractFactory("IOU");
        iou = await iou.deploy();
        await lending.initialize(reserve.address);
        await reserve.initialize(lending.address);
        await iou.initialize(reserve.address);
        await reserve.updateStateWithDebtToken(asset.address, iou.address);
        await asset.approve(lending.address, parseEther("100000000000000"));
    });

    describe("Test Reserve Functions", () => {
        /* it("initializes with enter()", async () => {
            await lending.enter(Alice, asset.address, parseEther("1"));
        });

        it("calls enter() after initialized 2", async () => {
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
        }); */

        it("calls updateState() directly", async () => {
            await asset.transfer(reserve.address, parseEther("10"));
            await reserve.updateStateWithDeposit(Alice, asset.address, parseEther("5"));
            /* await reserve.updateStateWithDeposit(Alice, asset.address, parseEther("5")); */
        });
    });
});
