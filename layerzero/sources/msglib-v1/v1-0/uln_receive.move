module layerzero::uln_receive {
    use layerzero_common::packet;
    use StarcoinFramework::Errors;
    use layerzero::endpoint;
    use StarcoinFramework::Table::{Self, Table};
    use StarcoinFramework::Event::{Self, EventHandle};
    use layerzero::uln_config::{Self, get_address_size, inbound_confirmations};
    use StarcoinFramework::Signer::address_of;
    use layerzero::packet_event;
    use layerzero_common::utils::{assert_length, type_address, assert_signer};
    use msglib_auth::msglib_cap::MsgLibReceiveCapability;

    const EULN_INVALID_VERIFIER: u64 = 0x00;
    const EULN_INSUFFICIENT_CONFIRMATIONS: u64 = 0x01;
    const EULN_PROPOSAL_NOT_FOUND: u64 = 0x02;

    struct ULN {}

    struct CapStore has key {
        cap: MsgLibReceiveCapability
    }

    struct ProposalKey has copy, drop {
        oracle: address,
        hash: vector<u8>,
    }

    struct ProposalStore has key {
        // key -> confirmation
        proposals: Table<ProposalKey, u64>,
    }

    struct EventStore has key {
        oracle_events: EventHandle<SignerEvent>,
        relayer_events: EventHandle<SignerEvent>,
    }

    struct SignerEvent has drop, store {
        signer: address,
        hash: vector<u8>,
        confirmations: u64,
    }
    //FIXME: entry fun
    // layerzero and msglib auth only
    public fun init(account: &signer) {
        assert_signer(account, @layerzero);

        // next major version = 1.0
        let cap = endpoint::register_msglib<ULN>(account, true);
        move_to(account, CapStore { cap });

        move_to(account, ProposalStore { proposals: Table::new() });

        move_to(account, EventStore {
            oracle_events: Event::new_event_handle<SignerEvent>(account),
            relayer_events: Event::new_event_handle<SignerEvent>(account)
        });
    }
    //FIXME: entry fun
    public fun relayer_verify<UA>(
        account: &signer,
        packet_bytes: vector<u8>,
        relayer_confirmation: u64
    ) acquires CapStore, ProposalStore, EventStore {
        let src_chain_id = packet::decode_src_chain_id(&packet_bytes);
        let uln_config = uln_config::get_uln_config(type_address<UA>(), src_chain_id);
        let required_confirmation = inbound_confirmations(&uln_config);

        assert!(
            relayer_confirmation >= required_confirmation,
            Errors::invalid_argument(EULN_INSUFFICIENT_CONFIRMATIONS),
        );

        // assert verifier permissions
        let verifier = address_of(account);
        assert!(
            uln_config::relayer(&uln_config) == verifier,
            Errors::invalid_state(EULN_INVALID_VERIFIER)
        );

        // assert the proposal exists from the UA-configured oracle
        let hash = packet::hash_sha3_packet_bytes(copy packet_bytes);
        assert_proposal_exists(
            uln_config::oracle(&uln_config),
            copy hash,
            required_confirmation
        );
        let packet = packet::decode_packet(&packet_bytes, get_address_size(src_chain_id));

        // emit verifier event, with confirmation.
        let cap_store = borrow_global<CapStore>(@layerzero);
        endpoint::receive<UA>(copy packet, &cap_store.cap);

        // emit verifer event
        let event_store = borrow_global_mut<EventStore>(@layerzero);
        Event::emit_event<SignerEvent>(
            &mut event_store.relayer_events,
            SignerEvent {
                signer: verifier,
                hash,
                confirmations: relayer_confirmation,
            },
        );

        // emit inbound event
        packet_event::emit_inbound_event(packet);
    }
    //FIXME: entry fun
    public fun oracle_propose(account: &signer, hash: vector<u8>, confirmations: u64) acquires ProposalStore, EventStore {
        assert_length(&hash, 32);

        let store = borrow_global_mut<ProposalStore>(@layerzero);

        let oracle = address_of(account);
        let key = ProposalKey {
            oracle,
            hash: copy hash,
        };

        if (Table::contains(&store.proposals, copy key)) {
            let confirmations_ref = Table::borrow_mut(&mut store.proposals, copy key);
            // only accept a higher confirmation number
            assert!(*confirmations_ref < confirmations, Errors::invalid_argument(EULN_INSUFFICIENT_CONFIRMATIONS));
            *confirmations_ref = confirmations;
        } else {
            // just insert into the table
            Table::add(&mut store.proposals, key, confirmations);
        };

        let event_store = borrow_global_mut<EventStore>(@layerzero);
        Event::emit_event<SignerEvent>(
            &mut event_store.oracle_events,
            SignerEvent {
                signer: oracle,
                hash,
                confirmations,
            },
        );
    }

    public fun get_proposal_confirmations(oracle: address, hash: vector<u8>): u64 acquires ProposalStore {
        let store = borrow_global<ProposalStore>(@layerzero);
        let key = ProposalKey {
            oracle,
            hash,
        };
        if (Table::contains(&store.proposals, copy key)) {
            return *Table::borrow(&store.proposals, key)
        };
        0
    }

    fun assert_proposal_exists(oracle: address, hash: vector<u8>, required_confirmation: u64) acquires ProposalStore {
        let store = borrow_global<ProposalStore>(@layerzero);
        let key = ProposalKey {
            oracle,
            hash,
        };

        assert!(
            Table::contains(&store.proposals, copy key),
            Errors::not_published(EULN_PROPOSAL_NOT_FOUND),
        );

        let oracle_confirmation = Table::borrow(&store.proposals, key);
        assert!(
            *oracle_confirmation >= required_confirmation,
            Errors::invalid_argument(EULN_INSUFFICIENT_CONFIRMATIONS),
        );
    }
}