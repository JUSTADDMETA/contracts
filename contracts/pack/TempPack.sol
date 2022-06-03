// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

//  ==========  External imports    ==========

import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155PausableUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";


//  ==========  Internal imports    ==========

import "../interfaces/ITempPack.sol";
import "../interfaces/ITWFee.sol";

import "../openzeppelin-presets/metatx/ERC2771ContextUpgradeable.sol";

import "../lib/FeeType.sol";
import "../lib/CurrencyTransferLib.sol";

//  ==========  Features    ==========

import "../feature/ContractMetadata.sol";
import "../feature/Royalty.sol";
import "../feature/Ownable.sol";
import "../feature/PermissionsEnumerable.sol";
import "../feature/TokenStore.sol";

contract TempPack is
    Initializable,
    ContractMetadata,
    Ownable,
    Royalty,
    PermissionsEnumerable,
    TokenStore,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    MulticallUpgradeable,
    ERC721HolderUpgradeable,
    ERC1155HolderUpgradeable,
    ERC1155PausableUpgradeable,
    ITempPack
{

    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant MODULE_TYPE = bytes32("Pack");
    uint256 private constant VERSION = 1;

    // Token name
    string public name;

    // Token symbol
    string public symbol;

    /// @dev Only transfers to or from TRANSFER_ROLE holders are valid, when transfers are restricted.
    bytes32 private constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    /// @dev Only MINTER_ROLE holders can create packs.
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev The thirdweb contract with fee related information.
    ITWFee public immutable thirdwebFee;

    /// @dev The address of the native token wrapper contract.
    address private immutable nativeTokenWrapper;

    /// @dev The token Id of the next set of packs to be minted.
    uint256 public nextTokenId;

    /*///////////////////////////////////////////////////////////////
                             Mappings
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from token ID => total circulating supply of token with that ID.
    mapping(uint256 => uint256) public totalSupply;

    /// @dev Mapping from pack ID => The state of that set of packs.
    mapping(uint256 => PackInfo) private packInfo;

   /*///////////////////////////////////////////////////////////////
                    Constructor + initializer logic
    //////////////////////////////////////////////////////////////*/

    constructor(address _thirdwebFee, address _nativeTokenWrapper) initializer {
        thirdwebFee = ITWFee(_thirdwebFee);
        nativeTokenWrapper = _nativeTokenWrapper;
    }

    /// @dev Initiliazes the contract, like a constructor.
    function initialize(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address[] memory _trustedForwarders,
        address _royaltyRecipient,
        uint256 _royaltyBps
    ) external initializer {
        // Initialize inherited contracts, most base-like -> most derived.
        __ReentrancyGuard_init();
        __ERC2771Context_init(_trustedForwarders);
        __ERC1155Pausable_init();
        __ERC1155_init(_contractURI);

        name = _name;
        symbol = _symbol;

        setContractURI(_contractURI);
        setOwner(_defaultAdmin);

        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, _defaultAdmin);
        _setupRole(MINTER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, address(0));

        setDefaultRoyaltyInfo(_royaltyRecipient, _royaltyBps);
    }

    /*///////////////////////////////////////////////////////////////
                        Generic contract logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the type of the contract.
    function contractType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @dev Returns the version of the contract.
    function contractVersion() external pure returns (uint8) {
        return uint8(VERSION);
    }

    /// @dev Pauses / unpauses contract.
    function pause(bool _toPause) internal onlyRole(DEFAULT_ADMIN_ROLE) {
        if(_toPause) {
            _pause();
        } else {
            _unpause();
        }
    }

    /*///////////////////////////////////////////////////////////////
                        ERC 165 / 1155 / 2981 logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the URI for a given tokenId.
    function uri(uint256 _tokenId) public view override returns (string memory) {
        return packInfo[_tokenId].uri;
    }

    /// @dev See ERC 165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Upgradeable, ERC1155ReceiverUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC2981Upgradeable).interfaceId == interfaceId;
    }

    /*///////////////////////////////////////////////////////////////
                    Pack logic: create | open packs.
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates a pack with the stated contents.
    function createPack(
        Token[] calldata _contents,
        uint256[] calldata _perUnitAmounts,
        string calldata _packUri,
        uint128 _openStartTimestamp,
        uint128 _amountDistributedPerOpen,
        address _recipient
    )
        external
        onlyRole(MINTER_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 packId, uint256 packTotalSupply)
    {

        require(_contents.length > 0, "nothing to pack");

        packId = nextTokenId;
        nextTokenId += 1;

        packTotalSupply = escrowPackContents(_contents, _perUnitAmounts, _packUri, packId);

        packInfo[packId].openStartTimestamp = _openStartTimestamp;
        packInfo[packId].amountDistributedPerOpen = _amountDistributedPerOpen;

        _mint(_recipient, packId, packTotalSupply, "");

        emit PackCreated(packId, _msgSender(), _recipient, packInfo[packId], packTotalSupply);
    }

    /// @notice Lets a pack owner open packs and receive the packs' reward units.
    function openPack(uint256 _packId, uint256 _amountToOpen) external nonReentrant whenNotPaused {

        address opener = _msgSender();

        require(opener == tx.origin, "opener must be eoa");
        require(balanceOf(opener, _packId) >= _amountToOpen, "opening more than owned");

        PackInfo memory pack = packInfo[_packId];
        require(pack.openStartTimestamp < block.timestamp, "cannot open yet");

        (
            Token[] memory rewardUnits
        ) = getRewardUnits(_packId, _amountToOpen, pack.amountDistributedPerOpen);

        _burn(_msgSender(), _packId, _amountToOpen);

        _transferTokenBatch(address(this), _msgSender(), rewardUnits);

        emit PackOpened(_packId, _msgSender(), _amountToOpen, rewardUnits);
    }

    function escrowPackContents(
        Token[] calldata _contents,
        uint256[] calldata _perUnitAmounts,
        string calldata _packUri,
        uint256 packId
    )
        internal 
        returns (uint256 packTotalSupply) 
    {

        for(uint256 i = 0; i < _contents.length; i += 1) {

            require(_contents[i].totalAmount % _perUnitAmounts[i] == 0, "invalid reward units");
            require(_contents[i].tokenType != TokenType.ERC721 || _contents[i].totalAmount == 1, "invalid erc721 rewards");

            packTotalSupply += _contents[i].totalAmount / _perUnitAmounts[i];
            packInfo[packId].perUnitAmounts[_contents[i].assetContract] = _perUnitAmounts[i];
        }
        
        _storeTokens(_msgSender(), _contents, _packUri, packId);
    }

    /// @dev Returns the reward units to distribute.
    function getRewardUnits(
        uint256 _packId,
        uint256 _numOfPacksToOpen,
        uint256 _rewardUnitsPerOpen
    )   
        internal
        returns (
            Token[] memory rewardUnits
        ) 
    {
        rewardUnits = new Token[](_numOfPacksToOpen * _rewardUnitsPerOpen);
        uint256 currentTotalSupply = totalSupply[_packId];
        uint256 availableRewardUnitsCount = getTokenCountOfBundle(_packId);

        uint256 random = uint(keccak256(abi.encodePacked(_msgSender(), blockhash(block.number), block.difficulty)));
        for(uint256 i = 0; i < (_numOfPacksToOpen * _rewardUnitsPerOpen); i += 1) {
            
            uint256 randomVal = uint256(keccak256(abi.encode(random, i)));
            uint256 target = randomVal % currentTotalSupply;
            uint256 step;

            for(uint256 j = 0; j < availableRewardUnitsCount; j += 1) {
                Token memory _token = getTokenOfBundle(_packId, j);
                PackInfo memory pack = packInfo[_packId];

                uint256 check = _token.totalAmount / pack.perUnitAmounts[_token.assetContract];

                if(target < step + check) {

                    rewardUnits[i] = _token;
                    rewardUnits[i].totalAmount = pack.perUnitAmounts[_token.assetContract];

                    _token.totalAmount -= pack.perUnitAmounts[_token.assetContract];
                    _updateTokenInBundle(_token, _packId, j);

                    break;

                } else {
                    step += check;
                }
            }
        }
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Returns whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Returns whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev See {ERC1155-_beforeTokenTransfer}.
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (!hasRole(TRANSFER_ROLE, address(0)) && from != address(0) && to != address(0)) {
            require(hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to), "restricted to TRANSFER_ROLE holders.");
        }

        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] += amounts[i];
            }
        }

        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] -= amounts[i];
            }
        }
    }

    /// @dev See EIP-2771
    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address sender)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /// @dev See EIP-2771
    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }
}