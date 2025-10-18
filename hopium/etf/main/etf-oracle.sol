// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/types/etf.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/uniswap/interface/imUniswapOracle.sol";
import "hopium/common/types/bips.sol";
import "hopium/common/lib/full-math.sol";
import "hopium/common/interface-ext/iErc20Metadata.sol";
import "hopium/etf/interface/iEtfOracle.sol";

abstract contract Storage {
    uint256 internal constant WAD = 1e18;
}

abstract contract Utils is ImUniswapOracle, Storage {
    /// @dev 10**exp with safety guard. 10**78 overflows uint256.
    function _pow10(uint8 exp) internal pure returns (uint256) {
        require(exp <= 77, "pow10 overflow");
        // unchecked is fine due to the guard
        unchecked { return 10 ** uint256(exp); }
    }

    /// @dev Scale arbitrary decimals to 1e18 without overflow using mulDiv.
    function _scaleTo1e18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) {
            // amount * 1e18 / 10^dec
            return FullMath.mulDiv(amount, WAD, _pow10(decimals));
        } else {
            // amount * 1e18 / 10^dec  == amount / 10^(dec-18)
            return amount / _pow10(decimals - 18);
        }
    }

    /// @dev Convert a WETH-denominated 1e18 amount to USD 1e18 using the oracle.
    ///      Returns 0 if either the amount or the oracle price is 0.
    function _convertWethToUsd(uint256 wethAmount18) internal view returns (uint256 usdAmount18) {
        if (wethAmount18 == 0) return 0;
        uint256 wethUsdPrice18 = getUniswapOracle().getWethUsdPrice(); // USD per 1 WETH, 1e18
        if (wethUsdPrice18 == 0) return 0;
        // USD = WETH * (USD/WETH)
        return FullMath.mulDiv(wethAmount18, wethUsdPrice18, WAD);
    }
}

abstract contract SnapshotHelpers is Utils, ImEtfFactory  {

    function _snapshotVault(Etf memory etf, address etfVault)
        internal
        view
        returns (Snapshot[] memory s, uint256 etfTvlWeth)
    {
        uint256 n = etf.assets.length;
        s = new Snapshot[](n);

        IUniswapOracle oracle = getUniswapOracle();

        // 1) Fill token info and values, and accumulate TVL
        unchecked {
            for (uint256 i = 0; i < n; ++i) {
                address t = etf.assets[i].tokenAddress;
                uint8   d = IERC20Metadata(t).decimals();
                uint256 bal = IERC20(t).balanceOf(etfVault);
                uint256 p   = oracle.getTokenWethPrice(t); // WETH per 1 token, 1e18

                // tokenValueWeth18 = bal * price / 10^dec
                uint256 v = (bal == 0 || p == 0) ? 0 : FullMath.mulDiv(bal, p, 10 ** d);

                s[i] = Snapshot({
                    tokenAddress:     t,
                    tokenDecimals:    d,
                    currentWeight:    0,          // set in pass #2
                    tokenRawBalance:  bal,
                    tokenPriceWeth18: p,
                    tokenValueWeth18: v
                });

                etfTvlWeth += v;
            }
        }

        // 2) Compute live weights as value share of TVL (in bips)
        if (etfTvlWeth > 0) {
            unchecked {
                for (uint256 i = 0; i < n; ++i) {
                    s[i].currentWeight = uint16(
                        (s[i].tokenValueWeth18 * HUNDRED_PERCENT_BIPS) / etfTvlWeth
                    );
                }
            }
        }
    }

    /// @dev USD-enhanced snapshot: and adds USD prices/values using the WETH->USD oracle conversion.
    function _snapshotVaultWithUsd(Etf memory etf, address etfVault)
        internal
        view
        returns (SnapshotWithUsd[] memory s, uint256 etfTvlWeth, uint256 etfTvlUsd)
    {
        (Snapshot[] memory snap, uint256 tvlWeth) = _snapshotVault(etf, etfVault);

        etfTvlWeth = tvlWeth;
        etfTvlUsd  = _convertWethToUsd(tvlWeth);

        uint256 n = snap.length;
        s = new SnapshotWithUsd[](n);

        unchecked {
            for (uint256 i = 0; i < n; ++i) {
                s[i] = SnapshotWithUsd({
                    tokenAddress:      snap[i].tokenAddress,
                    tokenDecimals:     snap[i].tokenDecimals,
                    currentWeight:     snap[i].currentWeight,
                    tokenRawBalance:   snap[i].tokenRawBalance,
                    tokenPriceWeth18:  snap[i].tokenPriceWeth18,
                    tokenPriceUsd18:   _convertWethToUsd(snap[i].tokenPriceWeth18),
                    tokenValueWeth18:  snap[i].tokenValueWeth18,
                    tokenValueUsd18:   _convertWethToUsd(snap[i].tokenValueWeth18)
                });
            }
        }
    }
}

