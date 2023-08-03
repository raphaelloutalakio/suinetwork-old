// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module era::marketplace {
    use sui::dynamic_object_field as ofield;
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::event::emit;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use std::fixed_point32;
    use std::type_name;
    use sui::sui::SUI;
    use std::string::{Self,String};

    const EAmountIncorrect: u64 = 0;
    const ENotOwner: u64 = 1;

    struct Marketplace has key {
        id: UID,
        fee_pbs: u64,
        collateral_fee: u64,
        volume: u64,
        listed: u64,
        owner: address,
    }

    struct Listing<phantom COIN,phantom N> has key, store {
        id: UID,
        ask: u64,
        owner: address,
        offers: u64,
    }

    struct AuctionListing<phantom COIN,phantom N> has key, store {
        id: UID,
        owner: address,
        item_id: ID,
	    bid: Balance<COIN>,
	    bid_amount: u64,
	    min_bid: u64,
	    min_bid_increment: u64,
	    starts: u64,
	    expires: u64,
	    bidder: address,
    }

    struct Offer<phantom OC> has store, key  {
        id: UID,
        paid: Coin<OC>,
        offerer: address,
    } 

    struct RoyaltyCollection has store, key {
	 id: UID,
	 total: u64,
     owner: address,
    }

    struct RoyaltyCollectionItem<phantom COIN> has store, key {
	 id: UID,
	 collection_type: String,
	 creator: address,
	 bps: u64,
     balance: Balance<COIN>
    }

    struct ListingEvent<phantom COIN,phantom N> has copy, drop {
	 item_id: ID,
	 amount: u64,
	 seller: address,
     expires: u64,
    }
    struct DeListEvent has copy, drop {
	 item_id: ID,
	 seller: address,
    }
    struct BuyEvent<phantom COIN> has copy, drop {
	 item_id: ID,
	 amount: u64,
	 buyer: address,
     seller: address,
    }
    struct ChangePriceEvent<phantom COIN> has copy, drop {
	 item_id: ID,
	 seller: address,
	 amount: u64
    }
    
    fun init(ctx: &mut TxContext) {
        transfer::share_object(Marketplace { id: object::new(ctx),fee_pbs:150,collateral_fee:10000,volume:0,listed:0,owner:tx_context::sender(ctx) });
        transfer::share_object(RoyaltyCollection { id: object::new(ctx),total: 0,owner:tx_context::sender(ctx)});
    }

    public entry fun list<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item: N,
        ask: u64,
        ctx: &mut TxContext
    ) {
        assert!(ask > 0, ENotOwner);
        let item_id = object::id(&item);
        let listing = Listing<COIN,N> {
            ask,
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            offers: 0,
        };

        ofield::add(&mut listing.id, true, item);
        ofield::add(&mut marketplace.id, item_id, listing);

        marketplace.listed = marketplace.listed + 1;

        emit(ListingEvent<COIN,N> {
            item_id: item_id,
            amount: ask,
            seller: tx_context::sender(ctx),
            expires: 0,
        });
    }

    public fun delist<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item_id: ID,
        ctx: &mut TxContext
    ): N {
        let Listing<COIN,N> {
            id,
            owner,
            ask: _,
            offers,
        } = ofield::remove(&mut marketplace.id, item_id);

        assert!(tx_context::sender(ctx) == owner, ENotOwner);

        marketplace.listed = marketplace.listed - 1;

        let item = ofield::remove(&mut id, true);

        let i : u64 = 0;
        while(i < offers){
            if(ofield::exists_(&id,i)){
             let Offer {
               id: offerID,
               paid,
               offerer,
              } = ofield::remove<u64,Offer<COIN>>(&mut id, i);
             transfer::public_transfer(paid, offerer);
             object::delete(offerID);
          };
          i = i + 1;
        };

        object::delete(id);
        item
    }

    public entry fun delist_and_take<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item_id: ID,
        ctx: &mut TxContext
    ) {
        let item = delist<COIN,N>(marketplace, item_id, ctx);
        transfer::public_transfer(item, tx_context::sender(ctx));

        emit(DeListEvent {
            item_id: item_id,
            seller: tx_context::sender(ctx),
        });
    }

    public fun calculate_fees(amount: u64,fee_pbs: u64,collateral_fee: u64) : u64{
         let fee_fraction = fixed_point32::create_from_rational(fee_pbs,collateral_fee);
         let fee_amount = fixed_point32::multiply_u64(amount,fee_fraction);
         fee_amount
    }

    public entry fun add_royalty_collection<T,COIN>(royaltycollection: &mut RoyaltyCollection,creator: address, bps: u64, ctx: &mut TxContext){
        assert!(royaltycollection.owner == tx_context::sender(ctx),ENotOwner);
        let token_name = string::from_ascii(type_name::into_string(type_name::get<T>()));
        let royaltyCollectionItem = RoyaltyCollectionItem<COIN>{
           id: object::new(ctx),
	       collection_type: token_name,
	       creator: creator,
	       bps: bps,
           balance: balance::zero<COIN>(),
        };
        ofield::add(&mut royaltycollection.id, token_name, royaltyCollectionItem);
    }

    public fun check_exists_royalty_collection<T,COIN>(royaltycollection: &mut RoyaltyCollection): bool {
        let token_name = string::from_ascii(type_name::into_string(type_name::get<T>()));
        ofield::exists_with_type<String, RoyaltyCollectionItem<COIN>>(&mut royaltycollection.id,token_name)
    }

    public entry fun update_royalty_collection<T,COIN>(royaltycollection: &mut RoyaltyCollection,bps: u64,creator: address,ctx: &mut TxContext) {
       let token_name = string::from_ascii(type_name::into_string(type_name::get<T>()));
       let royaltyCollectionItem = ofield::borrow_mut<String, RoyaltyCollectionItem<COIN>>(&mut royaltycollection.id,token_name);
       assert!(royaltyCollectionItem.creator == tx_context::sender(ctx) || royaltycollection.owner == tx_context::sender(ctx),ENotOwner);
       assert!(bps <= 1000,107);
       royaltyCollectionItem.bps = bps;
       royaltyCollectionItem.creator = creator;
    }

    public fun take_royalty_collection<T,COIN>(royaltycollection: &mut RoyaltyCollection, paid: &mut Coin<COIN>,amount: u64, ctx: &mut TxContext) {
       let token_name = string::from_ascii(type_name::into_string(type_name::get<T>()));
       let royaltyCollectionItem = ofield::borrow_mut<String, RoyaltyCollectionItem<COIN>>(&mut royaltycollection.id,token_name);
       let royalty_amount = calculate_fees(amount,royaltyCollectionItem.bps,10000);
       let royalty = coin::split<COIN>(paid,royalty_amount,ctx);
       coin::put(&mut royaltyCollectionItem.balance,royalty);
    }

    public entry fun whithdraw_royalty_collection<T,COIN>(royaltycollection: &mut RoyaltyCollection, ctx: &mut TxContext) {
       let token_name = string::from_ascii(type_name::into_string(type_name::get<T>()));
       let royaltyCollectionItem = ofield::borrow_mut<String, RoyaltyCollectionItem<COIN>>(&mut royaltycollection.id,token_name);
       assert!(royaltyCollectionItem.creator == tx_context::sender(ctx) || royaltycollection.owner == tx_context::sender(ctx),ENotOwner);
       let royalty = balance::value(&royaltyCollectionItem.balance);
       transfer::public_transfer(coin::take(&mut royaltyCollectionItem.balance,royalty,ctx),royaltyCollectionItem.creator);
    }
   
    public fun buy<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        royaltycollection: &mut RoyaltyCollection,
        item_id: ID,
        paid: Coin<COIN>,
        ctx: &mut TxContext
    ): N {
        let Listing<COIN,N> {
            id,
            ask,
            owner,
            offers,
        } = ofield::remove(&mut marketplace.id, item_id);

        assert!(ask == coin::value(&paid), EAmountIncorrect);
        marketplace.volume = marketplace.volume + coin::value(&paid);

        let coin_type = type_name::into_string(type_name::get<COIN>());
        let sui_type = type_name::into_string(type_name::get<SUI>());

        let coin_value = coin::value(&paid);
        if(marketplace.fee_pbs > 0 && coin_type == sui_type){
         let fee_amount = calculate_fees(coin_value,marketplace.fee_pbs,marketplace.collateral_fee);
         let fee = coin::split(&mut paid,fee_amount,ctx);
         transfer::public_transfer(fee,marketplace.owner); 
        };

        if(check_exists_royalty_collection<N,COIN>(royaltycollection) && coin_type == sui_type){
            take_royalty_collection<N,COIN>(royaltycollection,&mut paid,coin_value, ctx);
        };

        marketplace.listed = marketplace.listed - 1;

        emit(BuyEvent<COIN> {
            item_id: item_id,
            buyer: tx_context::sender(ctx),
            seller: owner,
	        amount: coin_value
        });

        transfer::public_transfer(paid,owner);
        
        let item = ofield::remove(&mut id, true);

        let i : u64 = 0;
        while(i < offers){
            if(ofield::exists_(&id,i)){
             let Offer {
               id: offerID,
               paid,
               offerer,
              } = ofield::remove<u64,Offer<COIN>>(&mut id, i);
             transfer::public_transfer(paid, offerer);
             object::delete(offerID);
          };
          i = i + 1;
        };

        object::delete(id);
        item
    }

    public entry fun buy_and_take<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        royaltycollection: &mut RoyaltyCollection,
        item_id: ID,
        paid: Coin<COIN>,
        ctx: &mut TxContext
    ) {

        transfer::public_transfer(
            buy<COIN,N>(marketplace, royaltycollection, item_id, paid,ctx),
            tx_context::sender(ctx)
        );
    }

    public entry fun change_price<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item_id: ID,
        price: u64,
        ctx: &mut TxContext
    ){
        assert!(price > 0, ENotOwner);
        let Listing<COIN,N> {
            id: _,
            ask,
            owner,
            offers: _,
        } = ofield::borrow_mut(&mut marketplace.id, item_id);

        assert!(tx_context::sender(ctx) == *owner, ENotOwner);

        *ask =  price;

        emit(ChangePriceEvent<COIN> {
            item_id: item_id,
            seller: tx_context::sender(ctx),
	        amount: price
        });
    }

    public entry fun mutate_owner(
        marketplace: &mut Marketplace,
        royaltycollection: &mut RoyaltyCollection,
        new_owner: address,
        ctx: &mut TxContext
    ){
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        marketplace.owner = new_owner;
        royaltycollection.owner = new_owner;
    }

    public entry fun mutate_fee_pbs(
        marketplace: &mut Marketplace,
        new_fee_pbs: u64,
        ctx: &mut TxContext
    ){
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        if(new_fee_pbs < marketplace.collateral_fee)
          marketplace.fee_pbs = new_fee_pbs;
    }
    public entry fun mutate_collateral_fee(
        marketplace: &mut Marketplace,
        new_collateral_fee: u64,
        ctx: &mut TxContext
    ){
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        marketplace.collateral_fee = new_collateral_fee;
    }

    public entry fun make_offer<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item_id: ID,
        paid: Coin<COIN>,
        ctx: &mut TxContext
    ){
        let id = object::new(ctx);
        let offer = Offer<COIN> {
                    id: id, 
                    paid: paid,
                    offerer: tx_context::sender(ctx),
        };

        let listing = ofield::borrow_mut<ID,Listing<COIN,N>>(&mut marketplace.id,item_id);
        
        ofield::add<u64,Offer<COIN>>(&mut listing.id, listing.offers, offer);
        listing.offers = listing.offers + 1
    }

    public entry fun remove_offer<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item_id: ID,
        offer_id: u64,
        ctx: &mut TxContext
    ){
        let listing = ofield::borrow_mut<ID,Listing<COIN,N>>(&mut marketplace.id,item_id);
        let Offer<COIN> {
            id,
            paid,
            offerer,
        } = ofield::remove<u64,Offer<COIN>>(&mut listing.id, offer_id);
        assert!(tx_context::sender(ctx) == offerer, 126);
        transfer::public_transfer(paid, offerer);
        object::delete(id);
    }

    public entry fun accept_offer<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        royaltycollection: &mut RoyaltyCollection,
        item_id: ID,
        offer_id: u64,
        ctx: &mut TxContext
    ){
        let Listing<COIN,N> {
            id,
            ask: _,
            owner,
            offers,
        } = ofield::remove(&mut marketplace.id, item_id);

        assert!(tx_context::sender(ctx) == owner, ENotOwner);
        
        marketplace.listed = marketplace.listed - 1;

        let item = ofield::remove<bool,N>(&mut id, true);

        let Offer<COIN> {
            id: idOffer,
            paid,
            offerer,
        } = ofield::remove<u64,Offer<COIN>>(&mut id, offer_id);

        emit(BuyEvent<COIN> {
            item_id: item_id,
            buyer: offerer,
            seller: owner,
	        amount: coin::value(&paid)
        });

        let coin_type = type_name::into_string(type_name::get<COIN>());
        let sui_type = type_name::into_string(type_name::get<SUI>());

        let coin_value = coin::value(&paid);
        if(marketplace.fee_pbs > 0 && coin_type == sui_type){
         let fee_amount = calculate_fees(coin_value,marketplace.fee_pbs,marketplace.collateral_fee);
         let fee = coin::split(&mut paid,fee_amount,ctx);
         transfer::public_transfer(fee,marketplace.owner); 
        };

        if(check_exists_royalty_collection<N,COIN>(royaltycollection) && coin_type == sui_type){
            take_royalty_collection<N,COIN>(royaltycollection,&mut paid,coin_value, ctx);
        };
        
        transfer::public_transfer(paid, tx_context::sender(ctx));
        transfer::public_transfer(item,offerer);
        object::delete(idOffer);

        let i : u64 = 0;
        while(i < offers){
            if(ofield::exists_(&id,i)){
             let Offer {
               id: offerID,
               paid,
               offerer,
              } = ofield::remove<u64,Offer<COIN>>(&mut id, i);
             transfer::public_transfer(paid, offerer);
             object::delete(offerID);
          };
          i = i + 1;
        };
        object::delete(id);
    }

    public entry fun listAuction<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item: N,
        min_bid: u64,
        min_bid_increment: u64,
        starts: u64,
        expires: u64,
        ctx: &mut TxContext
    ) {
        let item_id = object::id(&item);
        let listing = AuctionListing<COIN,N> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            item_id: item_id,
            bid: balance::zero<COIN>(),
            bid_amount: min_bid,
            min_bid: min_bid,
            min_bid_increment: min_bid_increment,
            starts: starts,
            expires: expires,
            bidder: tx_context::sender(ctx)
        };

        ofield::add(&mut listing.id, true, item);
        ofield::add(&mut marketplace.id, item_id, listing);

        marketplace.listed = marketplace.listed + 1;

        emit(ListingEvent<COIN,N> {
            item_id: item_id,
            amount: min_bid,
            seller: tx_context::sender(ctx),
            expires:expires
        });
    }

    public entry fun bid<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        item_id: ID,
        bid: Coin<COIN>,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        let auction = ofield::borrow_mut<ID,AuctionListing<COIN,N>>(&mut marketplace.id, item_id);
        let now : u64 = clock::timestamp_ms(clock);

        assert!(coin::value(&bid) >= auction.bid_amount + auction.min_bid_increment,2024);
        assert!( now > auction.starts && now < auction.expires, 2025);

        emit(ChangePriceEvent<COIN> {
            item_id: item_id,
            seller: auction.owner,
	        amount: coin::value(&bid)
        });

        if(balance::value(&auction.bid)>0)
         transfer::public_transfer(coin::take( &mut auction.bid,auction.bid_amount,ctx),auction.bidder);

        coin::put(&mut auction.bid,bid);
        auction.bid_amount = balance::value(&auction.bid);
        auction.bidder = tx_context::sender(ctx);

        //assert!(ask == coin::value(&paid), EAmountIncorrect);
    }

    public entry fun end_auction<COIN, N: key + store>(
        marketplace: &mut Marketplace,
        royaltycollection: &mut RoyaltyCollection,
        item_id: ID,
        //clock: &Clock,
        ctx: &mut TxContext
    ){
        let AuctionListing<COIN,N> {
            id,
            owner,
            item_id: _,
            bid,
            bid_amount: _,
            min_bid: _,
            min_bid_increment: _,
            starts: _,
            expires: _,
            bidder
        } = ofield::remove(&mut marketplace.id, item_id);
        marketplace.listed = marketplace.listed - 1;
        //let now : u64 = clock::timestamp_ms(clock);
        assert!(tx_context::sender(ctx) == owner, ENotOwner);

        emit(BuyEvent<COIN> {
            item_id: item_id,
            buyer: bidder,
            seller: owner,
	        amount: balance::value(&bid)
        });
        
        //assert!( now > auction.starts && now < auction.expires, 2025);
        let item = ofield::remove<bool,N>(&mut id, true);

        let coin_type = type_name::into_string(type_name::get<COIN>());
        let sui_type = type_name::into_string(type_name::get<SUI>());
        let balance_value = balance::value(&bid);
        let paid = coin::from_balance(bid,ctx);
        if(marketplace.fee_pbs > 0 && coin_type == sui_type && balance_value > 0){
         let fee_amount = calculate_fees(balance_value,marketplace.fee_pbs,marketplace.collateral_fee);
         let fee = coin::split(&mut paid,fee_amount,ctx);
         transfer::public_transfer(fee,marketplace.owner);
        };

        if(check_exists_royalty_collection<N,COIN>(royaltycollection) && coin_type == sui_type && balance_value > 0){
            take_royalty_collection<N,COIN>(royaltycollection,&mut paid,balance_value, ctx);
        };

        if(balance_value > 0){
         transfer::public_transfer(paid,owner);
        }else{
            coin::destroy_zero(paid);
        };
        transfer::public_transfer(item,bidder);
        object::delete(id);
    }
}


