pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Proxy Oracle contract to manage data feeds.
 * @author Primitive
 */

import { IAggregator } from "../interfaces/IAggregator.sol";
import { Ownable } from "../utils/Ownable.sol";

contract ProxyPriceProvider is Ownable {
    address public controller;

    uint256 public testPrice;

    mapping(address => IAggregator) private assetPriceProvider;

    event AssetPriceProvidersUpdated(address indexed asset, address indexed source);

    // Pseudo Constructor

    /**
     * @dev Initializes the state of the contract with a controller and asset => source mapping.
     */
    function initialize(
        address controllerAddress,
        address[] memory assetAddresses,
        address[] memory sourceAddresses,
        address fallbackOracleAddress
    ) public onlyOwner {
        require(controller == address(0x0), "ERR_INITIALIZED");
        controller = controllerAddress;
        _setAssetSources(assetAddresses, sourceAddresses);
    }

    // Governance functions

    /**
     * @dev External function for owner to set the asset price source mapping.
     */
    function setAssetSources(address[] calldata assetAddresses, address[] calldata sourceAddresses)
        external
        onlyOwner
    {
        _setAssetSources(assetAddresses, sourceAddresses);
    }

    /**
     * @dev Internal function that sets the mapping.
     */
    function _setAssetSources(address[] memory assetAddresses, address[] memory sourceAddresses)
        internal
    {
        uint256 assetsLength = assetAddresses.length;
        require(assetsLength == sourceAddresses.length, "ERR_PARAMS_LENGTH");
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = assetAddresses[i];
            address source = sourceAddresses[i];
            assetPriceProvider[asset] = IAggregator(source);
            emit AssetPriceProvidersUpdated(asset, source);
        }
    }

    /**
     * @dev Gets the asset price of an asset address, provided by the mapped source.
     */
    function getAssetPrice(address assetAddress) public view returns (uint256 price) {
        IAggregator source = assetPriceProvider[assetAddress];
        if (address(source) == address(0x0)) {
            price = testPrice;
        } else {
            int256 providedPrice = source.latestAnswer();
            if (providedPrice > 0) {
                price = uint256(providedPrice);
            }
        }
    }

    function setTestPrice(uint256 testPrice_) external {
        testPrice = testPrice_;
    }

    function getAssetVolatility(address assetAddress) public view returns (uint256 volatility) {
        volatility = 100;
    }

    /**
     * @dev Gets the prices for an array of addresses.
     */
    function getAssetPriceList(address[] calldata assetAddresses)
        external
        view
        returns (uint256[] memory prices)
    {
        uint256 assetsLength = assetAddresses.length;
        prices = new uint256[](assetsLength);
        for (uint256 i = 0; i < assetsLength; i++) {
            prices[i] = getAssetPrice(assetAddresses[i]);
        }
    }

    /**
     * @dev Gets the asset price provider source address.
     */
    function getAssetSource(address assetAddress) external view returns (address source) {
        source = address(assetPriceProvider[assetAddress]);
    }
}
