# Historical Mixxx Twitch mapping provenance

- Upstream: `https://github.com/mixxxdj/mixxx`
- Release: Mixxx `2.3.6`
- Annotated tag object: `f9373e612b739fdeac04650feb0799dc930d76c0`
- Commit: `691596c177a80d2420a29c2d9273364921d9a21e`
- Public-tree policy: provenance only; the historical bundle is not vendored

| Upstream path | Git blob SHA-1 | SHA-256 of verified raw file | Purpose |
|---|---|---|---|
| `res/controllers/mixco/novation_twitch.mixco.js` | `ac1b1e0e36356a33ca6c0fecb65cb592a9dabadd` | `7233fef6379e7f4a20961a7c9d18cdfd3d7b2350c9aca5429cfea21f9933e3e1` | input behavior and Mixco control model |
| `res/controllers/novation_twitch.mixco.output.js` | `87b86c2c5021318a7892be88ed4827e893584541` | `f175f61c63f71b9179997f17824788aa8e67a4ee24c54907cd1fa5b86e5b1fda` | bundled output/LED behavior |
| `res/controllers/novation_twitch.mixco.output.midi.xml` | `ed372f06afe613925c6f96cfd4725bf1fa99dffd` | `832460f661add7833a9a1b6e47c0ab2611c9ca7a3836f96ed3863c4013613d5e` | MIDI mapping declarations |

The current mapping under `mapping/novation-twitch-modern/` was adapted for
Mixxx 2.5.6 and the measured Core MIDI identity. Measured hardware behavior
takes precedence over historical assumptions.
