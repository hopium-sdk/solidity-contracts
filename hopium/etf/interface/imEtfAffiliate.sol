// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/types/etf.sol";

interface IEtfAffiliate {
    function getAffiliateOwner(string calldata code) external view returns (address);
    function emitFeeTransferredEvent(string calldata code, uint256 ethAmount) external;
}

abstract contract ImEtfAffiliate is ImDirectory {

    function getEtfAffiliate() internal view virtual returns (IEtfAffiliate) {
        return IEtfAffiliate(fetchFromDirectory("etf-affiliate"));
    }

}