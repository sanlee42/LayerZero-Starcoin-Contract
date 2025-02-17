/// A key-value store for UA and msglib to write and read any arbitrary data:
/// 1) UA composability: UA can write data to the store, and other UA can read it.
/// 2) New data types for msglib: new msglibs in the future can write data to the store for UA to read.
module layerzero::bulletin {
    use StarcoinFramework::Table::{Self, Table};
    use StarcoinFramework::Errors;
    use layerzero_common::semver::SemVer;
    use layerzero_common::utils::assert_type_signer;

    friend layerzero::endpoint;

    const ELAYERZERO_BULLETIN_EXISTED: u64 = 0x00;
    const ELAYERZERO_BULLETIN_NOT_EXISTED: u64 = 0x01;

    struct Bulletin has key, store {
        // bytes -> bytes
        values: Table<vector<u8>, vector<u8>>,
    }

    struct MsgLibBulletin has key {
        // msglib version -> bulletin
        bulletin: Table<SemVer, Bulletin>
    }

    fun init_module(account: &signer) {
        move_to(account, MsgLibBulletin {
            bulletin: Table::new()
        })
    }

    public(friend) fun init_ua_bulletin<UA>(account: &signer) {
        assert_type_signer<UA>(account);
        move_to(account, Bulletin {
            values: Table::new()
        })
    }

    public(friend) fun init_msglib_bulletin(version: SemVer) acquires MsgLibBulletin {
        let msglib_bulletin = borrow_global_mut<MsgLibBulletin>(@layerzero);
        assert!(
            !Table::contains(&msglib_bulletin.bulletin, copy version),
            Errors::already_published(ELAYERZERO_BULLETIN_EXISTED)
        );

        Table::add(&mut msglib_bulletin.bulletin, version, Bulletin {
            values: Table::new()
        })
    }

    public(friend) fun ua_write(ua_address: address, key: vector<u8>, value: vector<u8>) acquires Bulletin {
        let bulletin = borrow_global_mut<Bulletin>(ua_address);
        //FIXME: upsert
        Table::add(&mut bulletin.values, key, value)
    }

    public(friend) fun msglib_write(msglib_version: SemVer, key: vector<u8>, value: vector<u8>) acquires MsgLibBulletin {
        let msglib_bulletin = borrow_global_mut<MsgLibBulletin>(@layerzero);
        assert_msglib_bulletin_existed(msglib_bulletin, copy msglib_version);

        let bulletin = Table::borrow_mut(&mut msglib_bulletin.bulletin, msglib_version);
        //FIXME: upsert
        Table::add(&mut bulletin.values, key, value)
    }

    public fun ua_read(ua_address: address, key: vector<u8>): vector<u8> acquires Bulletin {
        let bulletin = borrow_global<Bulletin>(ua_address);
        *Table::borrow(&bulletin.values, key)
    }

    public fun msglib_read(msglib_version: SemVer, key: vector<u8>): vector<u8> acquires MsgLibBulletin {
        let msglib_bulletin = borrow_global<MsgLibBulletin>(@layerzero);
        assert_msglib_bulletin_existed(msglib_bulletin, copy msglib_version);

        let bulletin = Table::borrow(&msglib_bulletin.bulletin, msglib_version);
        *Table::borrow(&bulletin.values, key)
    }

    fun assert_msglib_bulletin_existed(msglib_bulletin: &MsgLibBulletin, msglib_version: SemVer) {
        assert!(
            Table::contains(&msglib_bulletin.bulletin, msglib_version),
            Errors::not_published(ELAYERZERO_BULLETIN_NOT_EXISTED)
        );
    }

    #[test_only]
    use StarcoinFramework::Signer::address_of;

    #[test_only]
    public fun init_module_for_test(account: &signer) {
        init_module(account);
    }

    #[test_only]
    use test::bulletin_test::TestUa;

    #[test_only]
    use layerzero_common::semver::build_version;

    #[test_only]
    fun setup(lz: &signer, ua: &signer) acquires MsgLibBulletin {
        use StarcoinFramework::Account;
        use StarcoinFramework::STC::STC;
        Account::create_account_with_address<STC>(address_of(lz));
        init_module_for_test(lz);

        init_msglib_bulletin(build_version(1, 0));
        init_msglib_bulletin(build_version(2, 0));
        init_ua_bulletin<TestUa>(ua);
    }

    #[test(lz = @layerzero, ua = @test)]
    fun test_set_ua_bulletin(lz: &signer, ua: &signer) acquires MsgLibBulletin, Bulletin {
        setup(lz, ua);

        ua_write(address_of(ua), b"key", b"value");
        assert!(ua_read(address_of(ua), b"key") == b"value", 0);

        ua_write(address_of(ua), b"key", b"value2");
        assert!(ua_read(address_of(ua), b"key") == b"value2", 0);
    }

    #[test(lz = @layerzero, ua = @test)]
    fun test_set_msglib_bulletin(lz: &signer, ua: &signer) acquires MsgLibBulletin {
        setup(lz, ua);

        msglib_write(build_version(1, 0), b"key", b"value");
        assert!(msglib_read(build_version(1, 0), b"key") == b"value", 0);

        msglib_write(build_version(2, 0), b"key", b"value2");
        assert!(msglib_read(build_version(2, 0), b"key") == b"value2", 0);

        msglib_write(build_version(1, 0), b"key", b"value3");
        assert!(msglib_read(build_version(1, 0), b"key") == b"value3", 0);
    }
}

#[test_only]
module test::bulletin_test {
    struct TestUa {}
}
