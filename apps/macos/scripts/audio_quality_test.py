import math
import tempfile
import unittest
import wave
from pathlib import Path

import audio_quality


def write_wave(path: Path, samples: list[int], channels: int = 1) -> None:
    payload = bytearray()
    for sample in samples:
        payload.extend(int(sample).to_bytes(2, "little", signed=True))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(payload)


class AudioQualityTests(unittest.TestCase):
    def test_analyze_reports_level_clipping_and_bursts(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "sample.wav"
            silence = [0] * 320
            speech = [16_384] * 320
            write_wave(path, silence + speech + silence + speech + [32_767])

            report = audio_quality.analyze(path)

            self.assertEqual(report["sampleRate"], 16_000)
            self.assertEqual(report["channels"], 1)
            self.assertEqual(report["bursts"], 2)
            self.assertEqual(report["clippedSamples"], 1)
            self.assertAlmostEqual(report["peakDbfs"], 0, places=3)
            self.assertTrue(math.isclose(report["silenceRatio"], 0.5, abs_tol=0.01))

    def test_analyze_downmixes_stereo_frames(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "stereo.wav"
            write_wave(path, [10_000, -10_000] * 320, channels=2)

            report = audio_quality.analyze(path)

            self.assertEqual(report["frames"], 320)
            self.assertLess(report["rmsDbfs"], -100)


if __name__ == "__main__":
    unittest.main()
