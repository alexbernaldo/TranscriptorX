import Foundation

enum CLICommand: String, Codable {
    case transcribe, models, version
}

struct CLIRequest: Codable {
    let command: CLICommand
    var paths: [String]
    var language: String?
    var format: String?
    var output: String?
    var outputDir: String?
    var overwrite: Bool?
    var model: String?
    var saveToHistory: Bool?
}

enum CLIEventType: String, Codable {
    case accepted, partial, progress, completed, failed, models, version, error
}

struct CLIServerEvent: Codable {
    let type: CLIEventType
    let jobId: UUID?
    let text: String?
    let percent: Int?
    let message: String?
    let payload: String?
}
