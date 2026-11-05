#[path = "support/input_contracts.rs"]
mod contracts;

#[test]
fn malformed_unicode_and_configuration_inputs_preserve_contracts() {
    for input in [
        "",
        "re:[",
        "re:(a+)+$",
        "$100 ${name} $$",
        "First.|Second paragraph.",
        "[general]\nauto_paste = false\n",
    ] {
        contracts::check(input.as_bytes());
    }
    for character in ['a', 'é', '€', '𐍈', '\u{0301}'] {
        for length in [49, 50, 167, 250, 499, 500, 501] {
            contracts::check(character.to_string().repeat(length).as_bytes());
        }
    }
    // A fixed seed makes failures reproducible in the ordinary test suite.
    let mut seed = 0x6a09_e667_f3bc_c909_u64;
    for length in 0..512 {
        let bytes: Vec<u8> = (0..length)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                seed as u8
            })
            .collect();
        contracts::check(&bytes);
    }
}
