# Speech validation fixtures

The acceptance corpus contains 100 English (`en_us`) and 100 Swedish (`sv_se`) test utterances from [Google FLEURS](https://huggingface.co/datasets/google/fleurs), revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`. Each language is sorted by numeric sample ID, then audio filename. The first 100 rows are selected. Archive SHA-256 hashes are pinned in `scripts/prepare-fixtures.py`. Generated manifests also contain individual audio hashes and references.

FLEURS is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Attribution: Conneau et al., *FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech* (2022), Google. Original recordings and references remain in the ignored `target/fixtures` directory. Benchmark reports include recognized text and aggregate measurements derived from that dataset.

`prepare-edge-fixtures.py` creates silence, the shortest complete English and Swedish utterances in the subset, leading/internal/trailing pauses, a legacy chunk boundary plus one sample, alternating English/Swedish sources, and simultaneous sources. Transformations are silence insertion, deterministic concatenation, amplitude scaling, and PCM16 conversion. Each generated fixture records its source IDs. Simultaneous-source WER is diagnostic because a single-speaker model does not define an interleaving order.

Additional language smoke fixtures use the first five German and French test rows from the same pinned revision. They test that Parakeet v3 continues to recognize other supported languages. They do not establish full accuracy acceptance for those languages.

WER uses Unicode NFC, case folding, punctuation-to-space normalization, and word-level Levenshtein distance. Apostrophes remain in words. Reports retain every observation. Cold runs use fresh worker processes without clearing the OS file cache. Warm runs use one loaded model. CPU and GPU candidates must use the same fixture IDs and references.
