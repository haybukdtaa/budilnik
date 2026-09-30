import SwiftUI

/// Временный экран для проверки, что будильник вообще звонит.
struct ContentView: View {
    @StateObject private var service = AlarmService()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "alarm.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Проверка будильника")
                .font(.title.bold())

            Text(service.status)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            Button {
                Task { await service.scheduleTest(after: 60) }
            } label: {
                Text("Зазвонить через 1 минуту")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.orange, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.black)
            }

            Button("Отменить все") {
                service.cancelAll()
            }
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
