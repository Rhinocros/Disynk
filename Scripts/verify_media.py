#!/usr/bin/env python3
"""方案第七节外部解码验收：用 PyAV（镜像 ffmpeg）打开 Disynk 自研封装产物（MKV/WebM），
核实容器可被第三方解码器识别、轨道/编码符合预期，并实际解码若干视频/音频帧
（证明音画数据完整、可被 VLC/ffprobe 播放）。

用法：verify_media.py <file> [--expect-audio] [--expect-duration] [--expect-vcodec NAME] [--expect-layout]
  --expect-audio      要求存在 ≥1 音轨且可解码（MKV AAC 验收）
  --expect-duration   要求容器时长 > 0（MKV 写回 Duration；WebM 导出器不保证故默认不校验）
  --expect-vcodec NAME 要求首路视频解码器名匹配（如 h264/hevc/vp8/vp9）
  --expect-layout     解码首帧并采样左/右半颜色，核实“左红右蓝”合并布局存活（§七 合并模式验收）
退出码 0=验收通过，非 0=失败。缺少 PyAV 时以退出码 3 跳过（不判失败）。
"""
import sys


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    expect_audio = "--expect-audio" in sys.argv
    expect_duration = "--expect-duration" in sys.argv
    expect_layout = "--expect-layout" in sys.argv
    exp_vcodec = None
    if "--expect-vcodec" in sys.argv:
        i = sys.argv.index("--expect-vcodec")
        if i + 1 < len(sys.argv):
            exp_vcodec = sys.argv[i + 1]
    if not args:
        print("usage: verify_media.py <file> [--expect-audio] [--expect-duration] [--expect-vcodec NAME]")
        return 2
    path = args[0]
    try:
        import av
    except Exception:
        print(f"○ 跳过外部解码验收（未安装 PyAV）：{path}")
        return 3

    try:
        c = av.open(path)
    except Exception as e:  # noqa: BLE001
        print(f"✗ 无法打开容器 {path}: {e}")
        return 1

    vids = [s for s in c.streams.video]
    auds = [s for s in c.streams.audio]
    dur = (c.duration or 0) / 1_000_000.0  # AV_TIME_BASE = 微秒
    n_video, n_audio = len(vids), len(auds)
    vinfo = f"{vids[0].codec_context.name} {vids[0].codec_context.width}x{vids[0].codec_context.height}" if vids else "无"
    ainfo = f"{auds[0].codec_context.name} rate={auds[0].codec_context.sample_rate} ch={auds[0].codec_context.channels}" if auds else "无"
    print(f"  容器={path.split('/')[-1]} 视频轨={n_video} 音频轨={n_audio} 时长={dur:.3f}s")
    print(f"    video: {vinfo}")
    print(f"    audio: {ainfo}")
    c.close()

    ok = True
    if n_video < 1:
        print("✗ 未解析到视频轨"); ok = False
    if expect_audio and n_audio < 1:
        print("✗ 未解析到 AAC 音轨"); ok = False
    if expect_duration and dur <= 0:
        print("✗ 容器时长为 0（Duration/Cues 未正确回写）"); ok = False
    if exp_vcodec and vids and vids[0].codec_context.name != exp_vcodec:
        print(f"✗ 视频解码器名不符：期望 {exp_vcodec}，实际 {vids[0].codec_context.name}"); ok = False

    # 每路从「全新 container」独立解码：PyAV 的 container.decode 会推进共享 demuxer 游标，
    # 若在视频解码中途 break 后再解音频会读到游标耗尽 → 假 0 帧。分离打开可各自完整解码。
    def decode_count(kind: str, limit: int) -> int:
        try:
            cc = av.open(path)
            n = 0
            for _ in cc.decode(getattr(cc.streams, kind)[0]):
                n += 1
                if n >= limit:
                    break
            cc.close()
            return n
        except Exception as e:  # noqa: BLE001
            print(f"✗ {kind} 解码异常: {e}")
            return -1

    if n_video >= 1:
        vf = decode_count("video", 64)
        print(f"  解码视频帧数={vf}")
        if vf < 1:
            print("✗ 无法解码任何视频帧"); ok = False
    if n_audio >= 1:
        af = decode_count("audio", 256)
        print(f"  解码音频帧数={af}")
        if af < 1:
            print("✗ 无法解码任何音频帧"); ok = False

    # §七「合并模式验收：各屏画面位置与布局一致」的端到端最强证据：
    # 从全新 container 解码首帧，采样左/右半中心行像素，核实“左红右蓝”布局
    # 存活整个“合成→H.264 编码→MKV 封装”链路（而非仅合成前的像素断言）。
    if expect_layout and n_video >= 1:
        try:
            cc = av.open(path)
            frame = next(iter(cc.decode(cc.streams.video[0])), None)
            cc.close()
            if frame is None:
                print("✗ 布局复核：无法解码首帧"); ok = False
            else:
                arr = frame.to_ndarray(format="rgb24")  # HxWx3
                h, w, _ = arr.shape
                ly = h // 2
                left = [int(v) for v in arr[ly, w // 8]]
                right = [int(v) for v in arr[ly, w - 1 - w // 8]]
                print(f"  布局复核 左像素RGB={tuple(left)} 右像素RGB={tuple(right)}")
                if not (left[0] > 110 and left[2] < 95):
                    print("✗ 布局复核：左半非红（屏1 未落左侧）"); ok = False
                if not (right[2] > 110 and right[0] < 95):
                    print("✗ 布局复核：右半非蓝（屏2 未落右侧）"); ok = False
        except Exception as e:  # noqa: BLE001
            print(f"✗ 布局复核异常: {e}"); ok = False

    if ok:
        print(f"✔ 外部解码验收通过：{path.split('/')[-1]}")
        return 0
    print(f"✗ 外部解码验收失败：{path}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
