import SwiftUI

/// Заметка, которую человек написал себе: появляется сразу после первого задания.
struct NoteView: View {
    @EnvironmentObject private var wake: WakeCoordinator
    let state: NoteState

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(state.alarmTitle)
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
            Text(state.text)
                .font(.app(.title2, weight: .semibold))
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                wake.dismissNote()
            } label: {
                Text("Понятно")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.burgundy)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Theme.background.ignoresSafeArea() }
        .interactiveDismissDisabled()
    }
}
