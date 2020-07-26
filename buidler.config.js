usePlugin("@nomiclabs/buidler-waffle");
usePlugin("@nomiclabs/buidler-ethers");
usePlugin("@nomiclabs/buidler-solhint");
usePlugin("buidler-gas-reporter");

// This is a sample Buidler task. To learn how to create your own go to
// https://buidler.dev/guides/create-task.html
task("accounts", "Prints the list of accounts", async () => {
    const accounts = await ethers.getSigners();

    for (const account of accounsolhts) {
        console.log(await account.getAddress());
    }
});

// You have to export an object to set up your config
// This object can have the following optional entries:
// defaultNetwork, networks, solc, and paths.
// Go to https://buidler.dev/config/ to learn more
module.exports = {
    networks: {
        local: {
            url: "http://127.0.0.1:8545",
            gasPrice: 80000000000,
            gas: 10000000,
            timeout: 1000000,
        },
    },
    gasReporter: {
        currency: "USD",
        showTimeSpent: true,
        enabled: true,
        currency: "USD",
    },
    // This is a sample solc configuration that specifies which version of solc to use
    solc: {
        version: "0.5.12",
        optimizer: {
            enabled: true,
            runs: 100,
        },
    },
};
