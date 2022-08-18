/// Continuous GDAs work by incrementally making more of an asset available for sale, at a constant emission rate, . For example, like we stated above, Alice might be interested in selling 0.25 tokens per minute. Emissions are broken up over an infinite series of virtual auctions. These auctions are started at an even rate over time, with each auction begining at the same price.
module nfts::continuous_gda {
    use sui::coin::{Self, Coin};
    use sui::balance::Balance;
    use sui::sui::SUI;
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self,TxContext};

    #[test_only]
    use sui::test_scenario;

    ///*///////////////////////////////////////////////////////////////
    //                         MAIN OBJECTS                          //
    /////////////////////////////////////////////////////////////////*/

    /// Represents a bid sent by a bidder to the auctioneer.
    struct Bid has key {
        id: UID,
        
        /// Address of the bidder
        bidder: address,
        
        /// ID of the Auction object this bid is intended for
        auction_id: ID,

        /// Number of tokens being purchased in this bid. Note that these are all assumed to be consecutive.  If you want to purchase non-consecutive tokens in an auction then you need to submit multiple bids.
        numTokens: u64,

        /// Coin used for bidding.
        bid: Balance<SUI>
    }

    /// Represents a continuous gradual dutch auction that is currently running.
    struct ContinuousGDA has key {
        id: UID,

        /// Address of the bidder that is currently winning the auction.
        highestBidder: address,

        /// Number of tokens being purchased by the current highest bidder. Note that these are all assumed to be consecutive.  If you want to purchase non-consecutive tokens in an auction then you need to submit multiple bids.
        numTokens: u64,

        /// Coin representing the current (highest) bid.
        funds: Balance<SUI>,

        /// parameter that controls initial price
        initialPrice: u64,

        /// parameter that controls price decay
        decayConstant: u64,

        /// emission rate, in tokens per second
        emissionRate: u64,

        /// start time for last available auction
        lastAvailableAuctionStartTime: u64
    }

    ///*///////////////////////////////////////////////////////////////
    //                         AUCTION LOGIC                         //
    /////////////////////////////////////////////////////////////////*/

    /// Creates a new ContinuousGDA
    public fun create_continuous_gda<T: key + store>(
         numTokens: u64, initialPrice: u64, decayConstant: u64, emissionRate: u64, lastAvailableAuctionStartTime: u64, ctx: &mut TxContext
    ) {
        let auction = ContinuousGDA {
            id: object::new(ctx),
            highestBidder: 0,
            numTokens: numTokens,
            funds: coin::into_balance(coin::zero<SUI>(ctx)),
            initialPrice: initialPrice,
            decayConstant: decayConstant,
            emissionRate: emissionRate,
            lastAvailableAuctionStartTime = lastAvailableAuctionStartTime; 
        };

        share_object(auction);
    }

    /// Updates the auction based on the information in the bid (update auction if higher bid received and send coin back for bids that are too low). This is executed by the auctioneer.
    public entry fun update_auction<T: key + store>(
        auction: &mut ContinuousGDA, bid: Bid, ctx: &mut TxContext
    ) {
        let Bid { id, bidder, auction_id, numTokens, bid: balance } = bid;

        assert!(object::borrow_id(auction) == &auction_id, EWrongAuction);

        if (balance::value(&balance) >= balance::value(&auction.funds)) {
            // a bid higher than currently highest bid received

            // update auction to reflect highest bid
            let BidData {
                funds,
                highestBidder
            } = option::swap(&mut auction.bid_data, new_bid_data);

            // transfer previously highest bid to its bidder
            send_balance(funds, highestBidder, ctx);
        } else {
            // a bid is too low - return funds to the bidder
            send_balance(funds, bidder, ctx);
        }

        object::delete(id);
    }

    public fun end_and_destroy_auction<T: key + store>(
        auction: ContinuousGDA<T>, ctx: &mut TxContext
    ) {
        let Auction { id, to_sell, owner, bid_data } = auction;
        object::delete(id);

        end_auction(&mut to_sell, owner, &mut bid_data, ctx);

        option::destroy_none(bid_data);
        option::destroy_none(to_sell);
    }

    /// Creates a bid a and send it to the auctioneer along with the ID of the auction. This is executed by a bidder.
    public fun bid(
        numTokens: u64, coin: Coin<SUI>, auction_id: ID, auctioneer: address, ctx: &mut TxContext
    ) {
        let bid = Bid {
            id: object::new(ctx),
            bidder: tx_context::sender(ctx),
            auction_id,
            numTokens: numTokens,
            bid: coin::into_balance(coin),
        };

        transfer::transfer(bid, auctioneer);
    }

    /// Calculate purchase price using exponential continuous GDA formula
    fun purchasePrice(auction: ContinuousGDA, numTokens: u64, ctx: &mut TxContext): u64 {
        quantity = numTokens;
        timeSinceLastAuctionStart = tx_context::epoch(ctx) - auction.lastAvailableAuctionStartTime;
        num1 = auction.initialPrice / auction.decayConstant;
        num2 = e_exp(auction.decayConstant * quantity / auction.emissionRate) - 1;
        den = e_exp(auction.decayConstant * timeSinceLastAuctionStart);
        totalCost = num1 * num2 / den;

        return totalCost;
    }

    /// Helper for the most common operation - wrapping a balance and sending it
    fun send_balance(balance: Balance<SUI>, to: address, ctx: &mut TxContext) {
        transfer::transfer(coin::from_balance(balance, ctx), to)
    }

    /// exposes transfer::transfer
    public fun transfer<T: key + store>(obj: ContinuousGDA<T>, recipient: address) {
        transfer::transfer(obj, recipient)
    }

    /// exposes transfer::transfer_to_object_id
    public fun transfer_to_object_id<T: key + store>(
        obj: ContinuousGDA<T>,
        owner_id: &mut UID,
    ) {
        transfer::transfer_to_object_id(obj, owner_id)
    }

    public fun share_object(obj: ContinuousGDA<T>) {
        transfer::share_object(obj)
    }

    /// @dev Calculates the natural exponentiation of a number: ie exp(x) = e^x
    /// @TODO: movemate PR
    public fun e_exp(x: u64, precision: u64): u64 {
        let result = 1;
        let factorial = 1;
        let x_power = 1;
        let i = 0;

        while (i < precision) {
            factorial = factorial * (i + 1);
            x_power = x_power * x;
            result = result + x_power / factorial;
            i = i + 1;
        };

        result
    }

    ///*///////////////////////////////////////////////////////////////
    //                             TESTS                             //
    /////////////////////////////////////////////////////////////////*/

    #[test]
    fun test_end_to_end() {
        let scenario = &mut test_scenario::begin();
        let ctx = test_scenario::ctx(scenario);

        let coin = coin::mint_for_testing<SUI>(1000, ctx);

        let auction = create_continuous_gda<SUI>(
            3,
            1000,
            0.5,
            0.5,
            ctx
        );

        test_scenario::next_epoch(scenario);
        test_scenario::next_epoch(scenario);

        let bid = Bid {
            id: object::new(ctx),
            bidder: tx_context::sender(ctx),
            auction_id: object::borrow_id(&auction),
            numTokens: 3,
            bid: coin::into_balance(coin),
        };

        update_auction(&mut auction, bid, ctx);

        test_scenario::end(scenario);
    }
}