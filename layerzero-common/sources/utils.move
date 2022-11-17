module layerzero_common::utils {
    use StarcoinFramework::Vector;
    use StarcoinFramework::Errors;
    use StarcoinFramework::Signer::address_of;
    use StarcoinFramework::TypeInfo::{account_address, type_of};

    const ELAYERZERO_INVALID_INDEX: u64 = 0x00;
    const ELAYERZERO_INVALID_U16: u64 = 0x01;
    const ELAYERZERO_INVALID_LENGTH: u64 = 0x02;
    const ELAYERZERO_PERMISSION_DENIED: u64 = 0x03;

    public fun vector_slice<T: copy>(vec: &vector<T>, start: u64, end: u64): vector<T> {
        assert!(start < end && end <= Vector::length(vec), Errors::invalid_argument(ELAYERZERO_INVALID_INDEX));
        let slice = Vector::empty<T>();
        let i = start;
        while (i < end) {
            Vector::push_back(&mut slice, *Vector::borrow(vec, i));
            i = i + 1;
        };
        slice
    }

    public fun assert_signer(account: &signer, account_address: address) {
        assert!(address_of(account) == account_address, Errors::invalid_state(ELAYERZERO_PERMISSION_DENIED));
    }

    public fun assert_length(data: &vector<u8>, length: u64) {
        assert!(Vector::length(data) == length, Errors::invalid_argument(ELAYERZERO_INVALID_LENGTH));
    }

    public fun assert_type_signer<TYPE>(account: &signer) {
        assert!(type_address<TYPE>() == address_of(account), Errors::invalid_state(ELAYERZERO_PERMISSION_DENIED));
    }

    public fun assert_u16(chain_id: u64) {
        assert!(chain_id <= 65535, Errors::invalid_argument(ELAYERZERO_INVALID_U16));
    }

    public fun type_address<TYPE>(): address {
        account_address(&type_of<TYPE>())
    }

    #[test]
    fun test_vector_slice() {
        let vec = vector<u8>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        let slice = vector_slice<u8>(&vec, 2, 8);
        assert!(slice == vector<u8>[3, 4, 5, 6, 7, 8], 0);

        let slice = vector_slice<u8>(&vec, 2, 3);
        assert!(slice == vector<u8>[3], 0);
    }

    #[test]
    #[expected_failure(abort_code = 7)]
    fun test_vector_slice_with_invalid_index() {
        let vec = vector<u8>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        vector_slice<u8>(&vec, 2, 20);
    }
}