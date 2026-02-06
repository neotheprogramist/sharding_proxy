/// Increment a felt252 by 1 with overflow protection via u256.
pub fn safe_increment(value: felt252, error_msg: felt252) -> felt252 {
    let as_u256: u256 = value.into();
    (as_u256 + 1).try_into().expect(error_msg)
}
