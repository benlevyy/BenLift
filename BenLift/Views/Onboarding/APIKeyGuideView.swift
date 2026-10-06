import SwiftUI

/// How to get a Claude API key, for someone who has never heard of one.
///
/// The chat coach is the only part of the app that needs a key, and the
/// only part that costs money — the user pays Anthropic directly for what
/// they use, not us. Friends installing from TestFlight will hit this field
/// with no idea what it is, so this walks them through it in four steps
/// and is honest about the cost.
struct APIKeyGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let consoleURL = URL(string: "https://console.anthropic.com")!
    private let keysURL = URL(string: "https://console.anthropic.com/settings/keys")!
    private let billingURL = URL(string: "https://console.anthropic.com/settings/billing")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The coach runs on Claude, Anthropic's AI model. You connect it with your own key, and you pay Anthropic directly for what you use. Everything else in the app works without one.")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    step(1, "Create an account",
                         "Sign in or sign up at the Anthropic Console. A Google or email login is enough.",
                         link: ("Open console.anthropic.com", consoleURL))

                    step(2, "Add some credit",
                         "Under Billing, add a payment method and a few dollars of credit. A chat message costs around a cent or two; daily use runs a few dollars a month.",
                         link: ("Open Billing", billingURL))

                    step(3, "Create a key",
                         "Under API Keys, tap Create Key and name it something like “BenLift”. Copy it straight away — it starts with sk-ant- and is only shown once.",
                         link: ("Open API Keys", keysURL))

                    step(4, "Paste it here",
                         "The key is stored in your iPhone's Keychain and only ever sent to Anthropic, with each message you send the coach. You can change or remove it in Settings.",
                         link: nil)

                    costNote
                }
                .padding(20)
            }
            .background(Color.appBackground)
            .navigationTitle("Getting a key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ body: String, link: (String, URL)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Color.accent)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primaryText)
                Text(body)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let (label, url) = link {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text(label)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.accent)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var costNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.tertiaryText)
            Text("Settings shows what the coach has cost you so far, so there are no surprises. Set a spend limit in the Console if you want a hard ceiling.")
                .font(.caption)
                .foregroundColor(.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}
