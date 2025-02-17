// support only type 1 and type 2
module layerzero::executor_v1 {
    use StarcoinFramework::Errors;
    use StarcoinFramework::Vector;
    use StarcoinFramework::Signer::address_of;

    use StarcoinFramework::Table::{Self, Table};
    use StarcoinFramework::Event::{Self, EventHandle};

    use StarcoinFramework::Token::{Self, Token};
    use StarcoinFramework::STC::STC;
    use StarcoinFramework::Account;

    use layerzero_common::utils::{assert_u16, type_address, vector_slice};
    use layerzero_common::serde;
    use layerzero_common::acl::{Self, ACL};
    use layerzero_common::packet::{Self, Packet};
    use executor_auth::executor_cap::ExecutorCapability;
    use executor_auth::executor_cap;
    use layerzero::admin;

    friend layerzero::executor_router;

    struct Executor {}

    const EEXECUTOR_INVALID_ADAPTER_PARAMS_SIZE: u64 = 0x00;
    const EEXECUTOR_INVALID_ADAPTER_PARAMS_TYPE: u64 = 0x01;
    const EEXECUTOR_DEFAULT_ADAPTER_PARAMS_NOT_FOUND: u64 = 0x02;
    const EEXECUTOR_INSUFFICIENT_FEE: u64 = 0x03;
    const EEXECUTOR_AIRDROP_TOO_MUCH: u64 = 0x04;
    const EEXECUTOR_CONFIG_NOT_FOUND: u64 = 0x05;
    const EEXECUTOR_ALEADY_REGISTERED: u64 = 0x06;
    const EEXECUTOR_NOT_REGISTERED: u64 = 0x07;
    const EEXECUTOR_AIRDROP_DONE: u64 = 0x08;

    const PRICE_RATIO_DENOMINATOR: u64 = 10000000000; // 10^10

    struct ExecutorConfig has key {
        // chain id -> fee
        fee: Table<u64, Fee>,
        acl: ACL,
    }

    struct Fee has store, drop, copy {
        airdrop_amt_cap: u64,
        price_ratio: u64,
        gas_price: u64,
    }

    struct AdapterParamsConfig has key {
        params: Table<u64, vector<u8>>,
    }

    struct EventStore has key {
        request_events: EventHandle<RequestEvent>,
        airdrop_events: EventHandle<AirdropEvent>,
    }

    struct RequestEvent has drop, store {
        executor: address,
        guid: vector<u8>,
        adapter_params: vector<u8>,
    }

    struct AirdropEvent has drop, store {
        src_chain_id: u64,
        guid: vector<u8>,
        receiver: address,
        amount: u128,
    }

    struct JobKey has copy, drop {
        guid: vector<u8>,
        executor: address,
    }

    struct JobStore has key {
        done: Table<JobKey, bool>
    }

    fun init_module(account: &signer) {
        move_to(account, AdapterParamsConfig {
            params: Table::new(),
        });

        move_to(account, EventStore {
            request_events: Event::new_event_handle<RequestEvent>(account),
            airdrop_events: Event::new_event_handle<AirdropEvent>(account),
        });

        move_to(account, JobStore {
            done: Table::new(),
        });
    }

    //
    // UA functions
    //
    public(friend) fun request<UA>(
        executor: address,
        packet: &Packet,
        adapter_params: vector<u8>,
        fee: Token<STC>,
        cap: &ExecutorCapability
    ): Token<STC> acquires AdapterParamsConfig, ExecutorConfig, EventStore {
        executor_cap::assert_version(cap, 1);
        // check fee
        let ua_address = type_address<UA>();
        let dst_chain_id = packet::dst_chain_id(packet);

        // use default one if adapter_params is empty
        if (Vector::length(&adapter_params) == 0) {
            adapter_params = get_default_adapter_params(dst_chain_id);
        };
        //FIXME: make quote_fee u128
        let fee_expected = quote_fee(ua_address, executor, dst_chain_id, copy adapter_params);
        let fee_expected = (fee_expected as u128);
        let fee_value = Token::value(&fee);
        assert!(fee_value >= fee_expected, Errors::invalid_argument(EEXECUTOR_INSUFFICIENT_FEE));

        // pay fee
        let refund = Token::withdraw(&mut fee, fee_value - fee_expected);
        Account::deposit(executor, fee);

        // emit event with GUID
        let event_store = borrow_global_mut<EventStore>(@layerzero);
        let guid = packet::get_guid(packet);
        Event::emit_event<RequestEvent>(
            &mut event_store.request_events,
            RequestEvent {
                executor,
                guid,
                adapter_params,
            },
        );

        refund
    }

