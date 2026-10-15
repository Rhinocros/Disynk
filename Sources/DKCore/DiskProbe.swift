import Foundation
import Darwin

/// 目标磁盘写入速度探测（方案第四节：多路 4K60 高码率合计可达 300~500MB/s，
/// 机械盘必然掉帧 → 录制启动前实测写入吞吐并在不足时告警）。
///
/// 关键：用 `F_FULLFSYNC` 把数据真正刷到介质，绕过写缓存/页缓存，得到可持续写入速率，
/// 而非「先写进 RAM」的假高值。探测产物写到目标目录下的临时文件，测完即删。
public enum DiskProbe {
    /// 实测持续写入速度（MB/s，十进制）。返回 nil 表示无法探测（目录不可写等）。
    /// - Parameters:
    ///   - directory: 目标输出目录（须已存在）。
    ///   - totalBytes: 探测总写入量，默认 64MB（足够越过缓存、逼近稳态）。
    ///   - chunkBytes: 单次写入块大小，默认 4MB（偶数对齐，减少 syscall 次数）。
    public static func measureWriteSpeedMBs(in directory: URL,
                                            totalBytes: Int = 64 * 1024 * 1024,
                                            chunkBytes: Int = 4 * 1024 * 1024) -> Double? {
        let tmp = directory.appendingPathComponent(".disynk-diskprobe-\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd); try? FileManager.default.removeItem(at: tmp) }

        // 预填一块非零数据（避免稀疏文件把全零优化掉）
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        for i in stride(from: 0, to: chunkBytes, by: 4096) { buffer[i] = UInt8.random(in: 1...255) }

        let start = DispatchTime.now()
        var written = 0
        while written < totalBytes {
            let n = buffer.withUnsafeBytes { raw in
                write(fd, raw.baseAddress, chunkBytes)
            }
            if n <= 0 { return nil }        // 磁盘满 / 中断
            written += n
        }
        // 强制刷盘：F_FULLFSYNC 落介质（不支持则退化 fsync）
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        guard elapsed > 0 else { return nil }
        return Double(written) / elapsed / 1_000_000.0   // 十进制 MB/s
    }

    /// 给定各输出文件的码率合计（bps）与实测 MB/s，判断是否可能掉帧（写不满实时需求）。
    /// 保守阈值：实测需 ≥ 需求 ×1.2 才认为安全；否则返回告警。
    public static func warningIfNeeded(aggregateBitrateBps: Int, measuredMBs: Double) -> DKError? {
        guard measuredMBs > 0 else { return nil }
        let neededMBs = Double(aggregateBitrateBps) / 8.0 / 1_000_000.0   // bps → 十进制 MB/s
        if measuredMBs < neededMBs * 1.2 {
            return .diskTooSlow(warnMBs: measuredMBs)
        }
        return nil
    }
}
