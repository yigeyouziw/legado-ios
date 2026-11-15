import SwiftUI

struct BookCover: View {
    let title: String
    var author = ""
    var remoteURL: String?
    var data: Data?

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.22, green: 0.40, blue: 0.34), Color(red: 0.10, green: 0.23, blue: 0.20)),
        (Color(red: 0.52, green: 0.30, blue: 0.24), Color(red: 0.30, green: 0.15, blue: 0.13)),
        (Color(red: 0.37, green: 0.43, blue: 0.52), Color(red: 0.20, green: 0.25, blue: 0.35)),
        (Color(red: 0.54, green: 0.41, blue: 0.23), Color(red: 0.31, green: 0.23, blue: 0.11)),
        (Color(red: 0.47, green: 0.35, blue: 0.46), Color(red: 0.29, green: 0.19, blue: 0.30))
    ]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Group {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let remoteURL, let url = try? LibraryStore.webURL(remoteURL) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { fallback(width: size.width) }
                    }
                } else {
                    fallback(width: size.width)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .aspectRatio(0.70, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.14)) }
        .accessibilityHidden(true)
    }

    private func fallback(width: CGFloat) -> some View {
        let key = Int(title.unicodeScalars.first?.value ?? 0) % Self.palette.count
        let colors = Self.palette[key]
        return ZStack(alignment: .leading) {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.black.opacity(0.18)).frame(width: max(2, width * 0.07))
            if width > 55 {
                VStack(alignment: .leading, spacing: width * 0.08) {
                    Rectangle().fill(.white.opacity(0.65)).frame(width: width * 0.22, height: 1)
                    Text(title).font(.system(size: width * 0.19, weight: .semibold, design: .serif))
                        .lineLimit(4)
                    if !author.isEmpty {
                        Text(author).font(.system(size: width * 0.10, weight: .medium)).lineLimit(1)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, width * 0.15)
                .foregroundStyle(.white)
            } else {
                Image(systemName: "book.closed").font(.system(size: width * 0.36, weight: .light))
                    .foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity)
            }
        }
    }
}

struct BookSummaryRow: View {
    let title: String
    var author = ""
    var subtitle: String?
    var coverURL: String?
    var coverData: Data?

    var body: some View {
        HStack(spacing: 14) {
            BookCover(title: title, author: author, remoteURL: coverURL, data: coverData)
                .frame(width: 45, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                if !author.isEmpty { Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 2)
    }
}