    //
    // executor functions
    //
    //FIXME: entry fun
    public fun register(account: &signer) {
        assert!(!exists<ExecutorConfig>(address_of(account)), Errors::already_published(EEXECUTOR_ALEADY_REGISTERED));

        move_to(account, ExecutorConfig {
            fee: Table::new(),
            acl: acl::empty(),
        });
    }
    //FIXME: entry fun
    public fun airdrop(
        account: &signer,
        src_chain_id: u64,
        guid: vector<u8>,
        receiver: address,
        amount: u128,
    ) acquires EventStore, JobStore {
        assert_u16(src_chain_id);

        // check if job is done
        let job_store = borrow_global_mut<JobStore>(@layerzero);
        let job_key = JobKey {
            guid: copy guid,
            executor: address_of(account),
        };
        assert!(
            !Table::contains(&job_store.done, copy job_key),
            Errors::already_published(EEXECUTOR_AIRDROP_DONE)
        );

        // add it to the job store to prevent double airdrop
        Table::add(&mut job_store.done, job_key, true);
        Account::pay_from<STC>(account, receiver, amount);

        // emit event
        let event_store = borrow_global_mut<EventStore>(@layerzero);
        Event::emit_event<AirdropEvent>(
            &mut event_store.airdrop_events,
            AirdropEvent {
                src_chain_id,
                guid,
                receiver,
                amount,
            },
        );
    }
    //FIXME: entry fun
    public fun set_fee(
        account: &signer,
        chain_id: u64,
        airdrop_amt_cap: u64,
        price_ratio: u64,
        gas_price: u64,
    ) acquires ExecutorConfig {
        assert_u16(chain_id);

        let account_addr = address_of(account);
        assert_executor_registered(account_addr);

        let config = borrow_global_mut<ExecutorConfig>(account_addr);
        //FIXME:upsert
        Table::add(&mut config.fee, chain_id, Fee {
            airdrop_amt_cap,
            price_ratio,
            gas_price,
        });
    }
    //FIXME: entry fun
    /// if not in the allow list, add it. Otherwise, remove it.
    public fun allowlist(account: &signer, ua: address) acquires ExecutorConfig {
        let account_addr = address_of(account);
        assert_executor_registered(account_addr);

        let config = borrow_global_mut<ExecutorConfig>(account_addr);
        acl::allowlist(&mut config.acl, ua);
    }

    //FIXME: entry fun
    /// if not in the deny list, add it. Otherwise, remove it.
    public fun denylist(account: &signer, ua: address) acquires ExecutorConfig {
        let account_addr = address_of(account);
        assert_executor_registered(account_addr);

        let config = borrow_global_mut<ExecutorConfig>(account_addr);
        acl::denylist(&mut config.acl, ua);
    }

    //
    // admin functions
    //
    //FIXME: entry fun
    public fun set_default_adapter_params(
        account: &signer,
        chain_id: u64,
        adapter_params: vector<u8>,
    ) acquires AdapterParamsConfig {
        admin::assert_config_admin(account);
        assert_u16(chain_id);

        let (type, _, _, _) = decode_adapter_params(&adapter_params);
        assert!(type == 1, Errors::invalid_argument(EEXECUTOR_INVALID_ADAPTER_PARAMS_TYPE));

        let config = borrow_global_mut<AdapterParamsConfig>(@layerzero);
        //FIXME: upsert
        Table::add(&mut config.params, chain_id, adapter_params);
    }

