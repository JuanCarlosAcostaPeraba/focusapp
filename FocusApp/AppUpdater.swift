import AppKit
import CoreServices
import CryptoKit
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var available: Update?

    private nonisolated static let repository = "JuanCarlosAcostaPeraba/focusapp"
    private nonisolated static let assetName = "FocusApp.dmg"
    private static let latestRelease = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    func check(automatically: Bool = false) {
        guard !busy else { return }
        busy = true
        if !automatically { status = "Buscando actualizaciones…" }
        Task {
            defer { busy = false }
            do {
                var request = URLRequest(url: Self.latestRelease, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("FocusApp", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.validate(response, hosts: ["api.github.com"])
                let release = try JSONDecoder().decode(Release.self, from: data)
                let update = try Self.newerUpdate(from: release, installedVersion: installedVersion)
                let previouslyAvailable = available
                available = update
                if let update {
                    if previouslyAvailable != update || !automatically {
                        status = update.asset == nil
                            ? "La versión \(update.version) no tiene un DMG verificable."
                            : "FocusApp \(update.version) está disponible."
                    }
                } else if previouslyAvailable != nil || !automatically {
                    status = "Tienes la última versión (\(installedVersion))."
                }
            } catch {
                if !automatically {
                    status = "No se pudo comprobar si hay actualizaciones. Inténtalo de nuevo."
                }
            }
        }
    }

    func download() {
        guard !busy, let update = available, let asset = update.asset else { return }
        busy = true
        status = "Descargando FocusApp \(update.version)…"
        Task {
            defer { busy = false }
            do {
                let file = try await Self.downloadDiskImage(asset, version: update.version)
                if NSWorkspace.shared.open(file) {
                    status = "DMG verificado. Cierra FocusApp y arrastra la nueva versión a Aplicaciones."
                } else {
                    status = "El DMG verificado está en Descargas. Ábrelo desde Finder."
                }
            } catch UpdateError.checksumMismatch {
                status = "El DMG descargado no coincide con el SHA-256 de GitHub."
            } catch {
                status = "No se pudo descargar el DMG. Puedes volver a intentarlo o ver la release en GitHub."
            }
        }
    }

    nonisolated static func newerUpdate(from release: Release, installedVersion: String) throws -> Update? {
        guard !release.draft, !release.prerelease,
              let latest = Version(release.tag), let current = Version(installedVersion) else {
            throw UpdateError.invalidRelease
        }
        guard latest > current else { return nil }

        let page = URL(string: "https://github.com/\(repository)/releases/tag/\(release.tag)")!
        let downloadURL = URL(string: "https://github.com/\(repository)/releases/download/\(release.tag)/\(assetName)")!
        let asset = release.assets.first { $0.name == assetName && $0.downloadURL == downloadURL.absoluteString }
            .flatMap { $0.sha256.map { DownloadAsset(url: downloadURL, sha256: $0) } }
        return Update(version: latest, page: page, asset: asset)
    }

    private nonisolated static func downloadDiskImage(_ asset: DownloadAsset, version: Version) async throws -> URL {
        let request = URLRequest(url: asset.url, timeoutInterval: 45)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validate(response, hosts: ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"])
        try verifyDiskImage(at: temporary, digest: asset.sha256)

        // Preserve Gatekeeper's normal checks for files downloaded from the internet.
        try (temporary as NSURL).setResourceValue([
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "FocusApp",
            kLSQuarantineDataURLKey as String: asset.url
        ], forKey: .quarantinePropertiesKey)

        let manager = FileManager.default
        let downloads = try manager.url(for: .downloadsDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
        let stem = "FocusApp-\(version)"
        let original = downloads.appendingPathComponent(stem + ".dmg")
        let destination = manager.fileExists(atPath: original.path)
            ? downloads.appendingPathComponent(stem + "-" + UUID().uuidString.prefix(8) + ".dmg")
            : original
        try manager.moveItem(at: temporary, to: destination)
        return destination
    }

    nonisolated static func verifyDiskImage(at file: URL, digest: String) throws {
        let actual = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw UpdateError.checksumMismatch }
    }

    private nonisolated static func validate(_ response: URLResponse, hosts: Set<String>) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let url = http.url, url.scheme == "https",
              let host = url.host, hosts.contains(host) else { throw UpdateError.network }
    }

    struct Update: Equatable {
        let version: Version
        let page: URL
        let asset: DownloadAsset?
    }

    struct DownloadAsset: Equatable {
        let url: URL
        let sha256: String
    }

    struct Release: Decodable {
        let tag: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case draft, prerelease, assets
        }
    }

    struct Asset: Decodable {
        let name: String
        let downloadURL: String
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, digest
            case downloadURL = "browser_download_url"
        }

        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            let hash = String(digest.dropFirst(7)).lowercased()
            guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            return hash
        }
    }

    struct Version: Comparable, CustomStringConvertible {
        let parts: [Int]

        init?(_ text: String) {
            let version = text.hasPrefix("v") ? String(text.dropFirst()) : text
            let components = version.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = components.compactMap { Int($0) }
            guard components.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }),
                  numbers.map(String.init).joined(separator: ".") == version else { return nil }
            parts = numbers
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    enum UpdateError: Error {
        case invalidRelease, network, checksumMismatch
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section("Actualizaciones") {
                LabeledContent("Versión instalada", value: updater.installedVersion)
                HStack {
                    if updater.available?.asset != nil {
                        Button("Descargar DMG", systemImage: "arrow.down.to.line") { updater.download() }
                            .disabled(updater.busy)
                    } else {
                        Button("Buscar actualizaciones", systemImage: "arrow.clockwise") { updater.check() }
                            .disabled(updater.busy)
                    }
                    if updater.busy {
                        ProgressView().controlSize(.small)
                    }
                }
                if let status = updater.status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                if let update = updater.available {
                    Link("Ver FocusApp \(update.version.description) en GitHub", destination: update.page)
                }
            }
        }
        .formStyle(.grouped)
    }
}
