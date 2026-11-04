use std::io::Cursor;
use std::path::Path;

use parakatt_cli::input::{read_audio, MAX_SAMPLES};

fn wav(path: &Path, rate: u32, channels: u16, bits: u16, values: &[i32]) {
    let mut writer = hound::WavWriter::create(
        path,
        hound::WavSpec {
            channels,
            sample_rate: rate,
            bits_per_sample: bits,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .unwrap();
    for value in values {
        writer.write_sample(*value).unwrap();
    }
    writer.finalize().unwrap();
}

#[test]
fn integer_pcm_keeps_signed_full_scale_and_sample_order() {
    let temp = tempfile::tempdir().unwrap();
    for bits in [16, 24, 32] {
        let path = temp.path().join(format!("{bits}.wav"));
        let scale = 1_i64 << (bits - 1);
        wav(
            &path,
            16_000,
            1,
            bits,
            &[(-scale) as i32, 0, (scale / 2) as i32],
        );
        assert_eq!(read_audio(&path, false).unwrap(), [-1.0, 0.0, 0.5]);
    }
}

#[test]
fn float_wav_and_raw_have_identical_samples() {
    let temp = tempfile::tempdir().unwrap();
    let values = [-1.0_f32, -0.25, 0.0, 0.5, 1.0];
    let wav_path = temp.path().join("speech å.wav");
    let raw_path = temp.path().join("speech.raw");
    let mut writer = hound::WavWriter::create(
        &wav_path,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16_000,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        },
    )
    .unwrap();
    for value in values {
        writer.write_sample(value).unwrap();
    }
    writer.finalize().unwrap();
    std::fs::write(
        &raw_path,
        values
            .into_iter()
            .flat_map(f32::to_le_bytes)
            .collect::<Vec<_>>(),
    )
    .unwrap();
    assert_eq!(read_audio(&wav_path, false).unwrap(), values);
    assert_eq!(read_audio(&raw_path, true).unwrap(), values);
}

#[test]
fn unsupported_rate_channels_and_sample_type_are_rejected() {
    let temp = tempfile::tempdir().unwrap();
    for (rate, channels, bits) in [(48_000, 1, 16), (16_000, 2, 16), (16_000, 1, 8)] {
        let path = temp.path().join(format!("{rate}-{channels}-{bits}.wav"));
        wav(&path, rate, channels, bits, &[1, 1]);
        assert!(read_audio(&path, false).is_err());
    }
}

#[test]
fn empty_partial_nonfinite_out_of_range_and_silent_raw_are_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("input.raw");
    for bytes in [
        vec![],
        vec![1, 2, 3],
        f32::NAN.to_le_bytes().to_vec(),
        f32::INFINITY.to_le_bytes().to_vec(),
        1.1_f32.to_le_bytes().to_vec(),
        0.0_f32.to_le_bytes().to_vec(),
    ] {
        std::fs::write(&path, bytes).unwrap();
        assert!(read_audio(&path, true).is_err());
    }
}

#[test]
fn duration_limit_accepts_boundary_and_rejects_one_extra_sample() {
    let temp = tempfile::tempdir().unwrap();
    let raw = temp.path().join("limit.raw");
    std::fs::write(&raw, [0.25_f32.to_le_bytes()].repeat(MAX_SAMPLES).concat()).unwrap();
    assert_eq!(read_audio(&raw, true).unwrap().len(), MAX_SAMPLES);
    let mut file = std::fs::OpenOptions::new().append(true).open(&raw).unwrap();
    std::io::Write::write_all(&mut file, &0.25_f32.to_le_bytes()).unwrap();
    assert!(read_audio(&raw, true).unwrap_err().contains("30-second"));

    let path = temp.path().join("limit.wav");
    wav(&path, 16_000, 1, 16, &vec![1; MAX_SAMPLES + 1]);
    assert!(read_audio(&path, false).unwrap_err().contains("30-second"));
}

#[test]
fn oversized_sparse_files_and_truncated_wav_fail_before_decoding() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("large.raw");
    std::fs::File::create(&path)
        .unwrap()
        .set_len(1 << 32)
        .unwrap();
    assert!(read_audio(&path, true).unwrap_err().contains("limit"));
    wav(&path, 16_000, 1, 16, &[1, 2, 3]);
    let mut bytes = std::fs::read(&path).unwrap();
    bytes.pop();
    std::fs::write(&path, bytes).unwrap();
    assert!(read_audio(&path, false).is_err());
    assert!(read_audio(temp.path(), false)
        .unwrap_err()
        .contains("regular"));
}

#[test]
fn oversized_declared_wav_data_is_rejected_without_allocating_its_length() {
    let mut bytes = Vec::new();
    {
        let mut writer = hound::WavWriter::new(
            Cursor::new(&mut bytes),
            hound::WavSpec {
                channels: 1,
                sample_rate: 16_000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .unwrap();
        writer.write_sample(1_i16).unwrap();
        writer.finalize().unwrap();
    }
    let index = bytes.windows(4).position(|v| v == b"data").unwrap() + 4;
    bytes[index..index + 4].copy_from_slice(&(u32::MAX - 1).to_le_bytes());
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("declared.wav");
    std::fs::write(&path, bytes).unwrap();
    assert!(read_audio(&path, false).is_err());
}
