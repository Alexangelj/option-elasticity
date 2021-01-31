const bre = require("@nomiclabs/buidler");
const ethers = bre.ethers;

class Pool {
    chainId;
    address;

    constructor(symbol, name, initialSupply) {
        this.symbol = symbol;
        this.name = name;
        this.initialSupply = initialSupply;
    }

    intialize = async () => {
        this.defaultProvider = await ethers.getDefaultProvider();
        this.signer = (await ethers.getSigners())[0];
        let factory = await ethers.getContractFactory("TestToken");
        this.contract = await factory.deploy(name, symbol, initialSupply);
        this.address = this.contract.address;
    };

    get contract() {
        return this.contract;
    }

    get address() {
        return this.address;
    }

    async balanceOf(address) {
        return await this.contract.balanceOf(address);
    }
}

Object.assign(module.exports, { Pool });
