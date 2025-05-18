//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "@inco/lightning/src/Lib.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./ConfidentialERC20.sol";

contract SPAContract is Ownable2Step {
    using e for *;

    // Constants
    uint256 public constant MIN_BID_PRICE = 0.01 ether;
    uint256 public constant CALLBACK_MAX_DURATION = 100 seconds;

    enum ErrorCodes {
        NO_ERROR,
        TRANSFER_FAILED,
        VALIDATION_ERROR
    }

    struct LastError {
        uint256 errorIndex;
        uint256 at;
    }

    mapping(address => LastError) private lastErrorByAddress;

    uint256 public auctionCount = 0;
    uint256 public bidCount = 0;

    // Auction states
    enum AuctionState {
        Active,
        Ended,
        Settled,
        Cancelled
    }

    // Events
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed creator,
        uint256 totalSupply,
        uint256 startTime,
        uint256 endTime
    );

    event BidPlaced(uint256 indexed auctionId, address indexed bidder);

    event AuctionEnded(uint256 indexed auctionId);

    event AuctionSettled(
        uint256 indexed auctionId,
        uint256 settledPrice,
        uint256 totalTokensSold
    );

    event TokensClaimed(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 tokenAmount
    );

    event RefundIssued(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 refundAmount
    );

    event ErrorChanged(address indexed user, uint256 errorId);
    event DecryptSettlementPriceReady();

    struct Auction {
        ConfidentialERC20 tokenContract; // Token contract being auctioned
        address creator; // Address of the auction creator
        uint256 totalSupply; // Total supply of tokens being auctioned
        uint256 startTime; // Start time of the auction
        uint256 endTime; // End time of the auction
        AuctionState state; // Current state of the auction
        uint256 minBidPrice; // Minimum bid price allowed
        euint256 reservedSupplySum; // Sum of allocated supply
        uint256 settledPrice; // Final settled price (after decryption)
        bool isSettlementInProgress; // Flag for settlement in progress
        uint256 totalSold; // Total tokens sold in the auction
    }

    struct Bid {
        address bidder; // Address of the bidder
        euint256 quantity; // Quantity of tokens requested (encrypted)
        euint256 price; // Price per token offered (encrypted)
        uint256 quantityFulfilled; // Quantity of tokens fulfilled
        bool isFulfilled; // Whether the bid has been fulfilled/processed
    }

    // Helper structure for bid data
    struct BidData {
        uint256 bidId;
        uint256 quantity;
        uint256 price;
    }


    // Encrypted constants for use in operations
    euint256 private immutable EU256_ZERO;

    mapping(uint256 => Auction) public auctions; // Mapping of auction ID to Auction struct
    mapping(uint256 => Bid) public bids; // Mapping of bid ID to Bid struct
    mapping(uint256 => uint256[]) public auctionToBids; // Mapping of auction ID to array of bid IDs
    mapping(address => mapping(uint256 => uint256[])) public bidderToBids; // Mapping of bidder to their bids per auction

    // Add this struct at contract level
    struct DecryptionRequest {
        uint256 auctionId;
        uint256 bidIndex;
        bool isQuantity; // true for quantity, false for price
    }

    // Add this mapping at contract level
    mapping(uint256 => DecryptionRequest) public decryptionRequests;

    // Add these at contract level
    mapping(uint256 => uint256[]) private decryptedQuantities;
    mapping(uint256 => uint256[]) private decryptedPrices;
    mapping(uint256 => uint256) private decryptionCount;

    constructor() Ownable(msg.sender) {
        // Initialize encrypted constants
        EU256_ZERO = e.asEuint256(0);
        e.allowThis(EU256_ZERO);
    }

    /**
     * @dev Create a new auction
     * @param _tokenContract Address of the token contract being auctioned
     * @param _totalSupply Total number of tokens being auctioned
     * @param _duration Duration of the auction in seconds
     * @param _minBidPrice Minimum bid price allowed
     */
    function createAuction(
        ConfidentialERC20 _tokenContract,
        uint64 _totalSupply,
        uint256 _duration,
        uint256 _minBidPrice
    ) external {
        require(_totalSupply > 0, "Supply must be greater than zero");
        require(_duration > 0, "Duration must be greater than zero");

        auctionCount++;

        Auction storage newAuction = auctions[auctionCount];
        newAuction.tokenContract = _tokenContract;
        newAuction.creator = msg.sender;
        newAuction.totalSupply = _totalSupply;
        newAuction.startTime = block.timestamp;
        newAuction.endTime = block.timestamp + _duration;
        newAuction.state = AuctionState.Active;
        newAuction.minBidPrice = _minBidPrice;
        newAuction.reservedSupplySum = uint256(0).asEuint256();

        // Transfer tokens from creator to contract
        euint256 eSupply = _totalSupply.asEuint256();

        eSupply.allowThis();
        e.allow(newAuction.reservedSupplySum, address(this));
        
        ConfidentialERC20(_tokenContract).transferFrom(
            msg.sender,
            address(this),
            eSupply
        );

        Auction storage auction = auctions[auctionCount];
        emit AuctionCreated(
            auctionCount,
            owner(),
            auction.totalSupply,
            auction.startTime,
            auction.endTime
        );
    }

    /**
     * @dev Place an encrypted bid in the auction
     * @param _auctionId ID of the auction
     * @param _encryptedQuantity Encrypted quantity of tokens requested
     * @param _encryptedPrice Encrypted price per token offered
     */
    function placeBid(
        uint256 _auctionId,
        bytes calldata _encryptedQuantity,
        bytes calldata _encryptedPrice
    ) external payable {
        Auction storage auction = auctions[_auctionId];

        euint256 quantity = e.newEuint256(_encryptedQuantity, msg.sender);
        euint256 price = e.newEuint256(_encryptedPrice, msg.sender);

        quantity.allowThis();
        price.allowThis();
        auction.reservedSupplySum.allowThis();

        require(auction.state == AuctionState.Active, "Auction is not active");
        require(block.timestamp < auction.endTime, "Auction has ended");
        // Validate input
        ebool invalidQuantity = e.gt(quantity, auction.totalSupply.asEuint256());
        invalidQuantity.allowThis();

        euint256 newQuantity = invalidQuantity.select(0.asEuint256(), quantity);
        newQuantity.allowThis();

        // Check minimum price - unlike ConfidentialSPA, we require a minimum plaintext price
        ebool belowMinPrice = e.lt(price, auction.minBidPrice);
        price = belowMinPrice.select(0.asEuint256(), price);

        // Create the bid
        bidCount++;
        Bid storage newBid = bids[bidCount];
        newBid.bidder = msg.sender;
        newBid.quantity = quantity;
        newBid.price = price;
        newBid.isFulfilled = false;
        newBid.quantityFulfilled = 0;

        auctionToBids[_auctionId].push(bidCount);
        bidderToBids[msg.sender][_auctionId].push(bidCount);

        // Update reserved supply sum
        euint256 newReservedSupply = e.add(auction.reservedSupplySum, quantity);
        newReservedSupply.allowThis();

        auction.reservedSupplySum = newReservedSupply;
        auction.reservedSupplySum.allowThis();

        ConfidentialERC20(auction.tokenContract).transferFrom(
            msg.sender,
            address(this),
            price
        );
        emit BidPlaced(_auctionId, msg.sender);
    }

    /**
     * @dev End an auction and begin settlement process
     * @param _auctionId ID of the auction
     */
    function endAuction(uint256 _auctionId) external {
        Auction storage auction = auctions[_auctionId];

        require(auction.state == AuctionState.Active, "Auction is not active");
        require(
            block.timestamp >= auction.endTime,
            "Auction has not ended yet"
        );

        auction.state = AuctionState.Ended;
        emit AuctionEnded(_auctionId);

        // Start settlement process
        startSettlement(_auctionId);
    }

    /**
     * @dev Start the settlement process for an auction
     * @param _auctionId ID of the auction
     */
    function startSettlement(uint256 _auctionId) internal {
        Auction storage auction = auctions[_auctionId];
        require(
            auction.state == AuctionState.Ended,
            "Auction is not in Ended state"
        );

        // If there are no bids, mark as settled with price 0
        if (auctionToBids[_auctionId].length == 0) {
            auction.settledPrice = 0;
            auction.state = AuctionState.Settled;
            emit AuctionSettled(_auctionId, 0, 0);
            return;
        }

        auction.isSettlementInProgress = true;

        // Get all bids for this auction
        uint256[] storage bidIds = auctionToBids[_auctionId];

        for (uint256 i = 0; i < bidIds.length; i++) {
            Bid storage bid = bids[bidIds[i]];
            
            // Request quantity decryption
            uint256 quantityRequestId = e.requestDecryption(
                bid.quantity,
                this.callbackSettlementByQuantity.selector,
                ""
            );
            
            // Store request details
            decryptionRequests[quantityRequestId] = DecryptionRequest({
                auctionId: _auctionId,
                bidIndex: i,
                isQuantity: true
            });

            // Request price decryption
            uint256 priceRequestId = e.requestDecryption(
                bid.price,
                this.callbackSettlementByQuantity.selector,
                ""
            );
            
            // Store request details
            decryptionRequests[priceRequestId] = DecryptionRequest({
                auctionId: _auctionId,
                bidIndex: i,
                isQuantity: false
            });
        }

        // Request decryption of all quantities and prices
        // We'll use a different callback to handle the sorted bids
        
    }
     /**
     * @dev Callback function for settlement decryption
     * @param _requestId ID of the decryption request
     * @param _decryptedValue Decrypted value
     * @param _extra Extra data (optional)
     */
    function callbackSettlementByQuantity(
        uint256 _requestId,
        bytes32 _decryptedValue,
        bytes memory _extra
    ) public {
        DecryptionRequest memory request = decryptionRequests[_requestId];
        uint256 value = uint256(_decryptedValue);

        if (request.isQuantity) {
            // Initialize array if first decryption
            if (decryptedQuantities[request.auctionId].length == 0) {
                decryptedQuantities[request.auctionId] = new uint256[](auctionToBids[request.auctionId].length);
            }
            decryptedQuantities[request.auctionId][request.bidIndex] = value;
        } else {
            // Initialize array if first decryption
            if (decryptedPrices[request.auctionId].length == 0) {
                decryptedPrices[request.auctionId] = new uint256[](auctionToBids[request.auctionId].length);
            }
            decryptedPrices[request.auctionId][request.bidIndex] = value;
        }

        // Increment decryption count
        decryptionCount[request.auctionId]++;

        // If all decryptions are done, proceed with settlement
        if (decryptionCount[request.auctionId] == auctionToBids[request.auctionId].length * 2) {
            settleByQuantity(
                request.auctionId,
                decryptedQuantities[request.auctionId],
                decryptedPrices[request.auctionId]
            );
        }
    }

    // This callback receives decrypted quantities and prices
    function settleByQuantity(
        uint256 _auctionId,
        uint256[] memory quantityValues,
        uint256[] memory priceValues
    ) internal {
        Auction storage auction = auctions[_auctionId];
        require(auction.isSettlementInProgress, "Settlement not in progress");

        uint256[] storage bidIds = auctionToBids[_auctionId];
        require(bidIds.length == quantityValues.length, "Data mismatch");

        // Create a structure to hold bid data for sorting
        BidData[] memory bidDataArray = new BidData[](bidIds.length);
        for (uint256 i = 0; i < bidIds.length; i++) {
            bidDataArray[i] = BidData({
                bidId: bidIds[i],
                quantity: quantityValues[i],
                price: priceValues[i]
            });
        }

        // Sort bids by quantity (descending order)
        sortBidsByQuantityDesc(bidDataArray);

        // Find the price at which we can sell the maximum number of tokens
        // This is the lowest price among accepted bids
        uint256 remainingSupply = auction.totalSupply;
        uint256 minAcceptedPrice = type(uint256).max;
        uint256 totalSold = 0;
        uint256 indexSelected = 0;
        // First pass: allocate tokens to bids in order of quantity (highest first)
        for (
            uint256 i = 0;
            i < bidDataArray.length && remainingSupply > 0;
            i++
        ) {
            uint256 quantity = bidDataArray[i].quantity;
            uint256 price = bidDataArray[i].price;

            // If this bid's quantity exceeds remaining supply, adjust it
            if (quantity > remainingSupply) {
                quantity = remainingSupply;
            }

            // Update remaining supply
            remainingSupply -= quantity;
            totalSold += quantity;

            // Update minimum price of accepted bids
            if (price < minAcceptedPrice) {
                minAcceptedPrice = price;
            }
            indexSelected = i;
        }

        // Complete settlement with the calculated price
        auction.settledPrice = minAcceptedPrice;
        auction.totalSold = totalSold;
        auction.state = AuctionState.Settled;
        auction.isSettlementInProgress = false;

        emit AuctionSettled(_auctionId, minAcceptedPrice, totalSold);

        // Queue fulfillment of bids at the settlement price
        queueBidFulfillment(_auctionId, bidDataArray,indexSelected, minAcceptedPrice);
    }

    // Sort bids by quantity in descending order
    function sortBidsByQuantityDesc(
        BidData[] memory bidDataArray
    ) internal pure {
        for (uint i = 0; i < bidDataArray.length - 1; i++) {
            for (uint j = 0; j < bidDataArray.length - i - 1; j++) {
                if (bidDataArray[j].quantity < bidDataArray[j + 1].quantity) {
                    // Swap
                    BidData memory temp = bidDataArray[j];
                    bidDataArray[j] = bidDataArray[j + 1];
                    bidDataArray[j + 1] = temp;
                }
            }
        }
    }

    // Queue fulfillment of accepted bids
    function queueBidFulfillment(
        uint256 _auctionId,
        BidData[] memory sortedBids,
        uint256 indexSelected,
        uint256 settlementPrice
    ) internal {
        Auction storage auction = auctions[_auctionId];
        uint256 remainingSupply = auction.totalSupply;

        // Process bids in sorted order (largest quantity first)
        for (uint256 i = 0; i < sortedBids.length-indexSelected; i++) {
            uint256 bidId = sortedBids[i].bidId;
            Bid storage bid = bids[bidId];
            uint256 bidQuantity = sortedBids[i].quantity;

            // If user's bid price is at least the settlement price
            if (sortedBids[i].price >= settlementPrice) {
                // Calculate how many tokens this bidder will receive
                uint256 quantityToFulfill = bidQuantity;
                if (quantityToFulfill > remainingSupply) {
                    quantityToFulfill = remainingSupply;
                }

                // Update remaining supply
                remainingSupply -= quantityToFulfill;

                // Queue this bid for fulfillment
                bid.quantityFulfilled = quantityToFulfill;
                bid.isFulfilled = true;

                // Add to payment and fulfillment queue
                // (implementation depends on your system)
                queuePaymentAndDelivery(
                    _auctionId,
                    bidId,
                    quantityToFulfill,
                    settlementPrice
                );
            }
        }
    }
    function queuePaymentAndDelivery(
        uint256 _auctionId,
        uint256 _bidId,
        uint256 _quantity,
        uint256 _price
    ) internal {
        // Placeholder for payment and delivery logic
        // This function should handle the transfer of tokens and payment
        Auction storage auction = auctions[_auctionId];
        Bid storage bid = bids[_bidId];
        euint256 quantityRemaining = e.sub(
            bid.quantity,
            bid.quantityFulfilled
        );
        quantityRemaining.allowThis();

        e.requestDecryption(
            quantityRemaining,
            this.callbackSettlementRefund.selector,
            ""
        );
        
        ConfidentialERC20(auction.tokenContract).transfer(
            bids[_bidId].bidder,
            _quantity.asEuint256()
        );
        (bool sent,) = payable(auction.creator).call{
            value: _quantity * _price
        }("");
        require(sent, "Failed to send Ether");
        emit TokensClaimed(_auctionId, bids[_bidId].bidder, _quantity);
    }
    
   function callbackSettlementRefund(
        uint256 _requestId,
        bytes32 _decryptedValue,
        bytes memory _extra
    ) public {
        // Handle the decrypted value for refund
        uint256 value = uint256(_decryptedValue);
        // Placeholder for refund logic
        // This function should handle the refund process
        require(value>=0, "Invalid value");
        (bool sent, ) = payable(msg.sender).call{
            value: value
        }("");
        require(sent, "Failed to send Ether");
        emit RefundIssued(
            decryptionRequests[_requestId].auctionId,
            msg.sender,
            value
        );
        // Clean up the request
        delete decryptionRequests[_requestId];
        delete decryptedQuantities[decryptionRequests[_requestId].auctionId];
        delete decryptedPrices[decryptionRequests[_requestId].auctionId];
        delete decryptionCount[decryptionRequests[_requestId].auctionId];
       
    }

    // Function to receive Ether
    receive() external payable {}
}
