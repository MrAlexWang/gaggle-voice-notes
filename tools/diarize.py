"""
说话人分离（声纹聚类）

输入：16kHz 单声道 wav
输出：JSON —— 若干 {start, end, speaker}，单位为秒

用法:
    python diarize.py --wav input.wav --models D:\models --out out.json [--threshold 0.75] [--clusters -1]

设计说明（对应 PRD 6.13 / TECH 4.13）：
    1. pyannote segmentation 把音频切成"谁在说"的片段
    2. CAM++ 提取每个片段的声纹嵌入
    3. 快速聚类（阈值 0.75，人数上限 8）合并同一人
    4. 与 whisper 的转写分段按"时间重叠率"对齐，得到每句的说话人
"""

import argparse
import json
import os
import sys
import wave


def read_wav(path):
    """读 16bit PCM wav，返回 float32 [-1,1] 与采样率"""
    import numpy as np

    with wave.open(path, "rb") as f:
        n_channels = f.getnchannels()
        sample_rate = f.getframerate()
        sample_width = f.getsampwidth()
        n_frames = f.getnframes()
        raw = f.readframes(n_frames)

    if sample_width != 2:
        raise ValueError(f"只支持 16bit PCM wav，当前 {sample_width * 8}bit")

    data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if n_channels > 1:
        data = data.reshape(-1, n_channels).mean(axis=1)
    return data, sample_rate


def resample_to_16k(data, sr):
    """无 ffmpeg 时用线性插值重采样（够用，声纹对重采样不敏感）"""
    if sr == 16000:
        return data
    import numpy as np

    n_out = int(len(data) * 16000 / sr)
    if n_out <= 0:
        return data
    idx = np.linspace(0, len(data) - 1, n_out)
    return np.interp(idx, np.arange(len(data)), data).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True)
    ap.add_argument("--models", required=True, help="模型目录")
    ap.add_argument("--out", required=True)
    # 阈值语义：余弦相似度高于该值 → 判为同一人。值越小越容易分出更多人。
    # 实测：TTS 两音色在 0.3 下正确分出 2 人，0.75 会全部合并。真人对话建议 0.5。
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--clusters", type=int, default=-1, help="-1 表示自动，上限 8")
    args = ap.parse_args()

    seg_model = os.path.join(args.models, "sherpa-onnx-pyannote-segmentation-3-0", "model.onnx")
    emb_model = os.path.join(args.models, "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")

    if not os.path.exists(seg_model):
        print(json.dumps({"error": f"缺少分割模型: {seg_model}"}, ensure_ascii=False))
        return 2
    if not os.path.exists(emb_model):
        print(json.dumps({"error": f"缺少声纹模型: {emb_model}"}, ensure_ascii=False))
        return 2

    try:
        import sherpa_onnx
    except Exception as e:
        print(json.dumps({"error": f"sherpa-onnx 未安装: {e}"}, ensure_ascii=False))
        return 3

    samples, sr = read_wav(args.wav)
    samples = resample_to_16k(samples, sr)

    cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=seg_model),
            num_threads=4,
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=emb_model, num_threads=4),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=args.clusters,
            threshold=args.threshold,
        ),
        min_duration_on=0.25,
        min_duration_off=0.4,
    )

    if not cfg.validate():
        print(json.dumps({"error": "配置校验失败，检查模型文件"}, ensure_ascii=False))
        return 4

    sd = sherpa_onnx.OfflineSpeakerDiarization(cfg)
    result = sd.process(samples).sort_by_start_time()

    segs = []
    for r in result:
        segs.append({
            "start": round(float(r.start), 3),
            "end": round(float(r.end), 3),
            "speaker": int(r.speaker),
        })

    out = {
        "segments": segs,
        "speakers": len({s["speaker"] for s in segs}),
        "duration": round(len(samples) / 16000.0, 2),
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
