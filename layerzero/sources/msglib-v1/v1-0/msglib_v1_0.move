// major version 1
// minor version 0
module layerzero::msglib_v1_0 {
    use layerzero::uln_config::{Self, UlnConfig, assert_address_size};
    use StarcoinFramework::Event::{Self, EventHandle};
    use layerzero_common::utils::{type_address};
    use layerzero_common::packet::{Self, Packet};
    use StarcoinFramework::Token::{Self,Token, value};
    use StarcoinFramework::STC::STC;
    use StarcoinFramework::Account;
    use layerzero::uln_signer;
    use StarcoinFramework::Vector;
    use layerzero::packet_event;
    use layerzero::admin;
    use zro::zro::ZRO;
    use msglib_auth::msglib_cap::{Self, MsgLibSendCapability};
    use StarcoinFramework::Errors;

    friend layerzero::msglib_router;

    const ELAYERZERO_INSUFFICIENT_FEE: u64 = 0x00;
    const ELAYERZERO_NOT_SUPPORTED: u64 = 0x01;

    fun init_module(account: &signer) {
        move_to(account, GlobalStore {
            treasury_fee_bps: 0,
            outbound_events: Event::new_event_handle<UlnEvent>(account)
        });
    }

    struct GlobalStore has key {
        treasury_fee_bps: u8,
        outbound_events: EventHandle<UlnEvent>,
    }

    struct UlnEvent has drop, store {
        uln_config: UlnConfig,
    }

    //
    // admins functions
    //
    //FIXME: entry fun
    public fun set_treasury_fee(account: &signer, fee_bps: u8) acquires GlobalStore {
        admin::assert_config_admin(account);

        let fee = borrow_global_mut<GlobalStore>(@layerzero);
        fee.treasury_fee_bps = fee_bps;
    }

    //
    // router functions
    //
    public(friend) fun send<UA>(
        packet: &Packet,
        native_fee: Token<STC>,
        zro_fee: Token<ZRO>,
        _msglib_params: vector<u8>,
        cap: &MsgLibSendCapability
    ): (Token<STC>, Token<ZRO>) acquires GlobalStore {
        msglib_cap::assert_send_version(cap, 1, 0);
        let dst_chain_id = packet::dst_chain_id(packet);

        // assert the destination address size is valid
        assert_address_size(dst_chain_id, Vector::length(&packet::dst_address(packet)));

        let ua_address = type_address<UA>();
        let uln_config = uln_config::get_uln_config(ua_address, dst_chain_id);
        let payload_size = Vector::length(&packet::payload(packet));

        // quote oracle
        let oracle = uln_config::oracle(&uln_config);
        let oracle_quote = uln_signer::quote(
            oracle,
            ua_address,
            dst_chain_id,
            payload_size
        );

        // quote verifier
        let relayer = uln_config::relayer(&uln_config);
        let relayer_quote = uln_signer::quote(
            relayer,
            ua_address,
            dst_chain_id,
            payload_size,
        );

        // quote treasury
        let pay_in_zro = value(&zro_fee) > 0;
        let treasury_quote = quote_treasury(oracle_quote, relayer_quote, pay_in_zro);

        // pay fee
        let (native_refund, zro_refund) = if (pay_in_zro) {
            pay_fee_with_zro(native_fee, zro_fee, relayer_quote, relayer, oracle_quote, oracle, treasury_quote)
        } else {
            let native_refund = pay_fee(native_fee, relayer_quote, relayer, oracle_quote, oracle, treasury_quote);
            (native_refund, zro_fee)
        };

        emit_uln_event(uln_config);
        packet_event::emit_outbound_event(packet);

        (native_refund, zro_refund)
    }

    public(friend) fun set_ua_config<UA>(chain_id: u64, config_type: u8, config_bytes: vector<u8>, cap: &MsgLibSendCapability){
        msglib_cap::assert_send_version(cap, 1, 0);
        uln_config::set_ua_config<UA>(chain_id, config_type, config_bytes)
    }

    //
    // public view functions
    //
    public fun get_ua_config(ua_address: address, chain_id: u64, config_type: u8): vector<u8>{
        uln_config::get_ua_config(ua_address, chain_id, config_type)
    }

    public fun quote(ua_address: address, dst_chain_id: u64, payload_size: u64, pay_in_zro: bool, _msglib_params: vector<u8>): (u128, u128) acquires GlobalStore {
        let app_config = uln_config::get_uln_config(ua_address, dst_chain_id);

        let oracle_quote = uln_signer::quote(uln_config::oracle(&app_config), ua_address, dst_chain_id, payload_size);

        let relayer_quote = uln_signer::quote(uln_config::relayer(&app_config), ua_address, dst_chain_id, payload_size);

        let treasury_quote = quote_treasury(oracle_quote, relayer_quote, pay_in_zro);

        if (pay_in_zro) {
            (oracle_quote + relayer_quote, treasury_quote)
        } else {
            (oracle_quote + relayer_quote + treasury_quote, 0)
        }
    }

