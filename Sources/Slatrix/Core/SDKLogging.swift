import Foundation
import MatrixRustSDK

/// Rotated SDK logs in ~/Library/Logs/Slatrix, the first place to look when sync or encryption misbehaves.
/// `defaults write ai.nuanu.slatrix logLevel debug` raises the level for a diagnosis.
enum SDKLogging {
    static func start() {
        let level: LogLevel =
            switch UserDefaults.standard.string(forKey: "logLevel") {
            case "trace": .trace
            case "debug": .debug
            case "warn": .warn
            default: .info
            }
        let files = TracingFileConfiguration(
            path: AppPaths.logs.path, filePrefix: "slatrix", fileSuffix: "log",
            maxTotalSizeBytes: 100_000_000, maxAgeSeconds: 7 * 24 * 3600)
        let config = TracingConfiguration(
            logLevel: level, traceLogPacks: [], extraTargets: [], writeToStdoutOrSystem: false,
            writeToFiles: files, sentryConfig: nil)
        do { try initPlatform(config: config, useLightweightTokioRuntime: false) } catch {
            NSLog("SDK logging is unavailable: %@", String(describing: error))
        }
    }
}
