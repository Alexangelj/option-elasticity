const bre = require("@nomiclabs/buidler");
const ethers = bre.ethers;

const deployOptionController = async (factory, token1, token2) => {
    // Deploy actual options controller contract.
    let contractFactory = await ethers.getContractFactory("OptionsController");
    let controller = await contractFactory.deploy();

    // Initialize it with a factory and pair of tokens, then deploy the core pool.
    await controller.initialize(factory.address, token1.address, token2.address);
    await controller.deployPool();
    await controller.approvePool();
    return controller;
};

module.exports = deployOptionController;
