import Foundation
import SwiftUI

struct WebDAVBackupView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("backup.webdav.url") private var address = ""
    @AppStorage("backup.webdav.username") private var username = ""
    @State private var password = ""
    @State private var operation: BackupOperation?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                TextField("备份文件 URL", text: $address)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("用户名（可选）", text: $username)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码或应用专用密码", text: $password).textContentType(.password)
            } footer: {
                Text("请填写可读写的 HTTPS 文件地址，例如 https://服务器/dav/legado-ios.json。密码仅用于本次操作。")
            }
            .disabled(working)
            Section {
                Button("上传备份", systemImage: "arrow.up.circle") { operation = .upload }
                Button("从 WebDAV 恢复", systemImage: "arrow.down.circle") { operation = .restore }
                if working { ProgressView("处理中…") }
            }
            .disabled(working || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("WebDAV 备份")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确认 WebDAV 操作", isPresented: Binding(get: { operation != nil }, set: {
            if !$0 { operation = nil }
        }), titleVisibility: .visible, presenting: operation) { item in
            Button(item.title, role: item == .restore ? .destructive : nil) { run(item) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(item == .upload ? "上传会覆盖服务器上的同名备份文件。" : "恢复成功后将替换本机书架和设置数据。")
        }
    }

    private func run(_ operation: BackupOperation) {
        let address = address
        let username = username
        let secret = password
        password = ""
        working = true
        Task {
            defer { working = false }
            do {
                let url = try LibraryStore.webURL(address)
                guard url.scheme?.lowercased() == "https", !url.path.isEmpty, !url.path.hasSuffix("/") else {
                    throw WebDAVError.invalidAddress
                }
                var request = URLRequest(url: url, timeoutInterval: 90)
                if !username.isEmpty || !secret.isEmpty {
                    let credential = Data("\(username):\(secret)".utf8).base64EncodedString()
                    request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
                }
                let session = URLSession(configuration: .ephemeral, delegate: NoWebDAVRedirects(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                switch operation {
                case .upload:
                    let backup = try await library.makeBackup()
                    request.httpMethod = "PUT"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let (_, response) = try await session.upload(for: request, from: backup)
                    try checkResponse(response)
                    library.message = LibraryMessage(title: "上传成功", detail: "备份已写入 WebDAV。")
                case .restore:
                    let (file, response) = try await session.download(for: request)
                    try checkResponse(response)
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard let size, size <= LibraryBackup.maxBytes else { throw LibraryError.tooLarge }
                    try await library.restoreBackup(Data(contentsOf: file, options: .mappedIfSafe))
                    library.message = LibraryMessage(title: "恢复成功", detail: "已从 WebDAV 载入备份。")
                }
            } catch { library.report("WebDAV 操作失败", error: error) }
        }
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(response.statusCode) else { throw LibraryError.rejectedHTTP(response.statusCode) }
    }
}

private enum BackupOperation {
    case upload, restore

    var title: String { self == .upload ? "上传并覆盖" : "恢复并替换" }
}

private enum WebDAVError: LocalizedError {
    case invalidAddress
    var errorDescription: String? { "请输入包含文件名的 HTTPS 地址。" }
}

private final class NoWebDAVRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
