import SwiftUI

/// The Pet & Voice tab: the pet's look and personality, and how it speaks.
struct PetTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PetSettingsSection()
                Divider()
                PetVoiceSettingsSection()
                Divider()
                VoiceModelsSection()
            }
            .padding(16)
        }
        .frame(height: 540)
    }
}
