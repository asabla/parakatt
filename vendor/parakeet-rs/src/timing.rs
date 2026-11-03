//! Optional stage measurements for local inference benchmarks.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct InferenceTimings {
    pub frontend_secs: f64,
    /// Includes input preparation and copying encoder outputs to the host.
    pub encoder_secs: f64,
    pub decoder_secs: f64,
    pub timestamps_secs: f64,
}
