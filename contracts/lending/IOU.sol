pragma solidity >=0.5.12 <=0.6.2;

import { IERC20, ERC20 } from "../tokens/ERC20.sol";
import { IReserve } from "../interfaces/IReserve.sol";

contract IOU is ERC20("Debt Instrument for Primitive", "IOU") {
    IReserve public reserve;

    function initialize(address reserveAddress) public {
        require(address(reserve) == address(0x0), "ERR_INTIIALIZED");
        reserve = IReserve(reserveAddress);
    }

    modifier onlyReserve {
        require(msg.sender == address(reserve), "ERR_NOT_RESERVE");
        _;
    }

    function mint(address to, uint256 quantity) external onlyReserve returns (bool) {
        _mint(to, quantity);
        return true;
    }

    function burn(address to, uint256 quantity) external onlyReserve returns (bool) {
        _burn(to, quantity);
        return true;
    }
}