abstract contract PriceHelpers is SnapshotHelpers {
    /// @dev Target-weighted (index) price in WETH (1e18).
    function _getEtfInitialPrice(Etf memory etf) internal view returns (uint256 priceWeth18) {
        uint256 sum; // (bips * 1e18)
        IUniswapOracle oracle = getUniswapOracle();

        unchecked {
            for (uint256 i = 0; i < etf.assets.length; ++i) {
                address token = etf.assets[i].tokenAddress;
                uint16  wBips = etf.assets[i].weightBips;

                // 1e18-scaled: WETH per 1 whole TOKEN
                uint256 p = oracle.getTokenWethPrice(token);
                if (p == 0 || wBips == 0) continue;

                sum += uint256(wBips) * p;
            }
        }
        // Divide by 100% in bips → 1e18 WETH per "index unit"
        return sum / HUNDRED_PERCENT_BIPS;
    }

    /// @dev Live NAV per whole ETF token in WETH (1e18):
    ///      ( Σ_i [ vaultBalance_i (raw) * price_i (WETH per whole token, 1e18) / 10^dec_i ] )
    ///      / ( ETF totalSupply (whole tokens) )
    function _getEtfWethPrice(uint256 etfId, Etf memory etf, address etfVault) internal view returns (uint256) {
        // Resolve addresses
        address etfToken = getEtfFactory().getEtfTokenAddress(etfId);

        // Supply in whole-token terms
        uint256 rawSupply = IERC20(etfToken).totalSupply();
        uint8   etfDec   = IERC20Metadata(etfToken).decimals();
        if (rawSupply == 0) {
            // No supply yet → use index price
            return _getEtfInitialPrice(etf);
        }
        uint256 supplyWhole18 = _scaleTo1e18(rawSupply, etfDec); // #whole ETF tokens, 1e18-scaled
        if (supplyWhole18 == 0) return 0;

        // Sum vault holdings valued in WETH (1e18)
        uint256 totalWethValue18 = _getEtfTvlWeth(etf, etfVault);

        // NAV per whole ETF token (1e18) = totalWethValue18 / (#whole ETF tokens)
        return FullMath.mulDiv(totalWethValue18, WAD, supplyWhole18);
    }

    /// @dev Total vault value in WETH (1e18) across all ETF assets.
    function _getEtfTvlWeth(Etf memory etf, address etfVault) internal view returns (uint256 totalWethValue18) {
        IUniswapOracle oracle = getUniswapOracle();

        unchecked {
            // Sum vault holdings valued in WETH (1e18)
            for (uint256 i = 0; i < etf.assets.length; ++i) {
                address token = etf.assets[i].tokenAddress;

                uint256 bal = IERC20(token).balanceOf(etfVault); // raw units
                if (bal == 0) continue;

                // WETH per 1 whole token (1e18)
                uint256 wethPerToken18 = oracle.getTokenWethPrice(token);
                if (wethPerToken18 == 0) continue;

                // value = bal(raw) * price(1e18) / 10^dec
                uint8 dec = IERC20Metadata(token).decimals();
                uint256 denom = _pow10(dec);

                totalWethValue18 += FullMath.mulDiv(bal, wethPerToken18, denom);
            }
        }
    }
    
}