    //
    // public view functions
    //
    public fun quote_fee(ua_address: address, executor: address, dst_chain_id: u64, adapter_params: vector<u8>): u64 acquires ExecutorConfig, AdapterParamsConfig {
        assert_executor_registered(executor);
        assert_u16(dst_chain_id);

        // check permission
        let config = borrow_global<ExecutorConfig>(executor);
        acl::assert_allowed(&config.acl, &ua_address);

        // use default one if adapter_params is empty
        if (Vector::length(&adapter_params) == 0) {
            adapter_params = get_default_adapter_params(dst_chain_id);
        };

        // get fee config from executor
        assert!(Table::contains(&config.fee, dst_chain_id), Errors::not_published(EEXECUTOR_CONFIG_NOT_FOUND));
        let fee_config = Table::borrow(&config.fee, dst_chain_id);

        // decode and verify adapter params
        let (_type, extra_gas, airdrop_amount, _receiver) = decode_adapter_params(&adapter_params);
        assert!(airdrop_amount <= fee_config.airdrop_amt_cap, Errors::invalid_argument(EEXECUTOR_AIRDROP_TOO_MUCH));

        (extra_gas * fee_config.gas_price + airdrop_amount) * fee_config.price_ratio / PRICE_RATIO_DENOMINATOR
    }

    public fun check_permission(executor: address, ua_address: address): bool acquires ExecutorConfig {
        assert_executor_registered(executor);
        let config = borrow_global<ExecutorConfig>(executor);
        acl::is_allowed(&config.acl, &ua_address)
    }

    public fun get_default_adapter_params(chain_id: u64): vector<u8> acquires AdapterParamsConfig {
        assert_u16(chain_id);
        let config = borrow_global<AdapterParamsConfig>(@layerzero);
        assert!(Table::contains(&config.params, chain_id), Errors::not_published(EEXECUTOR_DEFAULT_ADAPTER_PARAMS_NOT_FOUND));
        *Table::borrow(&config.params, chain_id)
    }

    //
    // internal functions
    //
    fun assert_executor_registered(account: address) {
        assert!(exists<ExecutorConfig>(account), Errors::not_published(EEXECUTOR_NOT_REGISTERED));
    }

    // txType 1
    // bytes  [2       8       ]
    // fields [txType  extraGas]
    // txType 2
    // bytes  [2       8         8           unfixed       ]
    // fields [txType  extraGas  airdropAmt  airdropAddress]
    fun decode_adapter_params(adapter_params: &vector<u8>): (u64, u64, u64, vector<u8>) {
        let size = Vector::length(adapter_params);
        assert!(size == 10 || size > 18, Errors::invalid_argument(EEXECUTOR_INVALID_ADAPTER_PARAMS_SIZE));

        let tx_type = serde::deserialize_u16(&vector_slice(adapter_params, 0, 2));

        let extra_gas;
        let airdrop_amount = 0;
        let receiver = Vector::empty<u8>();
        if (tx_type == 1) {
            assert!(size == 10, Errors::invalid_argument(EEXECUTOR_INVALID_ADAPTER_PARAMS_SIZE));

            extra_gas = serde::deserialize_u64(&vector_slice(adapter_params, 2, 10));
        } else if (tx_type == 2) {
            assert!(size > 18, Errors::invalid_argument(EEXECUTOR_INVALID_ADAPTER_PARAMS_SIZE));

            extra_gas = serde::deserialize_u64(&vector_slice(adapter_params, 2, 10));
            airdrop_amount = serde::deserialize_u64(&vector_slice(adapter_params, 10, 18));
            receiver = vector_slice(adapter_params, 18, size);
        } else {
            abort Errors::invalid_argument(EEXECUTOR_INVALID_ADAPTER_PARAMS_TYPE)
        };

        (tx_type, extra_gas, airdrop_amount, receiver)
    }

    #[test_only]
    public fun init_module_for_test(account: &signer) {
        init_module(account);
    }

    #[test_only]
    fun setup(lz: &signer, executor: &signer) {
        use StarcoinFramework::Account;
        use StarcoinFramework::STC::STC;

        Account::create_account_with_address<STC>(address_of(lz));
        Account::create_account_with_address<STC>(address_of(executor));
        admin::init_module_for_test(lz);
        init_module_for_test(lz);

        register(executor);
    }

