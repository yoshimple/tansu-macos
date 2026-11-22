import SwiftUI
import AppKit

/// パンくずの1階層
struct Crumb: Identifiable {
    let url: URL
    let name: String
    var id: URL { url }

    /// ボリュームの先頭（iCloud Drive はその先頭）から現在の場所までの階層を作る
    static func crumbs(for url: URL) -> [Crumb] {
        let target = url.standardizedFileURL
        var rootURL = URL(fileURLWithPath: "/")
        var rootName = FileManager.default.displayName(atPath: "/")
        let components = target.pathComponents
        if let iCloud = Volumes.iCloudDrive, target.path == iCloud.path || target.path.hasPrefix(iCloud.path + "/") {
            rootURL = iCloud
            rootName = L("iCloud Drive")
        } else if components.count >= 3, components[1] == "Volumes" {
            rootURL = URL(fileURLWithPath: "/Volumes/" + components[2])
            rootName = FileManager.default.displayName(atPath: rootURL.path)
        }
        var result = [Crumb(url: rootURL, name: rootName)]
        var current = rootURL
        for component in components.dropFirst(rootURL.pathComponents.count) {
            current = current.appendingPathComponent(component)
            result.append(Crumb(url: current, name: FileManager.default.displayName(atPath: current.path)))
        }
        return result
    }
}

struct AddressBar: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.addressEditing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit {
                        // 見つからないときは入力を残し、エラーを閉じたらその場で直せるようにする
                        if model.navigate(toPath: text, onErrorClosed: { focused = true }) {
                            model.focusFileList()
                        }
                    }
                    .onExitCommand { model.focusFileList() }
                    .onAppear {
                        text = tab.directory?.path ?? ""
                        // 表示された直後に指定すると、ほかの入力欄にフォーカスが残ることがあるため、1拍おいて移す
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { _, isFocused in
                        // ほかのアプリへ切り替えただけのときは、入力中のままにする
                        if !isFocused, model.window?.isKeyWindow != false {
                            model.addressEditing = false
                        }
                    }
            } else {
                // 幅に収まる範囲で、できるだけ多くの階層を出す。収まらない分は「…」にまとめる
                let all = tab.isRecents ? [Crumb(url: tab.url, name: tab.folderName)] : Crumb.crumbs(for: tab.url)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.addressEditing = true }
                    .overlay(alignment: .leading) {
                        ViewThatFits(in: .horizontal) {
                            ForEach((1...all.count).reversed(), id: \.self) { count in
                                breadcrumbs(all, visibleCount: count)
                            }
                        }
                    }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.content))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
        .clipped()
    }

    private func breadcrumbs(_ all: [Crumb], visibleCount: Int) -> some View {
        let hidden = Array(all.dropLast(visibleCount))
        let visible = Array(all.suffix(visibleCount))
        return HStack(spacing: 0) {
            Image(systemName: tab.isSearching ? "magnifyingglass" : tab.isRecents ? "clock.fill" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.folder)
                .padding(.trailing, 4)

            if !hidden.isEmpty {
                MenuButton(menu: {
                    let menu = NSMenu.make()
                    for crumb in hidden.reversed() {
                        menu.addAction(crumb.name, symbol: "folder") { tab.navigate(to: crumb.url) }
                    }
                    return menu
                }) {
                    Text("…").font(.system(size: 13)).padding(.horizontal, 5)
                }
                chevron(for: hidden[hidden.count - 1].url)
            }

            ForEach(visible) { crumb in
                CrumbButton(title: crumb.name) { tab.navigate(to: crumb.url) }
                if crumb.url.isFileURL {
                    chevron(for: crumb.url)
                }
            }
        }
    }

    /// 「>」を押すと、その階層にあるフォルダの一覧を出す
    private func chevron(for url: URL) -> some View {
        MenuButton(menu: {
            let menu = NSMenu.make()
            let folders = Self.subfolders(of: url)
            if folders.isEmpty {
                menu.addAction(L("フォルダーはありません"), enabled: false) {}
            }
            for folder in folders {
                menu.addAction(FileManager.default.displayName(atPath: folder.path), symbol: "folder",
                               checked: tab.url.path == folder.path || tab.url.path.hasPrefix(folder.path + "/")) {
                    tab.navigate(to: folder)
                }
            }
            return menu
        }) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    private static func subfolders(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return contents.filter { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

private struct CrumbButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
