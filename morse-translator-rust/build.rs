// build.rs — Tell the linker to link against libpigpiod_if2 when the
// "gpio" feature is enabled.  The library is provided by the pigpio
// package on Raspberry Pi OS (apt install libpigpio-dev pigpio).

fn main() {
    if std::env::var("CARGO_FEATURE_GPIO").is_ok() {
        // Link the pigpio daemon interface library.
        println!("cargo:rustc-link-lib=pigpiod_if2");
    }
}
