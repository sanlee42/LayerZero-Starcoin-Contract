#[test_only]
module test::example_oft {
    use StarcoinFramework::String;
    use StarcoinFramework::Token::{Self, BurnCapability, FreezeCapability, MintCapability};
    use layerzero::endpoint::UaCapability;
    use layerzero::oft;

    struct ExampleOFT {}

    struct Capabilities has key {
        lz_cap: UaCapability<ExampleOFT>,
        burn_cap: BurnCapability<ExampleOFT>,
        freeze_cap: FreezeCapability<ExampleOFT>,
        mint_cap: MintCapability<ExampleOFT>,
    }

    fun init_module(account: &signer) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<ExampleOFT>(
            account,
            String::utf8(b"Moon OFT"),
            String::utf8(b"Moon"),
            6,
            true,
        );

        let lz_cap = oft::init_oft<ExampleOFT>(account, mint_cap, burn_cap);

        move_to(account, Capabilities {
            lz_cap,
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }
}
