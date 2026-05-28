// build.rs — compile update_metadata.proto into Rust types
fn main() {
    prost_build::compile_protos(
        &["proto/update_metadata.proto"],
        &["proto/"],
    )
    .expect("Failed to compile update_metadata.proto");
}
