/// LZApp module provides a simple way for lz app owners to manage their application configurations:
/// 1. provides entry functions to config instead of calling from app with UaCapability
/// 2. allows the app to drop/store the next payload
/// 3. enables to send lz message with both Aptos coin and with ZRO coin, or only Aptos coin
module layerzero::lzapp {
    use StarcoinFramework::Errors;
    use StarcoinFramework::Signer::address_of;
    use layerzero::endpoint::{Self, UaCapability};
    use zro::zro::ZRO;
    use StarcoinFramework::Token::{Self,Token};
    use StarcoinFramework::STC::STC;
    use StarcoinFramework::Table::{Self, Table};
    use layerzero_common::utils::{assert_type_signer, type_address, vector_slice, assert_u16};
    use layerzero_common::serde;
    use StarcoinFramework::Hash;

    const ELZAPP_ALREADY_INITIALIZED: u64 = 0x00;
    const ELZAPP_NOT_INITIALIZED: u64 = 0x01;
    const ELZAPP_DST_GAS_INSUFFICIENCY: u64 = 0x02;
    const ELZAPP_PAYLOAD_NOT_FOUND: u64 = 0x03;
    const ELZAPP_INVALID_PAYLOAD: u64 = 0x04;

    struct Capabilities<phantom UA> has key {
        cap: UaCapability<UA>,
    }

    struct Path has copy, drop {
        chain_id: u64,
        packet_type: u64,
    }

    struct Config has key {
        min_dst_gas_lookup: Table<Path, u64>, // path -> min gas
    }

    struct Origin has copy, drop {
        src_chain_id: u64,
        src_address: vector<u8>,
        nonce: u64
    }

    struct StoredPayload has key {
        stored_payloads: Table<Origin, vector<u8>>, // origin -> payload hash
    }

    public fun init<UA>(account: &signer, cap: UaCapability<UA>) {
        assert_type_signer<UA>(account);

        let account_address = address_of(account);
        assert!(
            !exists<Config>(account_address) && !exists<Capabilities<UA>>(account_address),
            Errors::already_published(ELZAPP_ALREADY_INITIALIZED)
        );

        move_to(account, Capabilities {
            cap,
        });

        move_to(account, Config {
            min_dst_gas_lookup: Table::new(),
        });

        move_to(account, StoredPayload {
            stored_payloads: Table::new(),
        });
    }

    //
    // admin functions to interact with Layerzero endpoints
    //
    //FIXME: entry fun
    public fun set_config<UA>(
        account: &signer,
        major_version: u64,
        minor_version: u8,
        chain_id: u64,
        config_type: u8,
        config_bytes: vector<u8>,
    ) acquires Capabilities {
        assert_type_signer<UA>(account);

        let ua_address = type_address<UA>();
        let cap = borrow_global<Capabilities<UA>>(ua_address);
        endpoint::set_config(major_version, minor_version, chain_id, config_type, config_bytes, &cap.cap);
    }
    //FIXME: entry fun
    public fun set_send_msglib<UA>(account: &signer, chain_id: u64, major: u64, minor: u8) acquires Capabilities {
        assert_type_signer<UA>(account);

        let ua_address = type_address<UA>();
        let cap = borrow_global<Capabilities<UA>>(ua_address);
        endpoint::set_send_msglib(chain_id, major, minor, &cap.cap);
    }
    //FIXME: entry fun
    public fun set_receive_msglib<UA>(account: &signer, chain_id: u64, major: u64, minor: u8) acquires Capabilities {
        assert_type_signer<UA>(account);

        let ua_address = type_address<UA>();
        let cap = borrow_global<Capabilities<UA>>(ua_address);
        endpoint::set_receive_msglib<UA>(chain_id, major, minor, &cap.cap);
    }

