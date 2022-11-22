module executor_v2::executor_v2 {
    use StarcoinFramework::Token::Token;
    use StarcoinFramework::STC::STC;
    use layerzero_common::packet::Packet;
    use executor_auth::executor_cap::ExecutorCapability;

    const ELAYERZERO_NOT_SUPPORTED: u64 = 0x00;

    public fun request<UA>(
        _executor: address,
        _packet: &Packet,
        _adapter_params: vector<u8>,
        _fee: Token<STC>,
        _cap: &ExecutorCapability
    ): Token<STC> {
        abort ELAYERZERO_NOT_SUPPORTED
    }

    public fun quote_fee(_ua_address: address, _executor: address, _dst_chain_id: u64, _adapter_params: vector<u8>): u64 {
        abort ELAYERZERO_NOT_SUPPORTED
    }
}