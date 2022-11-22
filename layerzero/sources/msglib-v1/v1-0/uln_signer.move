// a signer can be a multi-sig or resources account
// the implemention of signer can be arbitrary.
module layerzero::uln_signer {
    use StarcoinFramework::Table::{Self,Table};
    use layerzero_common::utils::assert_u16;
    use StarcoinFramework::Signer::address_of;
    use layerzero_common::acl::{Self, ACL};
    use StarcoinFramework::Errors;

    const EULN_SIGNER_NO_CONFIG: u64 = 0x00;
    const EULN_SIGNER_NOT_REGISTERED: u64 = 0x01;
    const EULN_SIGNER_ALREADY_REGISTERED: u64 = 0x02;

    struct Fee has store, drop {
        base_fee: u128,
        fee_per_byte: u128
    }

    struct Config has key {
        fees: Table<u64, Fee>,
        acl: ACL
    }

    //
    // signer functions
    //
    //FIXME: entry fun
    public fun register(account: &signer) {
        assert!(!exists<Config>(address_of(account)), Errors::already_published(EULN_SIGNER_ALREADY_REGISTERED));

        move_to(account, Config {
            fees: Table::new(),
            acl: acl::empty()
        });
    }
    //FIXME: entry fun
    public fun set_fee(account: &signer, remote_chain_id: u64, base_fee: u128, fee_per_byte: u128) acquires Config {
        assert_u16(remote_chain_id);

        let account_addr = address_of(account);
        assert_signer_registered(account_addr);

        let config = borrow_global_mut<Config>(account_addr);
        //FIXME: upsert
        Table::add(&mut config.fees, remote_chain_id, Fee {
            base_fee,
            fee_per_byte
        });
    }

    //FIXME: entry fun
    /// if not in the allow list, add it. Otherwise, remove it.
    public fun allowlist(account: &signer, ua: address) acquires Config {
        let account_addr = address_of(account);
        assert_signer_registered(account_addr);

        let config = borrow_global_mut<Config>(account_addr);
        acl::allowlist(&mut config.acl, ua);
    }
    // FIXME: entry fun
    /// if not in the deny list, add it. Otherwise, remove it.
    public fun denylist(account: &signer, ua: address) acquires Config {
        let account_addr = address_of(account);
        assert_signer_registered(account_addr);

        let config = borrow_global_mut<Config>(account_addr);
        acl::denylist(&mut config.acl, ua);
    }


    //
    // view functions
    //
    public fun quote(uln_signer: address, ua: address, remote_chain_id: u64, payload_size: u64): u128 acquires Config {
        assert_signer_registered(uln_signer);

        let config = borrow_global<Config>(uln_signer);

        acl::assert_allowed(&config.acl, &ua);

        assert!(Table::contains(&config.fees, remote_chain_id), EULN_SIGNER_NO_CONFIG);
        let fee = Table::borrow(&config.fees, remote_chain_id);
        //FIXME: payload_size as u64
        fee.fee_per_byte * (payload_size as u128) + fee.base_fee
    }

    public fun check_permission(uln_signer: address, ua: address): bool acquires Config {
        assert_signer_registered(uln_signer);

        let config = borrow_global<Config>(uln_signer);
        acl::is_allowed(&config.acl, &ua)
    }

    fun assert_signer_registered(account: address) {
        assert!(exists<Config>(account), EULN_SIGNER_NOT_REGISTERED);
    }

    #[test_only]
    fun setup(lz: &signer, uln_singer: &signer) {
        use StarcoinFramework::Signer;
        use StarcoinFramework::Account;
        use StarcoinFramework::STC::STC;

        Account::create_account_with_address<STC>(Signer::address_of(lz));
        Account::create_account_with_address<STC>(Signer::address_of(uln_singer));

        register(uln_singer);
    }

    #[test(lz = @layerzero, uln_singer = @1234)]
    fun test_acl(lz: signer, uln_singer: signer) acquires Config {
        setup(&lz, &uln_singer);

        let alice = @1122;
        let bob = @3344;
        let carol = @5566;

        // by default, all accounts are permitted
        assert!(check_permission(address_of(&uln_singer), alice), 0);
        assert!(check_permission(address_of(&uln_singer), bob), 0);
        assert!(check_permission(address_of(&uln_singer), carol), 0);

        // allow alice, deny bob
        allowlist(&uln_singer, alice);
        denylist(&uln_singer, bob);
        assert!(check_permission(address_of(&uln_singer), alice), 0);
        assert!(!check_permission(address_of(&uln_singer), bob), 0);
        assert!(!check_permission(address_of(&uln_singer), carol), 0); // carol is not in the allow list

        // allow carol, now he is also permitted, to test we can allow more than 1 account
        allowlist(&uln_singer, carol);
        assert!(check_permission(address_of(&uln_singer), carol), 0);

        // remove carol from the whitelist. not permitted again
        allowlist(&uln_singer, carol);
        assert!(!check_permission(address_of(&uln_singer), carol), 0);

        // remove alice, now alice and carol are permitted but not bob
        allowlist(&uln_singer, alice);
        assert!(check_permission(address_of(&uln_singer), alice), 0);
        assert!(!check_permission(address_of(&uln_singer), bob), 0);
        assert!(check_permission(address_of(&uln_singer), carol), 0);
    }

    #[test(lz = @layerzero, uln_singer = @1234)]
    fun test_quote_fee(lz: signer, uln_singer: signer)  acquires Config {
        setup(&lz, &uln_singer);

        set_fee(&uln_singer, 1, 100, 10);
        assert!(quote(address_of(&uln_singer), @1122, 1, 100) == 1100, 0);
    }
}