    #[test]
    fun test_decode_adapter_params() {
        // type 1
        let adapter_params = Vector::empty<u8>();
        serde::serialize_u16(&mut adapter_params, 1);
        serde::serialize_u64(&mut adapter_params, 100);

        let (type, extra_gas, airdrop_amount, receiver) = decode_adapter_params(&adapter_params);
        assert!(type == 1, 0);
        assert!(extra_gas == 100, 0);
        assert!(airdrop_amount == 0, 0);
        assert!(Vector::length(&receiver) == 0, 0);

        // type 2
        let adapter_params = Vector::empty<u8>();
        serde::serialize_u16(&mut adapter_params, 2);
        serde::serialize_u64(&mut adapter_params, 100);
        serde::serialize_u64(&mut adapter_params, 5000);
        Vector::append(&mut adapter_params, vector<u8>[1, 2, 3, 4, 5]);

        let (type, extra_gas, airdrop_amount, receiver) = decode_adapter_params(&adapter_params);
        assert!(type == 2, 0);
        assert!(extra_gas == 100, 0);
        assert!(airdrop_amount == 5000, 0);
        assert!(receiver == vector<u8>[1, 2, 3, 4, 5], 0);
    }

    #[test(lz = @layerzero, executor = @1234)]
    fun test_set_fee(lz: &signer, executor: &signer) acquires ExecutorConfig {
        setup(lz, executor);

        set_fee(executor, 1, 1, 2, 3);

        let config = borrow_global<ExecutorConfig>(address_of(executor));
        let fee = Table::borrow(&config.fee, 1);
        assert!(fee.airdrop_amt_cap == 1, 0);
        assert!(fee.price_ratio == 2, 0);
        assert!(fee.gas_price == 3, 0);

        set_fee(executor, 1, 4, 5, 6);
        let config = borrow_global<ExecutorConfig>(address_of(executor));
        let fee = Table::borrow(&config.fee, 1);
        assert!(fee.airdrop_amt_cap == 4, 0);
        assert!(fee.price_ratio == 5, 0);
        assert!(fee.gas_price == 6, 0);
    }

    #[test(lz = @layerzero, executor = @1234)]
    fun test_quote_fee(lz: &signer, executor: &signer) acquires ExecutorConfig, AdapterParamsConfig {
        setup(lz, executor);

        set_fee(executor, 1, 100000, PRICE_RATIO_DENOMINATOR / 2, 3);

        let adapter_params = Vector::empty<u8>();
        serde::serialize_u16(&mut adapter_params, 2);
        serde::serialize_u64(&mut adapter_params, 100);
        serde::serialize_u64(&mut adapter_params, 5000);
        Vector::append(&mut adapter_params, vector<u8>[1, 2, 3, 4, 5]);

        let fee = quote_fee(@0x1, address_of(executor), 1, adapter_params);
        assert!(fee == (5000 + 100 * 3) / 2, 0);
    }

    #[test(lz = @layerzero, executor = @1234)]
    fun test_acl(lz: signer, executor: signer) acquires ExecutorConfig {
        setup(&lz, &executor);

        let alice = @1122;
        let bob = @3344;
        let carol = @5566;

        // by default, all accounts are permitted
        assert!(check_permission(address_of(&executor), alice), 0);
        assert!(check_permission(address_of(&executor), bob), 0);
        assert!(check_permission(address_of(&executor), carol), 0);

        // allow alice, deny bob
        allowlist(&executor, alice);
        denylist(&executor, bob);
        assert!(check_permission(address_of(&executor), alice), 0);
        assert!(!check_permission(address_of(&executor), bob), 0);
        assert!(!check_permission(address_of(&executor), carol), 0); // carol is not in the allow list

        // allow carol, now he is also permitted, to test we can allow more than 1 account
        allowlist(&executor, carol);
        assert!(check_permission(address_of(&executor), carol), 0);

        // remove carol from the whitelist. not permitted again
        allowlist(&executor, carol);
        assert!(!check_permission(address_of(&executor), carol), 0);

        // remove alice, now alice and carol are permitted but not bob
        allowlist(&executor, alice);
        assert!(check_permission(address_of(&executor), alice), 0);
        assert!(!check_permission(address_of(&executor), bob), 0);
        assert!(check_permission(address_of(&executor), carol), 0);
    }

    #[test(lz = @layerzero, executor = @1234)]
    fun test_default_adapter_params(lz: signer, executor: signer) acquires AdapterParamsConfig {
        setup(&lz, &executor);

        // config
        let default_adapter_params = Vector::empty<u8>();
        serde::serialize_u16(&mut default_adapter_params, 1);
        serde::serialize_u64(&mut default_adapter_params, 100);
        set_default_adapter_params(&lz, 1, default_adapter_params);

        // check
        let actual = get_default_adapter_params(1);
        assert!(actual == default_adapter_params, 0);
    }
}
