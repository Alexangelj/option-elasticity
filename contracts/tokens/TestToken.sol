pragma solidity >=0.5.12 <=0.6.2;

import { ERC20, IERC20 } from "./ERC20.sol";

contract TestToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply
    ) public ERC20 {
        _mint(msg.sender, totalSupply);
        name = name_;
        symbole = symbol_;
    }

    function mint(address to, uint256 amount) public returns (bool) {
        _mint(to, amount);
        return true;
    }
}