#[test_only]
module era::marketplaceTests {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario::{Self, Scenario};
    use era::marketplace::{Self,Marketplace};
    //use std::debug;
    //use std::type_name;
    //use std::ascii;
    //use sui::bag::{Self,Bag};

    // Simple Kitty-NFT data structure.
    struct Kitty has key, store {
        id: UID,
        kitty_id: u8
    }

    const ADMIN: address = @0xA55;
    const SELLER: address = @0x00A;
    const BUYER: address = @0x00B;
    
    /// Create a shared [`Marketplace`].
    fun create_marketplace(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, ADMIN);
        //let coin_type = type_name::into_string(type_name::get<Kitty>());
        //let sui_type = type_name::into_string(type_name::get<SUI>());
        //debug::print(&coin_type);
        //debug::print(&sui_type);
        //debug::print(&(coin_type==sui_type));
        //marketplace::create(test_scenario::ctx(scenario));
    }

    /// Mint SUI and send it to BUYER.
    fun mint_some_coin(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, ADMIN);
        let coin = coin::mint_for_testing<SUI>(1000, test_scenario::ctx(scenario));
        transfer::public_transfer(coin, BUYER);
    }

    /// Mint Kitty NFT and send it to SELLER.
    fun mint_kitty(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, ADMIN);
        let nft = Kitty { id: object::new(test_scenario::ctx(scenario)), kitty_id: 1 };
        transfer::public_transfer(nft, SELLER);
    }

    
    fun list_kitty(scenario: &mut Scenario) {
         test_scenario::next_tx(scenario, SELLER);
         let mkp_val = test_scenario::take_shared<Marketplace>(scenario);
         let mkp = &mut mkp_val;
         let nft = test_scenario::take_from_sender<Kitty>(scenario);

         marketplace::list<SUI,Kitty>(mkp, nft, 100, test_scenario::ctx(scenario));
         test_scenario::return_shared(mkp_val);
     }

     #[test]
    fun mint_stake() {
        let addr1 = @0xA;
        //let addr2 = @0xB;
        // create the NFT
        let scenario = test_scenario::begin(addr1);
        {
            create_marketplace(&mut scenario);
            //staking::init_for_testing<SUI,NFT>(ts::ctx(&mut scenario));
        };

        test_scenario::next_tx(&mut scenario, addr1);
        {
            //staking::mintNFT(b"test", b"a test", b"https://www.sui.io", ts::ctx(&mut scenario))
        };
        test_scenario::end(scenario);
    }

    // fun buy_kitty() {
    //     let scenario = &mut test_scenario::begin(ADMIN);

    //     create_marketplace(scenario);
    //     mint_some_coin(scenario);
    //     mint_kitty(scenario);
    //     list_kitty(scenario);

    //     // BUYER takes 100 SUI from his wallet and purchases Kitty.
    //     test_scenario::next_tx(scenario, BUYER);
    //     {
    //         let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
    //         let mkp_val = test_scenario::take_shared<Marketplace>(scenario);
    //         let mkp = &mut mkp_val;
    //         let bag = test_scenario::take_child_object<Marketplace, Bag>(scenario, mkp);
    //         let listing = test_scenario::take_child_object<Bag, bag::Item<Listing<Kitty, SUI>>>(scenario, &bag);
    //         let payment = coin::take(coin::balance_mut(&mut coin), 100, test_scenario::ctx(scenario));

    //         // Do the buy call and expect successful purchase.
    //         let nft = marketplace::buy<Kitty, SUI>(&mut bag, listing, payment);
    //         let kitty_id = burn_kitty(nft);

    //         assert!(kitty_id == 1, 0);

    //         test_scenario::return_shared(mkp_val);
    //         test_scenario::return_to_sender(scenario, bag);
    //         test_scenario::return_to_sender(scenario, coin);
    //     };
    // }

    // TODO(dyn-child) redo test with dynamic child object loading
    // // SELLER lists Kitty at the Marketplace for 100 SUI
    /*
    fun list_kitty(scenario: &mut Scenario) {
         test_scenario::next_tx(scenario, SELLER);
         let mkp_val = test_scenario::take_shared<Marketplace<SUI,Kitty>>(scenario);
         let mkp = &mut mkp_val;
         let bag = test_scenario::take_child_object<Marketplace<SUI,Kitty>, Bag>(scenario, mkp);
         let nft = test_scenario::take_from_sender<Kitty>(scenario);

         marketplace::list<SUI,Kitty>(mkp, &mut bag, nft, 100, test_scenario::ctx(scenario));
         test_scenario::return_shared(mkp_val);
         test_scenario::return_to_sender(scenario, bag);
     }*/

    // TODO(dyn-child) redo test with dynamic child object loading
    // #[test]
    // fun list_and_delist() {
    //     let scenario = &mut test_scenario::begin(ADMIN);

    //     create_marketplace(scenario);
    //     mint_kitty(scenario);
    //     list_kitty(scenario);

    //     test_scenario::next_tx(scenario, SELLER);
    //     {
    //         let mkp_val = test_scenario::take_shared<Marketplace>(scenario);
    //         let mkp = &mut mkp_val;
    //         let bag = test_scenario::take_child_object<Marketplace, Bag>(scenario, mkp);
    //         let listing = test_scenario::take_child_object<Bag, bag::Item<Listing<Kitty, SUI>>>(scenario, &bag);

    //         // Do the delist operation on a Marketplace.
    //         let nft = marketplace::delist<Kitty, SUI>(mkp, &mut bag, listing, test_scenario::ctx(scenario));
    //         let kitty_id = burn_kitty(nft);

    //         assert!(kitty_id == 1, 0);

    //         test_scenario::return_shared(mkp_val);
    //         test_scenario::return_to_sender(scenario, bag);
    //     };
    // }

    // TODO(dyn-child) redo test with dynamic child object loading
    // #[test]
    // #[expected_failure(abort_code = 1)]
    // fun fail_to_delist() {
    //     let scenario = &mut test_scenario::begin(ADMIN);

    //     create_marketplace(scenario);
    //     mint_some_coin(scenario);
    //     mint_kitty(scenario);
    //     list_kitty(scenario);

    //     // BUYER attempts to delist Kitty and he has no right to do so. :(
    //     test_scenario::next_tx(scenario, BUYER);
    //     {
    //         let mkp_val = test_scenario::take_shared<Marketplace>(scenario);
    //         let mkp = &mut mkp_val;
    //         let bag = test_scenario::take_child_object<Marketplace, Bag>(scenario, mkp);
    //         let listing = test_scenario::take_child_object<Bag, bag::Item<Listing<Kitty, SUI>>>(scenario, &bag);

    //         // Do the delist operation on a Marketplace.
    //         let nft = marketplace::delist<Kitty, SUI>(mkp, &mut bag, listing, test_scenario::ctx(scenario));
    //         let _ = burn_kitty(nft);

    //         test_scenario::return_shared(mkp_val);
    //         test_scenario::return_to_sender(scenario, bag);
    //     };
    // }

    // TODO(dyn-child) redo test with dynamic child object loading
    // #[test]
    // fun buy_kitty() {
    //     let scenario = &mut test_scenario::begin(ADMIN);

    //     create_marketplace(scenario);
    //     mint_some_coin(scenario);
    //     mint_kitty(scenario);
    //     list_kitty(scenario);

    //     // BUYER takes 100 SUI from his wallet and purchases Kitty.
    //     test_scenario::next_tx(scenario, BUYER);
    //     {
    //         let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
    //         let mkp_val = test_scenario::take_shared<Marketplace>(scenario);
    //         let mkp = &mut mkp_val;
    //         let bag = test_scenario::take_child_object<Marketplace, Bag>(scenario, mkp);
    //         let listing = test_scenario::take_child_object<Bag, bag::Item<Listing<Kitty, SUI>>>(scenario, &bag);
    //         let payment = coin::take(coin::balance_mut(&mut coin), 100, test_scenario::ctx(scenario));

    //         // Do the buy call and expect successful purchase.
    //         let nft = marketplace::buy<Kitty, SUI>(&mut bag, listing, payment);
    //         let kitty_id = burn_kitty(nft);

    //         assert!(kitty_id == 1, 0);

    //         test_scenario::return_shared(mkp_val);
    //         test_scenario::return_to_sender(scenario, bag);
    //         test_scenario::return_to_sender(scenario, coin);
    //     };
    // }

    // TODO(dyn-child) redo test with dynamic child object loading
    // #[test]
    // #[expected_failure(abort_code = 0)]
    // fun fail_to_buy() {
    //     let scenario = &mut test_scenario::begin(ADMIN);

    //     create_marketplace(scenario);
    //     mint_some_coin(scenario);
    //     mint_kitty(scenario);
    //     list_kitty(scenario);

    //     // BUYER takes 100 SUI from his wallet and purchases Kitty.
    //     test_scenario::next_tx(scenario, BUYER);
    //     {
    //         let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);
    //         let mkp_val = test_scenario::take_shared<Marketplace>(scenario);
    //         let mkp = &mut mkp_val;
    //         let bag = test_scenario::take_child_object<Marketplace, Bag>(scenario, mkp);
    //         let listing = test_scenario::take_child_object<Bag, bag::Item<Listing<Kitty, SUI>>>(scenario, &bag);

    //         // AMOUNT here is 10 while expected is 100.
    //         let payment = coin::take(coin::balance_mut(&mut coin), 10, test_scenario::ctx(scenario));

    //         // Attempt to buy and expect failure purchase.
    //         let nft = marketplace::buy<Kitty, SUI>(&mut bag, listing, payment);
    //         let _ = burn_kitty(nft);

    //         test_scenario::return_shared(mkp_val);
    //         test_scenario::return_to_sender(scenario, bag);
    //         test_scenario::return_to_sender(scenario, coin);
    //     };
    // }

    fun burn_kitty(kitty: Kitty): u8 {
        let Kitty{ id, kitty_id } = kitty;
        object::delete(id);
        kitty_id
    }
}