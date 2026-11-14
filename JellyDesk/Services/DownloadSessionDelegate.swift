import Foundation

/// Warum ein Download gescheitert ist.
enum DownloadFailure: Error {
    case http(Int)
    case transport(URLError)
    case file(String)
    case other(String)

    /// Lohnt ein automatischer neuer Versuch?
    var isTransient: Bool {
        switch self {
        case .http(let code):
            return code == 408 || code == 429 || (500...599).contains(code)
        case .transport(let error):
            switch error.code {
            case .badURL, .unsupportedURL, .userAuthenticationRequired, .userCancelledAuthentication,
                 .appTransportSecurityRequiresSecureConnection, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return false
            default:
                return true
            }
        case .file, .other:
            return false
        }
    }

    /// Fehlt schlicht das Netz? Dann wird später von selbst neu versucht.
    var isOffline: Bool {
        guard case .transport(let error) = self else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    var message: String {
        switch self {
        case .http(401), .http(403):
            return "Der Server lehnt das Token ab. In der Weboberfläche neu anmelden und den Download dort erneut anstoßen."
        case .http(404):
            return "Der Titel wurde auf dem Server nicht gefunden (404)."
        case .http(let code):
            return "Der Server antwortete mit Status \(code)."
        case .transport(let error):
            if error.code == .appTransportSecurityRequiresSecureConnection {
                return "Unverschlüsseltes HTTP ist nur für Adressen im Heimnetz erlaubt (IP, .local, Name ohne Punkt)."
            }
            return error.localizedDescription
        case .file(let text), .other(let text):
            return text
        }
    }
}

/// Eigene Delegate-Klasse der Download-Session. Läuft auf der Session-Queue,
/// verschiebt fertige Dateien sofort ans Ziel und meldet Ereignisse weiter.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event {
        case progress(itemID: String, written: Int64, expected: Int64)
        case finished(itemID: String, size: Int64)
        case failed(itemID: String, failure: DownloadFailure, resumeData: Data?)
    }

    private struct Registration {
        let itemID: String
        let destination: URL
        var outcome: Result<Int64, DownloadFailure>?
        var lastProgress: CFAbsoluteTime = 0
    }

    /// Wird auf der Session-Queue aufgerufen.
    var onEvent: (@Sendable (Event) -> Void)?

    private let lock = NSLock()
    private var registrations: [Int: Registration] = [:]

    func register(task: URLSessionTask, itemID: String, destination: URL) {
        lock.lock(); defer { lock.unlock() }
        registrations[task.taskIdentifier] = Registration(itemID: itemID, destination: destination)
    }

    /// Nach dem Abmelden werden Ereignisse dieser Aufgabe verworfen (Pause, Löschen).
    func unregister(task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        registrations[task.taskIdentifier] = nil
    }

    private func registration(for task: URLSessionTask) -> Registration? {
        lock.lock(); defer { lock.unlock() }
        return registrations[task.taskIdentifier]
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard var reg = registrations[downloadTask.taskIdentifier], now - reg.lastProgress >= 0.25 else {
            lock.unlock()
            return
        }
        reg.lastProgress = now
        registrations[downloadTask.taskIdentifier] = reg
        lock.unlock()
        // Ohne Content-Length meldet URLSession -1 (NSURLSessionTransferSizeUnknown).
        onEvent?(.progress(itemID: reg.itemID, written: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Die temporäre Datei verschwindet nach der Rückkehr, also hier verschieben.
        guard let reg = registration(for: downloadTask) else { return }
        let outcome: Result<Int64, DownloadFailure>

        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Eine Fehlerseite ist kein Film.
            outcome = .failure(.http(http.statusCode))
        } else {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: reg.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: reg.destination.path) { try fm.removeItem(at: reg.destination) }
                try fm.moveItem(at: location, to: reg.destination)
                let size = (try? fm.attributesOfItem(atPath: reg.destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                outcome = size > 0 ? .success(size) : .failure(.file("Der Server hat eine leere Datei geliefert."))
                if size == 0 { try? fm.removeItem(at: reg.destination) }
            } catch {
                outcome = .failure(.file("Die Datei konnte nicht abgelegt werden: \(error.localizedDescription)"))
            }
        }

        lock.lock()
        registrations[downloadTask.taskIdentifier]?.outcome = outcome
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let reg = registrations.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let reg else { return }

        if let error {
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let failure: DownloadFailure = (error as? URLError).map { .transport($0) } ?? .other(error.localizedDescription)
            onEvent?(.failed(itemID: reg.itemID, failure: failure, resumeData: resumeData))
            return
        }
        switch reg.outcome {
        case .success(let size):
            onEvent?(.finished(itemID: reg.itemID, size: size))
        case .failure(let failure):
            onEvent?(.failed(itemID: reg.itemID, failure: failure, resumeData: nil))
        case .none:
            onEvent?(.failed(itemID: reg.itemID, failure: .other("Der Download endete ohne Datei."), resumeData: nil))
        }
    }
}