abstract contract EtfStats is PriceHelpers {

    struct EthUsd {
        uint256 eth18; // value in WETH (1e18)
        uint256 usd18; // value in USD  (1e18)
    }
    
    struct Stats {
        EthUsd  price;               // NAV per ETF token
        EthUsd  volume;              // cumulative volume since inception
        EthUsd  tvl;                 // vault TVL
        uint256 assetsLiquidityUsd;  // sum of TOKEN–WETH pool liquidity (USD, 1e18)
        uint256 assetsMcapUsd;       // sum of token market caps (USD, 1e18)
    }

    /// @dev Generic helper to sum a per-token USD metric across all ETF assets.
    ///      Accepts a function pointer of type (address) → (uint256).
    ///      Wrapped in try/catch so missing pools won’t revert.
    function _sumPerAsset(Etf memory etf, function (address) external view returns (uint256) fn) internal view returns (uint256 sum) {
        unchecked {
            for (uint256 i = 0; i < etf.assets.length; ++i) {
                address token = etf.assets[i].tokenAddress;
                try fn(token) returns (uint256 value) {
                    sum += value;
                } catch { /* ignore if oracle call fails */ }
            }
        }
    }

    /// @notice Returns full ETF stats.
    function _getStats(uint256 etfId, Etf memory etf, address etfVault) internal view returns (Stats memory s) {
        IUniswapOracle uniO = getUniswapOracle();

        // 2. NAV per ETF token
        uint256 priceEth18 = _getEtfWethPrice(etfId, etf, etfVault);
        uint256 priceUsd18 = _convertWethToUsd(priceEth18);
        s.price = EthUsd({ eth18: priceEth18, usd18: priceUsd18 });

        // 3. Volume (from factory)
        (uint256 volWeth18, uint256 volUsd18) = getEtfFactory().getEtfTotalVolume(etfId);
        s.volume = EthUsd({ eth18: volWeth18, usd18: volUsd18 });

        // 4. TVL (vault holdings)
        uint256 tvlEth18 = _getEtfTvlWeth(etf, etfVault);
        uint256 tvlUsd18 = _convertWethToUsd(tvlEth18);
        s.tvl = EthUsd({ eth18: tvlEth18, usd18: tvlUsd18 });

        // 5. Aggregated per-asset stats
        s.assetsLiquidityUsd = _sumPerAsset(etf, uniO.getTokenLiquidityUsd);
        s.assetsMcapUsd      = _sumPerAsset(etf, uniO.getTokenMarketCapUsd);
    }
}


contract EtfOracle is ImDirectory, PriceHelpers, EtfStats {

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Current NAV per ETF token in WETH (1e18).
    function getEtfWethPrice(uint256 etfId) external view returns (uint256) {
        (Etf memory etf, address vaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);
        return _getEtfWethPrice(etfId, etf, vaultAddress);
    }

    /// @notice Current NAV per ETF token in USD (1e18).
    /// @dev Uses the internal _convertWethToUsd helper for conversion.
    function getEtfUsdPrice(uint256 etfId) external view returns (uint256) {
        (Etf memory etf, address vaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);
        uint256 etfWethPrice18 = _getEtfWethPrice(etfId, etf, vaultAddress);
        return _convertWethToUsd(etfWethPrice18);
    }

    function getEtfPrice(uint256 etfId) external view returns (uint256 wethPrice18, uint256 usdPrice18) {
        (Etf memory etf, address vaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);
        wethPrice18 = _getEtfWethPrice(etfId, etf, vaultAddress);
        usdPrice18 = _convertWethToUsd(wethPrice18);
    }

    function snapshotVault(uint256 etfId) external view returns (Snapshot[] memory s, uint256 etfTvlWeth) {
        (Etf memory etf, address vaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);
        return _snapshotVault(etf, vaultAddress);
    }

    function snapshotVaultUnchecked(Etf memory etf, address vaultAddress) external view returns (Snapshot[] memory s, uint256 etfTvlWeth) {
        return _snapshotVault(etf, vaultAddress);
    }

    function snapshotVaultWithUsd(uint256 etfId) external view returns (SnapshotWithUsd[] memory s, uint256 etfTvlWeth, uint256 etfTvlUsd) {
        (Etf memory etf, address vaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);
        return _snapshotVaultWithUsd(etf, vaultAddress);
    }

    function getEtfStats(uint256 etfId) external view returns (Stats memory s) {
        (Etf memory etf, address etfVault) = getEtfFactory().getEtfByIdAndVault(etfId);
        return _getStats(etfId, etf, etfVault);
    }

    function getEtfDetails(uint256 etfId) external view returns (Etf memory etf, Stats memory st, SnapshotWithUsd[] memory sn, uint256 etfTvlWeth, uint256 etfTvlUsd) {
        address etfVault;
        (etf, etfVault) = getEtfFactory().getEtfByIdAndVault(etfId);
        st = _getStats(etfId, etf, etfVault);
        (sn, etfTvlWeth, etfTvlUsd) = _snapshotVaultWithUsd(etf, etfVault);
    }
}