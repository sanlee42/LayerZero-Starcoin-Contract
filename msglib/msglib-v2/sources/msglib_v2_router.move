module msglib_v2::msglib_v2_router {
    use layerzero_common::packet::Packet;
    use StarcoinFramework::STC::STC;
    use StarcoinFramework::Token::Token;
    use zro::zro::ZRO;
    use msglib_auth::msglib_cap::MsgLibSendCapability;

    const ELAYERZERO_NOT_SUPPORTED: u64 = 0x00;

    public fun send<UA>(
        _packet: &Packet,
        _native_fee: Token<STC>,
        _zro_fee: Token<ZRO>,
        _msglib_params: vector<u8>,
        _cap: &MsgLibSendCapability
    ): (Token<STC>, Token<ZRO>) {
        abort ELAYERZERO_NOT_SUPPORTED
    }

    public fun quote(_ua_address: address, _dst_chain_id: u64, _payload_size: u64, _pay_in_zro: bool, _msglib_params: vector<u8>): (u128, u128) {
        abort ELAYERZERO_NOT_SUPPORTED
    }

    public fun set_ua_config<UA>(_chain_id: u64, _config_type: u8, _config_bytes: vector<u8>, _cap: &MsgLibSendCapability) {
        abort ELAYERZERO_NOT_SUPPORTED
    }

    public fun get_ua_config(_ua_address: address, _chain_id: u64, _config_type: u8): vector<u8>{
        abort ELAYERZERO_NOT_SUPPORTED
    }
}