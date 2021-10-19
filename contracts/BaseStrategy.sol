// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/Initializable.sol";

import "./lib/SettAccessControl.sol";

import "interfaces/badger/IStrategy.sol";
import "interfaces/badger/IVault.sol";

/*
    ===== Badger Base Strategy =====
    Common base class for all Sett strategies

    Changelog
    V1.1
    - Verify amount unrolled from strategy positions on withdraw() is within a threshold relative to the requested amount as a sanity check
    - Add version number which is displayed with baseStrategyVersion(). If a strategy does not implement this function, it can be assumed to be 1.0

    V1.2
    - Remove idle want handling from base withdraw() function. This should be handled as the strategy sees fit in _withdrawSome()
*/
abstract contract BaseStrategy is IStrategy, PausableUpgradeable, SettAccessControl {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    address public want; // Token used for deposits

    uint256 public performanceFeeGovernance;
    uint256 public performanceFeeStrategist;
    uint256 public withdrawalFee;

    uint256 public constant MAX_FEE = 10_000;

    address public vault;
    address public guardian;

    uint256 public withdrawalMaxDeviationThreshold;

    /// @notice percentage of rewards converted to want
    /// @dev converting of rewards to want during harvest should take place in this ratio
    /// @dev change this ratio if rewards are converted in a different percentage
    /// value ranges from 0 to 10_000
    /// 0: keeping 100% harvest in reward tokens
    /// 10_000: converting all rewards tokens to want token
    uint256 public autoCompoundRatio = 10_000;

    function __BaseStrategy_init(
        address _governance,
        address _strategist,
        address _vault,
        address _keeper,
        address _guardian
    ) public initializer whenNotPaused {
        __Pausable_init();
        governance = _governance;
        strategist = _strategist;
        keeper = _keeper;
        vault = _vault;
        guardian = _guardian;
        withdrawalMaxDeviationThreshold = 50;
    }
    
    // ===== Modifiers =====

    function _onlyVault() internal view {
        require(msg.sender == vault, "onlyVault");
    }

    function _onlyAuthorizedActorsOrVault() internal view {
        require(msg.sender == keeper || msg.sender == governance || msg.sender == vault, "onlyAuthorizedActorsOrVault");
    }

    function _onlyAuthorizedPausers() internal view {
        require(msg.sender == guardian || msg.sender == governance, "onlyPausers");
    }

    /// ===== View Functions =====
    function baseStrategyVersion() public view returns (string memory) {
        return "1.5";
    }

    /// @notice Get the balance of want held idle in the Strategy
    function balanceOfWant() public view override returns (uint256) {
        return IERC20Upgradeable(want).balanceOf(address(this));
    }

    /// @notice Get the total balance of want realized in the strategy, whether idle or active in Strategy positions.
    function balanceOf() public virtual view override returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function isTendable() public virtual view returns (bool) {
        return false;
    }

    function isProtectedToken(address token) public view returns (bool) {
        address[] memory protectedTokens = getProtectedTokens();
        for (uint256 i = 0; i < protectedTokens.length; i++) {
            if (token == protectedTokens[i]) {
                return true;
            }
        }
        return false;
    }

    /// ===== Permissioned Actions: Governance =====

    function setGuardian(address _guardian) external {
        _onlyGovernance();
        guardian = _guardian;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external {
        _onlyGovernanceOrStrategist();
        require(_withdrawalFee <= MAX_FEE, "base-strategy/excessive-withdrawal-fee");
        withdrawalFee = _withdrawalFee;
    }

    function setPerformanceFeeStrategist(uint256 _performanceFeeStrategist) external {
        _onlyGovernanceOrStrategist();
        require(_performanceFeeStrategist <= MAX_FEE, "base-strategy/excessive-strategist-performance-fee");
        performanceFeeStrategist = _performanceFeeStrategist;
    }

    function setPerformanceFeeGovernance(uint256 _performanceFeeGovernance) external {
        _onlyGovernanceOrStrategist();
        require(_performanceFeeGovernance <= MAX_FEE, "base-strategy/excessive-governance-performance-fee");
        performanceFeeGovernance = _performanceFeeGovernance;
    }

    function setVault(address _vault) external {
        _onlyGovernance();
        vault = _vault;
    }

    function setWithdrawalMaxDeviationThreshold(uint256 _threshold) external {
        _onlyGovernance();
        require(_threshold <= MAX_FEE, "base-strategy/excessive-max-deviation-threshold");
        withdrawalMaxDeviationThreshold = _threshold;
    }

    function setAutoCompoundRatio(uint256 _ratio) internal {
        // _onlyGovernance(); TODO: see what permissions this has to get
        require(_ratio <= MAX_FEE, "base-strategy/excessive-auto-compound-ratio");
        autoCompoundRatio = _ratio;
    }

    function earn() public override whenNotPaused {
        deposit();
    }

    function deposit() public virtual whenNotPaused {
        _onlyAuthorizedActorsOrVault();
        uint256 _want = IERC20Upgradeable(want).balanceOf(address(this));
        if (_want > 0) {
            _deposit(_want);
        }
        _postDeposit();
    }

    // ===== Permissioned Actions: Vault =====

    /// @notice Vault-only function to Withdraw partial funds, normally used with a vault withdrawal
    function withdrawToVault() external override whenNotPaused returns (uint256 balance) {
        _onlyVault();

        _withdrawAll();

        _transferToVault(IERC20Upgradeable(want).balanceOf(address(this)));
    }

    /// @notice Withdraw partial funds from the strategy, unrolling from strategy positions as necessary
    /// @notice Processes withdrawal fee if present
    /// @dev If it fails to recover sufficient funds (defined by withdrawalMaxDeviationThreshold), the withdrawal should fail so that this unexpected behavior can be investigated
    function withdraw(uint256 _amount) external virtual override whenNotPaused {
        _onlyVault();

        // Withdraw from strategy positions, typically taking from any idle want first.
        _withdrawSome(_amount);
        uint256 _postWithdraw = IERC20Upgradeable(want).balanceOf(address(this));

        // Sanity check: Ensure we were able to retrieve sufficent want from strategy positions
        // If we end up with less than the amount requested, make sure it does not deviate beyond a maximum threshold
        if (_postWithdraw < _amount) {
            uint256 diff = _diff(_amount, _postWithdraw);

            // Require that difference between expected and actual values is less than the deviation threshold percentage
            require(diff <= _amount.mul(withdrawalMaxDeviationThreshold).div(MAX_FEE), "base-strategy/withdraw-exceed-max-deviation-threshold");
        }

        // Return the amount actually withdrawn if less than amount requested
        uint256 _toWithdraw = MathUpgradeable.min(_postWithdraw, _amount);

        // Process withdrawal fee
        uint256 _fee = _processFee(want, _toWithdraw, withdrawalFee, IVault(vault).rewards());

        // Transfer remaining to Vault to handle withdrawal
        _transferToVault(_toWithdraw.sub(_fee));
    }

    // NOTE: must exclude any tokens used in the yield
    // Vault role - withdraw should return to Vault
    /// @return balance - balance of asset withdrawn
    function withdrawOther(address _asset) external override whenNotPaused returns (uint256 balance) {
        _onlyVault();
        _onlyNotProtectedTokens(_asset);

        balance = IERC20Upgradeable(_asset).balanceOf(address(this));
        IERC20Upgradeable(_asset).safeTransfer(vault, balance);
        return balance;
    }

    /// ===== Permissioned Actions: Authoized Contract Pausers =====

    function pause() external {
        _onlyAuthorizedPausers();
        _pause();
    }

    function unpause() external {
        _onlyGovernance();
        _unpause();
    }

    /// ===== Internal Helper Functions =====

    /// @dev Helper function to process an arbitrary fee
    /// @dev If the fee is active, transfers a given portion in basis points of the specified value to the recipient
    /// @return The fee that was taken
    function _processFee(
        address token,
        uint256 amount,
        uint256 feeBps,
        address recipient
    ) internal returns (uint256) {
        if (feeBps == 0) {
            return 0;
        }
        uint256 fee = amount.mul(feeBps).div(MAX_FEE);
        IERC20Upgradeable(token).safeTransfer(recipient, fee);
        return fee;
    }

    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount)
        internal
        returns (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        )
    {
        governancePerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeGovernance,
            vault
        );

        strategistPerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeStrategist,
            vault
        );

        return (governancePerformanceFee, strategistPerformanceFee);
    }

    function _transferToVault(uint256 _amount) internal {
        IERC20Upgradeable(want).safeTransfer(vault, _amount);
    }

    /// @notice Vault-only function to Withdraw partial funds, normally used with a vault withdrawal
    function _reportToVault(uint256 _harvestedAmount, uint256 _harvestTime, uint256 _assetsAtLastHarvest) internal whenNotPaused {
        (uint256 feeStrategist, uint256 feeGovernance) = _processPerformanceFees(_harvestedAmount);
        IVault(vault).report(_harvestedAmount, _harvestTime, _assetsAtLastHarvest, feeStrategist, feeGovernance);
    }

    /// @notice Utility function to diff two numbers, expects higher value in first position
    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        require(a >= b, "diff/expected-higher-number-in-first-position");
        return a.sub(b);
    }

    // ===== Abstract Functions: To be implemented by specific Strategies =====

    /// @dev Internal deposit logic to be implemented by Stratgies
    /// @param _want: the amount of want token to be deposited into the strategy
    function _deposit(uint256 _want) internal virtual;

    function _postDeposit() internal virtual {
        //no-op by default
    }

    /// @notice Specify tokens used in yield process, should not be available to withdraw via withdrawOther()
    /// @param _asset: address of asset
    function _onlyNotProtectedTokens(address _asset) internal {
        require(!isProtectedToken(_asset), "_onlyNotProtectedTokens");
    }

    /// @dev Gives the list of protected tokens
    /// @return array of protected tokens
    function getProtectedTokens() public virtual view returns (address[] memory);

    /// @dev Internal logic for strategy migration. Should exit positions as efficiently as possible
    function _withdrawAll() internal virtual;

    /// @dev Internal logic for partial withdrawals. Should exit positions as efficiently as possible.
    /// @dev The withdraw() function shell automatically uses idle want in the strategy before attempting to withdraw more using this
    /// @param _amount: the amount of want token to be withdrawm from the strategy
    /// @return withdrawn amount from the strategy
    function _withdrawSome(uint256 _amount) internal virtual returns (uint256);

    /// @dev Realize returns from positions
    /// @dev Returns can be reinvested into positions, or distributed in another fashion
    /// @dev Performance fees should also be implemented in this function
    /// @return harvested : total amount harvested
    function harvest() external virtual returns (uint256 harvested);

    /// @dev User-friendly name for this strategy for purposes of convenient reading
    /// @return Name of the strategy
    function getName() external virtual pure returns (string memory);

    /// @dev Balance of want currently held in strategy positions
    /// @return balance of want held in strategy positions
    function balanceOfPool() public virtual view override returns (uint256);

    /// @dev Calculate the total amount of rewards accured. 
    /// @notice if there are multiple reward tokens this function should take all of them into account
    /// @return the amount of rewards accured
    function balanceOfRewards() public virtual view override returns (uint256);

    uint256[49] private __gap;
}