    public entry fun set_executor<UA>(account: &signer, chain_id: u64, version: u64, executor: address) acquires Capabilities {
        assert_type_signer<UA>(account);

        let ua_address = type_address<UA>();
        let cap = borrow_global<Capabilities<UA>>(ua_address);
        endpoint::set_executor<UA>(chain_id, version, executor, &cap.cap);
    }
    //FIXME: entry fun
    // force to receive the payload but do nothing if blocking
    public fun force_resume<UA>(account: &signer, src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires Capabilities {
        assert_type_signer<UA>(account);

        let ua_address = type_address<UA>();
        let cap = borrow_global<Capabilities<UA>>(ua_address);
        endpoint::lz_receive(src_chain_id, src_address, payload, &cap.cap); // drop the payload
    }
    
    //FIXME: entry fun
    // if the app does not want to consume the next payload
    public fun store_next_payload<UA>(account: &signer, src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires Capabilities, StoredPayload {
        assert_type_signer<UA>(account);

        let ua_address = type_address<UA>();
        let cap = borrow_global<Capabilities<UA>>(ua_address);
        let nonce = endpoint::lz_receive(src_chain_id, src_address, payload, &cap.cap);

        // store it
        let store = borrow_global_mut<StoredPayload>(ua_address);
        Table::add(&mut store.stored_payloads, Origin {
            src_chain_id,
            src_address,
            nonce,
        }, Hash::sha3_256(payload));
    }
    //FIXME: entry fun
    public fun bulletin_ua_write<UA>(account: &signer, key: vector<u8>, value: vector<u8>) acquires Capabilities {
        assert_type_signer<UA>(account);

        let ua_address = type_address<UA>();
        let cap = borrow_global<Capabilities<UA>>(ua_address);
        endpoint::bulletin_ua_write(key, value, &cap.cap);
    }
    //FIXME: entry fun
    // admin function to do gas configurations
    public fun set_min_dst_gas<UA>(account: &signer, chain_id: u64, pk_type: u64, min_dst_gas: u64) acquires Config {
        assert_type_signer<UA>(account);
        assert_u16(chain_id);

        let ua_address = type_address<UA>();
        let config = borrow_global_mut<Config>(ua_address);
        //FIXME: Upset
        Table::add(&mut config.min_dst_gas_lookup, Path {
            chain_id,
            packet_type: pk_type,
        }, min_dst_gas);
    }

    //
    // ua functions for sending/receiving messages
    //
    public fun send<UA>(
        dst_chain_id: u64,
        dst_address: vector<u8>,
        payload: vector<u8>,
        fee: Token<STC>,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
        cap: &UaCapability<UA>,
    ): (u64, Token<STC>) {
        let (nonce, native_refund, zro_refund) = endpoint::send(dst_chain_id, dst_address, payload, fee, Token::zero<ZRO>(), adapter_params, msglib_params, cap);
        Token::destroy_zero(zro_refund);
        (nonce, native_refund)
    }

    public fun send_with_zro<UA>(
        dst_chain_id: u64,
        dst_address: vector<u8>,
        payload: vector<u8>,
        native_fee: Token<STC>,
        zro_fee: Token<ZRO>,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
        cap: &UaCapability<UA>
    ): (u64, Token<STC>, Token<ZRO>) {
        endpoint::send(dst_chain_id, dst_address, payload, native_fee, zro_fee, adapter_params, msglib_params, cap)
    }

    public fun remove_stored_paylaod<UA>(src_chain_id: u64, src_address: vector<u8>, nonce: u64, payload: vector<u8>, _cap: &UaCapability<UA>) acquires StoredPayload {
        let store = borrow_global_mut<StoredPayload>(type_address<UA>());
        let origin = Origin {
            src_chain_id,
            src_address,
            nonce,
        };
        assert!(Table::contains(&store.stored_payloads, origin), Errors::not_published(ELZAPP_PAYLOAD_NOT_FOUND));
        let hash = Table::remove(&mut store.stored_payloads, origin);
        assert!(hash == Hash::sha3_256(payload), Errors::invalid_argument(ELZAPP_INVALID_PAYLOAD));
    }

    //
    // view functions
    //
    public fun assert_gas_limit(ua_address: address, chain_id: u64, packet_type: u64, adapter_params: &vector<u8>, extra_gas: u64) acquires Config {
        assert!(exists<Config>(ua_address), Errors::not_published(ELZAPP_NOT_INITIALIZED));

        let config = borrow_global<Config>(ua_address);
        let min_dst_gas = Table::borrow(&config.min_dst_gas_lookup, Path {
            chain_id,
            packet_type,
        });

        let gas = serde::deserialize_u64(&vector_slice(adapter_params, 2, 10));
        assert!(gas >= *min_dst_gas + extra_gas, Errors::invalid_argument(ELZAPP_DST_GAS_INSUFFICIENCY));
    }

    public fun has_stored_payload(ua_address: address, src_chain_id: u64, src_address: vector<u8>, nonce: u64): bool acquires StoredPayload {
        let store = borrow_global<StoredPayload>(ua_address);
        Table::contains(&store.stored_payloads, Origin {
            src_chain_id,
            src_address,
            nonce,
        })
    }
}