    public fun quote_treasury(oracle_quote: u128, relayer_quote: u128, pay_in_zro: bool): u128 acquires GlobalStore {
        if (pay_in_zro) {
            abort ELAYERZERO_NOT_SUPPORTED
        };
        let fee = borrow_global<GlobalStore>(@layerzero);
        (oracle_quote + relayer_quote) * (fee.treasury_fee_bps as u128) / 10000
    }

    //
    // internal functions
    //
    fun pay_fee(
        fee: Token<STC>,
        relayer_quote: u128,
        relayer: address,
        oracle_quote: u128,
        oracle: address,
        treasury_quote: u128,
    ): Token<STC> {
        assert!(
            value(&fee) >= treasury_quote + oracle_quote + relayer_quote,
            Errors::invalid_argument(ELAYERZERO_INSUFFICIENT_FEE)
        );

        // paying and refund the rest
        let oracle_fee = Token::withdraw(&mut fee, oracle_quote);
        Account::deposit(oracle, oracle_fee);

        let relayer_fee = Token::withdraw(&mut fee, relayer_quote);
        Account::deposit(relayer, relayer_fee);

        let treasury_fee = Token::withdraw(&mut fee, treasury_quote);
        Account::deposit(@layerzero, treasury_fee);

        fee
    }

    fun pay_fee_with_zro(
        native_fee: Token<STC>,
        zro_fee: Token<ZRO>,
        relayer_quote: u128,
        relayer: address,
        oracle_quote: u128,
        oracle: address,
        treasury_quote: u128,
    ): (Token<STC>, Token<ZRO>) {
        assert!(
            value(&native_fee) >= oracle_quote + relayer_quote
                && value(&zro_fee) >= treasury_quote,
            Errors::invalid_argument(ELAYERZERO_INSUFFICIENT_FEE)
        );

        // paying and refund the rest
        let oracle_fee = Token::withdraw(&mut native_fee, oracle_quote);
        Account::deposit<STC>(oracle, oracle_fee);

        let relayer_fee = Token::withdraw(&mut native_fee, relayer_quote);
        Account::deposit<STC>(relayer, relayer_fee);

        let treasury_fee = Token::withdraw<ZRO>(&mut zro_fee, treasury_quote);
        Account::deposit<ZRO>(@layerzero, treasury_fee);

        (native_fee, zro_fee)
    }

    fun emit_uln_event(uln_config: UlnConfig) acquires GlobalStore {
        let config = borrow_global_mut<GlobalStore>(@layerzero);
        Event::emit_event<UlnEvent>(
            &mut config.outbound_events,
            UlnEvent { uln_config },
        );
    }

    #[test_only]
    public fun init_module_for_test(account: &signer) {
        init_module(account);
    }

    #[test_only]
    fun setup(lz: &signer) {
        use StarcoinFramework::Account;
        use StarcoinFramework::Signer;

        Account::create_account_with_address<STC>(Signer::address_of(lz));
        admin::init_module_for_test(lz);
        init_module(lz);
    }

    #[test(lz = @layerzero)]
    fun test_quote_treasury(lz: &signer) acquires GlobalStore {
        setup(lz);

        let treasury_fee_bps = 100;
        set_treasury_fee(lz, treasury_fee_bps);

        let oracle_quote = 123;
        let relayer_quote = 456;
        let treasury_quote = quote_treasury(oracle_quote, relayer_quote, false);
        assert!(treasury_quote == 5, 0); // 123 + 456 = 579, 579 * 100 / 10000 = 5
    }
    //FIXME
    /*
        #[test(lz = @layerzero, aptos = @aptos_framework)]
        fun test_pay_fee(lz: &signer, aptos: &signer) acquires GlobalStore {
            use StarcoinFramework::STC::{Self, STC};
            use StarcoinFramework::Account;

            setup(lz);

            let treasury_fee_bps = 100;
            set_treasury_fee(lz, treasury_fee_bps);

            let oracle_quote = 123;
            let relayer_quote = 456;
            let treasury_quote = quote_treasury(oracle_quote, relayer_quote, false);

            let oracle = @0x11;
            let relayer = @0x22;
            let treasury = @layerzero;
            Account::create_account_with_address<STC>(oracle);
            Account::create_account_with_address<STC>(relayer);

            // init the aptos_coin and give counter_root the mint ability.

            let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos);
            let fee = coin::mint<AptosCoin>(
                1000,
                &mint_cap,
            );

            let fee = pay_fee(fee, relayer_quote, relayer, oracle_quote, oracle, treasury_quote);

            assert!(coin::balance<AptosCoin>(oracle) == oracle_quote, 0);
            assert!(coin::balance<AptosCoin>(relayer) == relayer_quote, 0);
            assert!(coin::balance<AptosCoin>(treasury) == treasury_quote, 0);
            assert!(value(&fee) == 1000 - oracle_quote - relayer_quote - treasury_quote, 0);

            coin::burn(fee, &burn_cap);
            coin::destroy_burn_cap(burn_cap);
            coin::destroy_mint_cap(mint_cap);

    }
    */
}