// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./libraries/GameLib.sol";
import "./libraries/ConstLib.sol";
import "./interfaces/IGameDB.sol";

contract Player is Initializable, IERC721Receiver  {
    using EnumerableSet for EnumerableSet.UintSet;

    // Free mint records
    mapping(address => bool) private _freemint;
    // Invitation relationship
    mapping(address => address) private _referrers;

    IGameDB private _gameDB;
    IERC721 private _heroNFT;
    IERC721 private _equipmentNFT;
    uint256 private _heroTeamId;
    EnumerableSet.UintSet private tokenIds;

    event SetReferrer(address owner, address referrer);
    event HeroEquipment(uint256 tokenId, uint256[] equipments);
    event SetHeroEquipment(uint256 tokenId, uint256[] equTokenIds);
    event CreateHeroTeam(address owner, uint256 id, string name, uint256[] tokenIds, uint256 rank);
    event UpdateHeroTeam(address owner, uint256 id, string name, uint256[] tokenIds, uint256 rank);
    event CloseHeroTeam(address owner, uint256 id);

    function initialize(IERC721 heroNFT, IERC721 equipmentNFT, IGameDB gameDB) public initializer {
        _gameDB = gameDB;
        _heroNFT = heroNFT;
        _equipmentNFT = equipmentNFT;
    }

    // Create my hero team
    function createHeroTeam(GameLib.HeroTeam memory heroTeam) external {
        require(heroTeam.tokenIds.length == 3, "The team must contain 3 NFTs");
        require(heroTeam.tokenIds[0] != heroTeam.tokenIds[1] && heroTeam.tokenIds[0] != heroTeam.tokenIds[2] && heroTeam.tokenIds[1] != heroTeam.tokenIds[2]);

        GameLib.HeroMeta memory heroMeta1 = _gameDB.getHeroMeta(heroTeam.tokenIds[0]);
        GameLib.HeroMeta memory heroMeta2 = _gameDB.getHeroMeta(heroTeam.tokenIds[1]);
        GameLib.HeroMeta memory heroMeta3 = _gameDB.getHeroMeta(heroTeam.tokenIds[2]);
        require(heroMeta1.rank == heroMeta2.rank && heroMeta2.rank == heroMeta3.rank, "Heroes of the same rank are required to form a team");
        require(heroMeta1.career + heroMeta2.career + heroMeta3.career == ConstLib.WARRIOR + ConstLib.MAGE + ConstLib.ASSASSIN, "The professions of three heroes must be different");

        for (uint i = 0; i < heroTeam.tokenIds.length; i++) {
            _heroNFT.safeTransferFrom(msg.sender, address(this), heroTeam.tokenIds[i]);
        }

        _heroTeamId++;
        heroTeam.id = _heroTeamId;
        heroTeam.rank = heroMeta1.rank;
        heroTeam.owner = msg.sender;
        _gameDB.setHeroTeam(heroTeam);
        _gameDB.addUserHeroTeam(msg.sender, heroTeam.id);

        emit CreateHeroTeam(msg.sender, heroTeam.id, heroTeam.name, heroTeam.tokenIds, heroTeam.rank);
    }

    // Modify my hero team, cannot modify if signed up
    function updateHeroTeam(GameLib.HeroTeam memory heroTeam) external {       
        require(heroTeam.tokenIds.length == 3, "The team must contain 3 NFTs");
        require(heroTeam.tokenIds[0] != heroTeam.tokenIds[1] && heroTeam.tokenIds[0] != heroTeam.tokenIds[2] && heroTeam.tokenIds[1] != heroTeam.tokenIds[2]);
        require(_gameDB.existsHeroTeam(msg.sender, heroTeam.id), "Team id does not belong to you");
        require(block.timestamp >= _gameDB.getHeroTeamProtectionTime(heroTeam.id), "The team is on a clearance mission and cannot be modified");

        GameLib.HeroMeta memory heroMeta1 = _gameDB.getHeroMeta(heroTeam.tokenIds[0]);
        GameLib.HeroMeta memory heroMeta2 = _gameDB.getHeroMeta(heroTeam.tokenIds[1]);
        GameLib.HeroMeta memory heroMeta3 = _gameDB.getHeroMeta(heroTeam.tokenIds[2]);
        require(heroMeta1.rank == heroMeta2.rank && heroMeta2.rank == heroMeta3.rank, "Heroes of the same rank are required to form a team");
        require(heroMeta1.career + heroMeta2.career + heroMeta3.career == ConstLib.WARRIOR + ConstLib.MAGE + ConstLib.ASSASSIN, "The professions of three heroes must be different");

        for (uint i = 0; i < heroTeam.tokenIds.length; i++) {
            tokenIds.add(heroTeam.tokenIds[i]);
            if (_heroNFT.ownerOf(heroTeam.tokenIds[i]) != address(this)) {
                _heroNFT.safeTransferFrom(msg.sender, address(this), heroTeam.tokenIds[i]);
            }
        }

        GameLib.HeroTeam memory oldHeroTeam = _gameDB.getHeroTeam(heroTeam.id);
        for (uint i = 0; i < oldHeroTeam.tokenIds.length; i++) {
            if (!tokenIds.contains(oldHeroTeam.tokenIds[i])) {
                _heroNFT.safeTransferFrom(msg.sender, address(this), oldHeroTeam.tokenIds[i]);
            }
        }

        heroTeam.rank = heroMeta1.rank;
        _gameDB.setHeroTeam(heroTeam);

        emit UpdateHeroTeam(msg.sender, heroTeam.id, heroTeam.name, heroTeam.tokenIds, heroTeam.rank);
    }

    // Disband team, cannot be disbanded if signed up for a match
    function closeHeroTeam(uint256 heroTeamId) external {       
        require(_gameDB.existsHeroTeam(msg.sender, heroTeamId), "Team id does not belong to you");
        require(block.timestamp >= _gameDB.getHeroTeamProtectionTime(heroTeamId), "The team is on a clearance mission and cannot be modified");

        GameLib.HeroTeam memory heroTeam = _gameDB.getHeroTeam(heroTeamId);
        for (uint i = 0; i < heroTeam.tokenIds.length; i++) {
            _heroNFT.safeTransferFrom(address(this), msg.sender, heroTeam.tokenIds[i]);
        }

        _gameDB.deleteHeroTeam(heroTeamId);
        _gameDB.deleteUserHeroTeam(heroTeamId);

        emit CloseHeroTeam(msg.sender, heroTeamId);
    }

    // Change hero's equipment
    function setHeroEquipment(uint256 tokenId, uint256[] calldata typeIds, uint256[] calldata equTokenIds) external {
        require(msg.sender == _heroNFT.ownerOf(tokenId), "HeroNFT doesn't belong to you");
        
        _setHeroEquipment(tokenId, typeIds, equTokenIds);
    }

    // Change hero's equipment in the team
    function setHeroEquipmentForHeroTeam(uint256 heroTeamId, uint256 tokenId, uint256[] calldata typeIds, uint256[] calldata equTokenIds) external {
        require(_gameDB.existsHeroTeam(msg.sender, heroTeamId), "Team id does not belong to you");

        bool exists = false;
        GameLib.HeroTeam memory heroTeam = _gameDB.getHeroTeam(heroTeamId);
        for(uint i = 0; i < heroTeam.tokenIds.length; i++) {
            if(heroTeam.tokenIds[i] == tokenId) {
                exists = true;
                break;
            }
        }

        _setHeroEquipment(tokenId, typeIds, equTokenIds);
    }

    function _setHeroEquipment(uint256 tokenId, uint256[] calldata typeIds, uint256[] calldata equTokenIds) private {
        require(typeIds.length == equTokenIds.length, "tokenIds length not match");

        address owner = msg.sender;
        uint256[8] memory oldEquTokenIds = _gameDB.getHeroEquipments(tokenId);
        GameLib.EquipmentMeta memory equ;
        GameLib.HeroMeta memory hero = _gameDB.getHeroMeta(tokenId);
        for (uint i = 0; i < typeIds.length; i++) {
            require(equTokenIds[i] > 0, "EquTokenId must be greater than 0");
            equ = _gameDB.getEquipmentMeta(equTokenIds[i]);
            require(equ.typeId == typeIds[i], "typeId not match");
            require(hero.level >= equ.minLevel, "level not match");
            require(hero.rank >= equ.quality, "rank not match");
            bool isCareerMatch = false; // Whether the career matches
            for (uint j = 0; j < equ.careers.length; j++) {
                if(equ.careers[j] == hero.career) {
                    isCareerMatch = true;
                    break;
                }
            }
            require(isCareerMatch, "career not match");

            uint256 oldEquTokenId = oldEquTokenIds[typeIds[i] - 1];
            uint256 equTokenId = equTokenIds[i];
            if(oldEquTokenId == 0) {
                // Add new equipment
                _equipmentNFT.safeTransferFrom(owner, address(this), equTokenId);
            } else if (oldEquTokenId != equTokenId) {
                // Replace new equipment
                _equipmentNFT.safeTransferFrom(owner, address(this), equTokenId);
                // Return old equipment
                _equipmentNFT.safeTransferFrom(address(this), owner, oldEquTokenId);
            }
            oldEquTokenIds[typeIds[i] - 1] = equTokenId;
        }

        _gameDB.setHeroEquipments(tokenId, oldEquTokenIds);

        emit SetHeroEquipment(tokenId, equTokenIds);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}