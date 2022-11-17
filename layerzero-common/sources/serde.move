module layerzero_common::serde {
    use StarcoinFramework::Vector;
    use StarcoinFramework::Errors;

    const EINVALID_LENGTH: u64 = 0x00;

    public fun serialize_u8(buf: &mut vector<u8>, v: u8) {
        Vector::push_back(buf, v);
    }

    public fun serialize_u16(buf: &mut vector<u8>, v: u64) {
        assert!(v <= 65535, Errors::invalid_argument(EINVALID_LENGTH));
        serialize_u8(buf, (((v >> 8) & 0xFF) as u8));
        serialize_u8(buf, ((v & 0xFF) as u8));
    }

    public fun serialize_u64(buf: &mut vector<u8>, v: u64) {
        serialize_u8(buf, (((v >> 56) & 0xFF) as u8));
        serialize_u8(buf, (((v >> 48) & 0xFF) as u8));
        serialize_u8(buf, (((v >> 40) & 0xFF) as u8));
        serialize_u8(buf, (((v >> 32) & 0xFF) as u8));
        serialize_u8(buf, (((v >> 24) & 0xFF) as u8));
        serialize_u8(buf, (((v >> 16) & 0xFF) as u8));
        serialize_u8(buf, (((v >> 8) & 0xFF) as u8));
        serialize_u8(buf, ((v & 0xFF) as u8));
    }

    public fun serialize_vector(buf: &mut vector<u8>, v: vector<u8>) {
        Vector::append(buf, v);
    }

    public fun deserialize_u8(buf: &vector<u8>): u8 {
        assert!(Vector::length(buf) == 1, Errors::invalid_argument(EINVALID_LENGTH));
        *Vector::borrow(buf, 0)
    }

    public fun deserialize_u16(buf: &vector<u8>): u64 {
        assert!(Vector::length(buf) == 2, Errors::invalid_argument(EINVALID_LENGTH));
        ((*Vector::borrow(buf, 0) as u64) << 8) + (*Vector::borrow(buf, 1) as u64)
    }

    public fun deserialize_u64(buf: &vector<u8>): u64 {
        assert!(Vector::length(buf) == 8, Errors::invalid_argument(EINVALID_LENGTH));
        ((*Vector::borrow(buf, 0) as u64) << 56)
        + ((*Vector::borrow(buf, 1) as u64) << 48)
        + ((*Vector::borrow(buf, 2) as u64) << 40)
        + ((*Vector::borrow(buf, 3) as u64) << 32)
        + ((*Vector::borrow(buf, 4) as u64) << 24)
        + ((*Vector::borrow(buf, 5) as u64) << 16)
        + ((*Vector::borrow(buf, 6) as u64) << 8)
        + (*Vector::borrow(buf, 7) as u64)
    }

    #[test]
    fun test_serialize() {
        let data = Vector::empty<u8>();
        serialize_u8(&mut data, 1);
        assert!(data == vector<u8>[1], 0);

        let data = Vector::empty<u8>();
        serialize_u16(&mut data, 258);
        assert!(data == vector<u8>[1, 2], 0);

        let data = Vector::empty<u8>();
        serialize_u64(&mut data, 72623859790382856);
        assert!(data == vector<u8>[1, 2, 3, 4, 5, 6, 7, 8], 0);
    }

    #[test]
    fun test_deserialize() {
        let data = deserialize_u8(&vector<u8>[1]);
        assert!(data == 1, 0);

        let data = deserialize_u16(&vector<u8>[1, 2]);
        assert!(data == 258, 0);

        let data = deserialize_u64(&vector<u8>[1, 2, 3, 4, 5, 6, 7, 8]);
        assert!(data == 72623859790382856, 0);
    }
}