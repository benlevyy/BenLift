import SwiftUI

/// "How do I do this one?" — answered by the web, not by us.
///
/// A form library is a product in itself (video, cues, variations, kept
/// current). A search for the lift's name gets the user to one in a tap,
/// which is the whole requirement when someone is standing at a machine
/// they have never used.
enum ExerciseHelp {
    static func searchURL(for exerciseName: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "how to do \(exerciseName) exercise proper form")
        ]
        return components?.url
    }
}

/// Opens a web search for the lift's form. Two sizes: a labelled pill for
/// the workout runner, and a bare icon for library rows.
struct ExerciseHelpButton: View {
    let exerciseName: String
    var compact: Bool = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = ExerciseHelp.searchURL(for: exerciseName) else { return }
            Haptics.selection()
            openURL(url)
        } label: {
            if compact {
                Image(systemName: "questionmark.circle")
                    .font(.body)
                    .foregroundColor(.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                    Text("How to")
                }
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.cardSurface)
                .cornerRadius(8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How to do \(exerciseName)")
    }
}
