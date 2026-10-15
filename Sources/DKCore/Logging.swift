import Foundation
import os

/// 统一日志门面（DKCore）
public enum DKLog {
    private static let subsystem = "com.disynk.app"

    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let compose = Logger(subsystem: subsystem, category: "compose")
    public static let encode = Logger(subsystem: subsystem, category: "encode")
    public static let mux = Logger(subsystem: subsystem, category: "mux")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let shot = Logger(subsystem: subsystem, category: "shot")
    public static let overlay = Logger(subsystem: subsystem, category: "overlay")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let virtualDisplay = Logger(subsystem: subsystem, category: "virtual-display")
    public static let window = Logger(subsystem: subsystem, category: "window")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
